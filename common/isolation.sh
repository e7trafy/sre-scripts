#!/bin/bash
################################################################################
# SRE Helpers - Per-project isolation library
#
# Every project gets its own system user + dedicated PHP-FPM pool so a
# compromised site cannot read any other site's code, .env, or storage.
#
# Naming contract (MUST stay byte-identical with the Go implementation in
# servers-manage agent/internal/sysuser — shared test vectors in
# tests/isolation-naming.txt):
#   key   = basename of the project dir under /var/www (domain or slug)
#   s     = lowercase(key) with every char outside [a-z0-9] replaced by '-'
#   if len(s) > 24: s = s[0:17] + '-' + first 6 hex of sha256(s)
#   user  = "p-" + s            (<= 26 chars, Linux limit is 32)
#   pool  = <pool_dir>/<key>.conf, section [<key>]
#   sock  = /run/php/fpm-<user>.sock
#
# Sourced by common/lib.sh. Functions assume root.
################################################################################

ISO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_POOL_TEMPLATE="${ISO_LIB_DIR}/../vhost/templates/fpm-pool.conf"
ISO_LOG_DIR="/var/log/php-fpm"

# --- Naming ------------------------------------------------------------------

# Sanitized (possibly truncated) form of a site key
iso_sanitize() {
    local key="$1" s
    s=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    if (( ${#s} > 24 )); then
        local hash
        hash=$(printf '%s' "$s" | sha256sum | cut -c1-6)
        s="${s:0:17}-${hash}"
    fi
    printf '%s' "$s"
}

# OS user (and group) for a site key
iso_user_for() {
    printf 'p-%s' "$(iso_sanitize "$1")"
}

# Dedicated PHP-FPM socket for a site key
iso_socket_for() {
    printf '/run/php/fpm-%s.sock' "$(iso_user_for "$1")"
}

# The user the web server (nginx/apache) runs as on this host
iso_web_user() {
    case "${SRE_OS_FAMILY:-debian}" in
        rhel)
            local ws
            ws=$(config_get "SRE_WEB_SERVER" "nginx")
            [[ "$ws" == "apache" ]] && printf 'apache' || printf 'nginx'
            ;;
        *) printf 'www-data' ;;
    esac
}

# --- User + deploy key -------------------------------------------------------

# Create the project user/group (idempotent), let the web server join the
# project group, and generate a per-project read-only git deploy key.
# Usage: iso_ensure_user <key> [project_dir]
iso_ensure_user() {
    local key="$1"
    local project_dir="${2:-/var/www/${key}}"
    local user web_user
    user=$(iso_user_for "$key")
    web_user=$(iso_web_user)

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would create user $user (home $project_dir) + deploy key"
        return 0
    fi

    if ! id "$user" &>/dev/null; then
        useradd -r -M -U -d "$project_dir" -s /usr/sbin/nologin "$user"
        sre_success "Created project user: $user"
    fi

    # Web server reads static files through the project group
    if ! id -nG "$web_user" 2>/dev/null | tr ' ' '\n' | grep -qx "$user"; then
        usermod -a -G "$user" "$web_user"
        sre_info "Added $web_user to group $user (static file reads)"
    fi

    install -d -m 750 -o "$user" -g "$user" "$project_dir"

    # Per-project read-only git deploy key (register the .pub on the repo)
    local ssh_dir="${project_dir}/.ssh"
    if [[ ! -f "${ssh_dir}/id_ed25519" ]]; then
        install -d -m 700 -o "$user" -g "$user" "$ssh_dir"
        sudo -u "$user" ssh-keygen -q -t ed25519 -N "" \
            -C "deploy-${key}@$(hostname -s)" -f "${ssh_dir}/id_ed25519"
        sre_success "Generated deploy key: ${ssh_dir}/id_ed25519.pub"
    fi
    if [[ ! -s "${ssh_dir}/known_hosts" ]]; then
        ssh-keyscan -T 5 github.com gitlab.com bitbucket.org 2>/dev/null \
            > "${ssh_dir}/known_hosts" || true
        chown "$user:$user" "${ssh_dir}/known_hosts"
        chmod 600 "${ssh_dir}/known_hosts"
    fi
}

# Print the project's public deploy key (empty output if none)
iso_deploy_pubkey() {
    local key="$1" project_dir="${2:-/var/www/$1}"
    [[ -f "${project_dir}/.ssh/id_ed25519.pub" ]] && cat "${project_dir}/.ssh/id_ed25519.pub"
}

# --- FPM pool ----------------------------------------------------------------

# Test FPM config for a version; on failure the caller must remove the pool
iso_fpm_test() {
    local ver="$1"
    if command -v "php-fpm${ver}" &>/dev/null; then
        "php-fpm${ver}" -t &>/dev/null
    else
        php-fpm -t &>/dev/null
    fi
}

# Write (or refresh) the project's dedicated FPM pool and reload FPM.
# Usage: iso_write_pool <key> <php_ver> <project_dir> [extra_open_basedir_path ...]
iso_write_pool() {
    local key="$1" php_ver="$2" project_dir="$3"
    shift 3
    local extra_paths=("$@")
    local user socket pool_dir pool_file web_user
    user=$(iso_user_for "$key")
    socket=$(iso_socket_for "$key")
    pool_dir=$(get_phpfpm_pool_dir "$php_ver")
    pool_file="${pool_dir}/${key}.conf"
    web_user=$(iso_web_user)

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would write FPM pool $pool_file (user $user, socket $socket)"
        return 0
    fi

    [[ -f "$ISO_POOL_TEMPLATE" ]] || { sre_error "Pool template missing: $ISO_POOL_TEMPLATE"; return 1; }
    id "$user" &>/dev/null || { sre_error "User $user missing — run iso_ensure_user first"; return 1; }

    # open_basedir: project dir + declared extras + /dev/urandom
    local basedir="${project_dir}/"
    local p
    for p in "${extra_paths[@]}"; do
        [[ -n "$p" ]] && basedir+=":${p%/}/"
    done
    basedir+=":/dev/urandom"

    # Scoped tmp + session dirs (inside open_basedir)
    install -d -m 700 -o "$user" -g "$user" "${project_dir}/.php-tmp" "${project_dir}/.php-sessions"
    install -d -m 755 "$ISO_LOG_DIR"

    # /run/php exists via tmpfiles on debian; ensure on rhel + across reboots
    if [[ ! -d /run/php ]]; then
        install -d -m 755 /run/php
        echo 'd /run/php 0755 root root -' > /etc/tmpfiles.d/sre-php-isolation.conf
    fi

    # pm.max_children: RAM-aware default, overridable via SRE_POOL_MAX_CHILDREN
    local max_children="${SRE_POOL_MAX_CHILDREN:-}"
    if [[ -z "$max_children" ]]; then
        local mem_mb
        mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
        max_children=10
        [[ -n "$mem_mb" && "$mem_mb" -lt 4096 ]] && max_children=6
    fi

    local had_pool=false
    [[ -f "$pool_file" ]] && { had_pool=true; backup_config "$pool_file"; }

    local content
    content=$(cat "$ISO_POOL_TEMPLATE")
    content="${content//\{POOL_NAME\}/$key}"
    content="${content//\{POOL_USER\}/$user}"
    content="${content//\{WEB_USER\}/$web_user}"
    content="${content//\{SOCKET\}/$socket}"
    content="${content//\{MAX_CHILDREN\}/$max_children}"
    content="${content//\{PROJECT_DIR\}/$project_dir}"
    content="${content//\{OPEN_BASEDIR\}/$basedir}"
    printf '%s\n' "$content" > "$pool_file"

    if ! iso_fpm_test "$php_ver"; then
        sre_error "FPM config test failed — removing pool $pool_file"
        if [[ "$had_pool" == "true" ]]; then
            sre_warning "A previous pool existed; restore it from the backup_config copy"
        fi
        rm -f "$pool_file"
        return 1
    fi

    # Per-pool logs rotation (one snippet, once)
    if [[ ! -f /etc/logrotate.d/sre-php-fpm-pools ]]; then
        cat > /etc/logrotate.d/sre-php-fpm-pools <<'LOGROTATE'
/var/log/php-fpm/*-error.log /var/log/php-fpm/*-slow.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE
    fi

    svc_reload "$(get_phpfpm_svc "$php_ver")"
    sre_success "FPM pool ready: $pool_file (user $user, socket $socket)"
}

# Disable a project pool (rollback helper)
iso_remove_pool() {
    local key="$1" php_ver="$2"
    local pool_file
    pool_file="$(get_phpfpm_pool_dir "$php_ver")/${key}.conf"
    if [[ -f "$pool_file" ]]; then
        mv "$pool_file" "${pool_file}.disabled"
        svc_reload "$(get_phpfpm_svc "$php_ver")"
        sre_success "Pool disabled: ${pool_file}.disabled"
    fi
}

# --- Socket resolution (backward-compat pivot) -------------------------------

# Per-project socket if this site has a pool, otherwise the shared socket.
# Rendering a vhost with no pool present is byte-identical to the old output.
iso_socket_or_shared() {
    local key="$1" php_ver="$2"
    if [[ -f "$(get_phpfpm_pool_dir "$php_ver")/${key}.conf" ]]; then
        iso_socket_for "$key"
    else
        printf '/run/php/php%s-fpm.sock' "$php_ver"
    fi
}

# --- Permissions -------------------------------------------------------------

# Apply the isolated ownership/permission scheme to a project tree.
# Usage: iso_apply_perms <key> <project_dir> <type> [moodledata_dir]
iso_apply_perms() {
    local key="$1" project_dir="$2" type="$3" moodledata_dir="${4:-}"
    local user
    user=$(iso_user_for "$key")

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would chown $project_dir to $user, dirs 750 / files 640, secrets 600"
        return 0
    fi
    id "$user" &>/dev/null || { sre_error "User $user missing — run iso_ensure_user first"; return 1; }

    sre_info "Applying isolated permissions to $project_dir (owner $user) ..."
    chown -R "$user:$user" "$project_dir"
    find "$project_dir" -type d -exec chmod 750 {} +
    find "$project_dir" -type f -exec chmod 640 {} +

    # Strip legacy www-data/root ACLs from the shared-user era
    if command -v setfacl &>/dev/null; then
        setfacl -bR "$project_dir" 2>/dev/null || true
    fi

    # Owner-executables
    local d
    for d in "$project_dir"/releases/*/vendor/bin "$project_dir"/current/vendor/bin \
             "$project_dir"/releases/*/node_modules/.bin "$project_dir"/current/node_modules/.bin; do
        [[ -d "$d" ]] && chmod -R u+x "$d" 2>/dev/null
    done
    find "$project_dir" -maxdepth 3 \( -name artisan -o -name "*.sh" \) -type f -exec chmod 750 {} + 2>/dev/null

    # Secrets: owner-only — the web server must never read these
    find "$project_dir" -maxdepth 4 \
        \( -name ".env" -o -name "wp-config.php" -o -name "auth.json" \) \
        -type f -exec chmod 600 {} + 2>/dev/null
    [[ "$type" == "moodle" ]] && find "$project_dir" -maxdepth 3 -name "config.php" -type f -exec chmod 600 {} + 2>/dev/null
    find "$project_dir" -path "*storage/oauth-*.key" -type f -exec chmod 600 {} + 2>/dev/null

    # Re-tighten what the blanket sweep loosened
    if [[ -d "${project_dir}/.ssh" ]]; then
        chmod 700 "${project_dir}/.ssh"
        chmod 600 "${project_dir}/.ssh/"id_* "${project_dir}/.ssh/known_hosts" 2>/dev/null
        chmod 640 "${project_dir}/.ssh/"*.pub 2>/dev/null
    fi
    for d in "${project_dir}/.php-tmp" "${project_dir}/.php-sessions"; do
        [[ -d "$d" ]] && chmod 700 "$d"
    done

    # moodledata: project-user only — served through PHP, never by nginx
    if [[ -n "$moodledata_dir" && -d "$moodledata_dir" ]]; then
        sre_info "Applying isolated permissions to moodledata: $moodledata_dir ..."
        chown -R "$user:$user" "$moodledata_dir"
        chmod -R u+rwX,g-rwx,o-rwx "$moodledata_dir"
        command -v setfacl &>/dev/null && setfacl -bR "$moodledata_dir" 2>/dev/null || true
    fi

    sre_success "Isolated permissions applied (owner $user)"
}
