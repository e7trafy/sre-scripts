#!/bin/bash
################################################################################
# SRE Helpers - Step 20: Isolate Existing Projects
# Converts an existing shared-www-data site to per-project isolation:
# dedicated system user + deploy key, dedicated PHP-FPM pool with
# open_basedir, vhost switched to the per-project socket, ownership swept
# to p-<domain>, supervisor workers + scheduler cron re-targeted.
#
# The site keeps serving throughout: the pool goes live before the vhost
# switch, and the permission sweep runs after traffic is already on the
# new pool.
#
# Rollback restores the vhost backup (<vhost>.pre-isolation), re-owns to
# www-data, disables the pool, and restores worker/cron users.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=20

ISO_DOMAIN=""
ISO_ALL=false
ISO_ROLLBACK=false
ISO_EXTRA_PATHS=()

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 20: Isolate Existing Projects
  Migrates existing sites from the shared www-data model to per-project
  isolation (own user, own FPM pool, open_basedir, 750/640/600 perms,
  per-project deploy key). One site at a time, idempotent, health-checked.

Options:
  --domain <name>     Site to migrate (default: pick from state files)
  --all               Migrate every site with a state file, one by one
  --extra-path <dir>  Extra open_basedir path (repeatable; moodledata is
                      added automatically from the state file)
  --rollback          Roll the domain back to the shared www-data model
  --dry-run           Print planned actions without executing
  --yes               Accept defaults without prompting
  --help              Show this help

Examples:
  sudo bash $0 --domain app.example.com
  sudo bash $0 --domain lms.example.com --extra-path /u02/appdata/shared
  sudo bash $0 --all
  sudo bash $0 --domain app.example.com --rollback

After migrating ALL sites on a host, verify no vhost still uses the
shared socket:  grep -rl 'php[0-9.]*-fpm.sock' /etc/nginx/sites-enabled/
EOF
}

_raw_args=("$@")
sre_parse_args "20-isolate-existing.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)     _i=$((_i + 1)); ISO_DOMAIN="${_raw_args[$_i]:-}" ;;
        --all)        ISO_ALL=true ;;
        --rollback)   ISO_ROLLBACK=true ;;
        --extra-path) _i=$((_i + 1)); ISO_EXTRA_PATHS+=("${_raw_args[$_i]:-}") ;;
    esac
    _i=$((_i + 1))
done

require_root

sre_header "Step 20: Isolate Existing Projects"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

SRE_OS_FAMILY=$(config_get "SRE_OS_FAMILY" "debian")
web_server=$(config_get "SRE_WEB_SERVER" "nginx")
default_php=$(config_get "SRE_PHP_VERSION" "8.3")

DEPLOY_STATE_DIR="/etc/sre-helpers/deployments"

################################################################################
# Helpers
################################################################################

# Detect the PHP version a site's vhost currently targets.
_vhost_file_for() {
    local dom="$1" f
    for f in "/etc/nginx/sites-available/${dom}.conf" \
             "/etc/nginx/sites-available/${dom}" \
             "/etc/nginx/conf.d/${dom}.conf" \
             "/etc/apache2/sites-available/${dom}.conf" \
             "/etc/httpd/conf.d/${dom}.conf"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

_php_version_from_vhost() {
    local vf="$1" ver
    ver=$(grep -oE 'php[0-9]+\.[0-9]+-fpm\.sock' "$vf" 2>/dev/null | head -1 \
        | grep -oE '[0-9]+\.[0-9]+')
    echo "${ver:-$default_php}"
}

_health_code() {
    local dom="$1" code
    code=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "https://${dom}/" 2>/dev/null)
    if [[ -z "$code" || "$code" == "000" ]]; then
        code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://${dom}/" 2>/dev/null)
    fi
    echo "${code:-000}"
}

_web_reload() {
    case "$web_server" in
        nginx)
            nginx -t && svc_reload nginx
            ;;
        apache)
            if command -v apache2ctl &>/dev/null; then
                apache2ctl configtest && svc_reload apache2
            else
                apachectl configtest && svc_reload httpd
            fi
            ;;
    esac
}

# Re-target supervisor + scheduler cron at a user. Program names untouched.
_retarget_runas() {
    local dom="$1" user="$2" changed=false f
    for f in "/etc/supervisor/conf.d/${dom}-"*.conf "/etc/supervisord.d/${dom}-"*.conf; do
        [[ -f "$f" ]] || continue
        sed -i "s/^user=.*/user=${user}/" "$f"
        sre_info "  $f → user=${user}"
        changed=true
    done
    if [[ "$changed" == "true" ]]; then
        supervisorctl reread &>/dev/null || true
        supervisorctl update &>/dev/null || true
    fi
    local cron_file="/etc/cron.d/${dom//\./-}-scheduler"
    if [[ -f "$cron_file" ]]; then
        # Field 6 of a system crontab is the run-as user
        sed -i -E "s/^((\S+\s+){5})\S+/\1${user}/" "$cron_file"
        sre_info "  $cron_file → ${user}"
    fi
}

################################################################################
# Migrate one site
################################################################################

isolate_site() {
    local dom="$1"
    local project_dir="/var/www/${dom}"

    sre_header "Isolating: $dom"

    if [[ ! -d "$project_dir" ]]; then
        sre_error "Project dir missing: $project_dir"
        return 1
    fi

    # Load state (type, moodledata, repo) if present
    DEPLOY_TYPE=""
    DEPLOY_MOODLEDATA_DIR=""
    local sf="${DEPLOY_STATE_DIR}/${dom}.conf"
    if [[ -f "$sf" ]]; then
        # shellcheck source=/dev/null
        source "$sf"
        sre_info "State loaded: type=${DEPLOY_TYPE:-?}"
    else
        sre_warning "No state file — inferring type from layout"
        if [[ -d "${project_dir}/public_html" && -f "${project_dir}/public_html/config.php" ]]; then
            DEPLOY_TYPE="moodle"
        elif [[ -e "${project_dir}/current" ]]; then
            DEPLOY_TYPE="laravel"
        else
            DEPLOY_TYPE="static"
        fi
        sre_info "Inferred type: $DEPLOY_TYPE"
    fi

    local vf php_ver user socket
    vf=$(_vhost_file_for "$dom") || { sre_error "No vhost found for $dom"; return 1; }
    php_ver=$(_php_version_from_vhost "$vf")
    user=$(iso_user_for "$dom")
    socket=$(iso_socket_for "$dom")

    sre_info "Vhost:       $vf"
    sre_info "PHP version: $php_ver"
    sre_info "New user:    $user"
    sre_info "New socket:  $socket"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would create user+key, write pool, switch vhost, sweep perms, re-target workers"
        return 0
    fi

    local before_code
    before_code=$(_health_code "$dom")
    sre_info "Health before: HTTP $before_code"

    # 1. User + deploy key (nothing routed yet)
    iso_ensure_user "$dom" "$project_dir"

    # 2. Pool (extra paths: moodledata + flags)
    local extras=("${ISO_EXTRA_PATHS[@]}")
    [[ -n "${DEPLOY_MOODLEDATA_DIR:-}" ]] && extras+=("$DEPLOY_MOODLEDATA_DIR")
    local is_php=true
    case "$DEPLOY_TYPE" in nuxt|vue|static) is_php=false ;; esac
    if [[ "$is_php" == "true" ]]; then
        iso_write_pool "$dom" "$php_ver" "$project_dir" "${extras[@]}" || return 1

        # 3. Vhost switch (backup kept for rollback)
        if grep -qE "unix:/run/php/php[0-9.]+-fpm\.sock" "$vf"; then
            [[ -f "${vf}.pre-isolation" ]] || cp "$vf" "${vf}.pre-isolation"
            sed -i -E "s|unix:/run/php/php[0-9.]+-fpm\.sock|unix:${socket}|g" "$vf"
            if ! _web_reload; then
                sre_error "Web config test failed — restoring vhost"
                cp "${vf}.pre-isolation" "$vf"
                _web_reload
                return 1
            fi
            sre_success "Vhost switched to $socket"
        elif grep -q "$socket" "$vf"; then
            sre_info "Vhost already points at $socket"
        else
            sre_warning "No shared-socket reference in $vf — review manually"
        fi
    fi

    # 4. Permission sweep (site already serving from the new pool)
    if [[ "$DEPLOY_TYPE" == "moodle" ]]; then
        iso_apply_perms "$dom" "$project_dir" "$DEPLOY_TYPE" "${DEPLOY_MOODLEDATA_DIR:-}"
    else
        iso_apply_perms "$dom" "$project_dir" "$DEPLOY_TYPE"
    fi

    # 5. Workers + cron
    _retarget_runas "$dom" "$user"

    # 6. Health check
    local after_code
    after_code=$(_health_code "$dom")
    if [[ "$after_code" -ge 500 || "$after_code" == "000" ]]; then
        sre_error "Health after migration: HTTP $after_code (was $before_code)"
        sre_error "Consider: sudo bash $0 --domain $dom --rollback"
        return 1
    fi
    sre_success "Health after: HTTP $after_code (was $before_code)"

    # 7. Record + show the deploy key
    if [[ -f "$sf" ]]; then
        grep -q '^DEPLOY_OS_USER=' "$sf" \
            && sed -i "s/^DEPLOY_OS_USER=.*/DEPLOY_OS_USER=\"${user}\"/" "$sf" \
            || echo "DEPLOY_OS_USER=\"${user}\"" >> "$sf"
        grep -q '^DEPLOY_ISOLATED=' "$sf" \
            && sed -i 's/^DEPLOY_ISOLATED=.*/DEPLOY_ISOLATED="true"/' "$sf" \
            || echo 'DEPLOY_ISOLATED="true"' >> "$sf"
    fi

    local pubkey
    pubkey=$(iso_deploy_pubkey "$dom" "$project_dir")
    if [[ -n "$pubkey" ]]; then
        sre_info "Register this READ-ONLY deploy key on the repository:"
        echo ""
        echo "    $pubkey"
        echo ""
    fi

    sre_success "$dom is isolated as $user"
}

################################################################################
# Rollback one site
################################################################################

rollback_site() {
    local dom="$1"
    local project_dir="/var/www/${dom}"

    sre_header "Rolling back isolation: $dom"

    local vf php_ver
    vf=$(_vhost_file_for "$dom") || { sre_error "No vhost found for $dom"; return 1; }
    php_ver=$(_php_version_from_vhost "$vf")

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would restore vhost backup, chown to www-data, disable pool, restore workers"
        return 0
    fi

    if [[ -f "${vf}.pre-isolation" ]]; then
        cp "${vf}.pre-isolation" "$vf"
        _web_reload || sre_warning "Web reload failed after restore — check manually"
        sre_success "Vhost restored from ${vf}.pre-isolation"
    else
        sre_warning "No ${vf}.pre-isolation backup — vhost left as-is"
    fi

    iso_remove_pool "$dom" "$php_ver"

    local web_user
    web_user=$(iso_web_user)
    sre_info "Re-owning $project_dir to $web_user (this can take a while) ..."
    chown -R "$web_user:$web_user" "$project_dir"

    _retarget_runas "$dom" "$web_user"

    local sf="${DEPLOY_STATE_DIR}/${dom}.conf"
    [[ -f "$sf" ]] && sed -i 's/^DEPLOY_ISOLATED=.*/DEPLOY_ISOLATED="false"/' "$sf"

    sre_success "$dom rolled back to the shared $web_user model"
    sre_info "Health: HTTP $(_health_code "$dom")"
}

################################################################################
# Main
################################################################################

if [[ "$ISO_ALL" == "true" ]]; then
    shopt -s nullglob
    state_files=("${DEPLOY_STATE_DIR}"/*.conf)
    shopt -u nullglob
    if [[ ${#state_files[@]} -eq 0 ]]; then
        sre_error "No deployment state files in $DEPLOY_STATE_DIR"
        exit 2
    fi
    failed=()
    for sf in "${state_files[@]}"; do
        dom=$(basename "$sf" .conf)
        if ! isolate_site "$dom"; then
            failed+=("$dom")
            sre_error "Migration failed for $dom — continuing with the rest"
        fi
        echo ""
    done
    sre_header "Summary"
    sre_info "Sites processed: ${#state_files[@]}, failed: ${#failed[@]}"
    [[ ${#failed[@]} -gt 0 ]] && sre_warning "Failed: ${failed[*]}"

    sre_info "Shared-socket assertion (should print nothing):"
    grep -rlE 'php[0-9.]+-fpm\.sock' /etc/nginx/sites-enabled/ 2>/dev/null || sre_success "No vhost uses the shared socket"
    exit 0
fi

if [[ -z "$ISO_DOMAIN" ]]; then
    shopt -s nullglob
    state_files=("${DEPLOY_STATE_DIR}"/*.conf)
    shopt -u nullglob
    domains=()
    for sf in "${state_files[@]}"; do
        domains+=("$(basename "$sf" .conf)")
    done
    if [[ ${#domains[@]} -eq 0 ]]; then
        sre_error "No deployment state files found. Pass --domain <name>."
        exit 2
    fi
    ISO_DOMAIN=$(prompt_choice "Select site:" "${domains[@]}")
fi

if [[ "$ISO_ROLLBACK" == "true" ]]; then
    rollback_site "$ISO_DOMAIN"
else
    isolate_site "$ISO_DOMAIN"
fi

recommend_next_step "$CURRENT_STEP"
