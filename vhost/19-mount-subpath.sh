#!/bin/bash
################################################################################
# SRE Helpers - Step 19: Mount Project as Subpath Under Another Project
#
# Mounts a sub-app (e.g. lms.upm.edu.sa) under a host vhost at a chosen
# subpath (e.g. elearning.upm.edu.sa/lms). Two implementations:
#
#   1. proxy (recommended) — sub-app keeps its own working vhost on an
#      internal-only listener (127.0.0.1:PORT); host vhost gets a
#      `location ^~ /lms/ { proxy_pass ... }` snippet. Type-agnostic.
#
#   2. alias — single vhost; host gets `location ^~ /lms/ { alias ...; }` with
#      a nested PHP block pointing at the sub-app's FPM socket. No extra
#      listener, but alias+SCRIPT_FILENAME is a known nginx footgun.
#
# Both modes write the host-side glue to /etc/nginx/snippets/<host>-subpaths/,
# which step 8's nginx template now includes (survives vhost regeneration).
#
# Optionally:
#   - 301-redirect the sub-app's old hostname to the new subpath URL.
#   - Rewrite Moodle wwwroot / Laravel APP_URL to the subpath URL.
#
# Verification:
#   - nginx -t (syntax)
#   - HTTP probe through the subpath to confirm routing (catches misroute by
#     the host's `location ~ \.php$` regex).
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=19

# Defaults (set by SRE_YES path when present, otherwise prompted)
MS_HOST=""           # e.g. elearning.upm.edu.sa
MS_SUB=""            # e.g. lms.upm.edu.sa  (the sub-app's own domain)
MS_PATH=""           # e.g. /lms
MS_MODE=""           # proxy | alias
MS_REDIRECT_OLD=""   # yes | no
MS_REWRITE_APP=""    # yes | no
MS_INTERNAL_PORT=""  # proxy mode only; auto-picked from free ports
MS_RESET="false"

SRE_YES="${SRE_YES:-false}"
SRE_FORCE="${SRE_FORCE:-false}"
SRE_DRY_RUN="${SRE_DRY_RUN:-false}"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 19: Mount Project as Subpath Under Another Project
  Mounts an existing provisioned project at <host>/<path>/.
  Two modes: --mode proxy (default, recommended) or --mode alias.

Options:
  --host <domain>          Host project that serves the subpath (e.g. elearning.upm.edu.sa)
  --sub <domain>           Sub-app to mount (e.g. lms.upm.edu.sa)
  --path <prefix>          Subpath prefix (e.g. /lms). Leading slash required, no trailing.
  --mode <proxy|alias>     Implementation mode (default: proxy)
  --internal-port <port>   Proxy mode: internal listener port (default: auto-pick 8081+)
  --redirect-old <yes|no>  301-redirect the sub-app's old domain to the subpath (default: yes)
  --rewrite-app <yes|no>   Rewrite sub-app's wwwroot/APP_URL to subpath URL (default: yes)
  --reset                  Remove the mount: snippet, internal listener (proxy), redirect vhost
  --yes                    Non-interactive; use defaults / provided flags
  --force                  Allow destructive overwrites (replacing an existing mount)
  --dry-run                Print planned actions without executing
  --help                   Show this help

Examples:
  # Recommended: proxy mode, with old-domain redirect and Moodle wwwroot rewrite
  sudo bash $0 --host elearning.upm.edu.sa --sub lms.upm.edu.sa --path /lms

  # Alias mode, no redirect (keep old domain alive)
  sudo bash $0 --host elearning.upm.edu.sa --sub lms.upm.edu.sa --path /lms \\
      --mode alias --redirect-old no

  # Tear down the mount
  sudo bash $0 --host elearning.upm.edu.sa --sub lms.upm.edu.sa --path /lms --reset
EOF
}

# Parse common args first
_raw_args=("$@")
sre_parse_args "19-mount-subpath.sh" "${_raw_args[@]}"

# Parse step-specific args
_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --host)           _i=$((_i + 1)); MS_HOST="${_raw_args[$_i]:-}" ;;
        --sub)            _i=$((_i + 1)); MS_SUB="${_raw_args[$_i]:-}" ;;
        --path)           _i=$((_i + 1)); MS_PATH="${_raw_args[$_i]:-}" ;;
        --mode)           _i=$((_i + 1)); MS_MODE="${_raw_args[$_i]:-}" ;;
        --internal-port)  _i=$((_i + 1)); MS_INTERNAL_PORT="${_raw_args[$_i]:-}" ;;
        --redirect-old)   _i=$((_i + 1)); MS_REDIRECT_OLD="${_raw_args[$_i]:-}" ;;
        --rewrite-app)    _i=$((_i + 1)); MS_REWRITE_APP="${_raw_args[$_i]:-}" ;;
        --reset)          MS_RESET="true" ;;
    esac
    _i=$((_i + 1))
done

require_root
sre_header "Step 19: Mount Project as Subpath"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")

if [[ "$web_server" != "nginx" ]]; then
    sre_error "Subpath mounts are nginx-only in this version (web_server=$web_server)."
    sre_error "Apache reverse-proxy + ProxyPass is not yet supported here."
    exit 2
fi

# ============================================================================
# Helpers
# ============================================================================

# Resolve a domain to its vhost file. Tries sites-available first, falls back
# to conf.d (RHEL). Returns the path on stdout, empty + non-zero on miss.
_find_vhost() {
    local dom="$1"
    local f
    for f in \
        "/etc/nginx/sites-available/${dom}.conf" \
        "/etc/nginx/sites-available/${dom}" \
        "/etc/nginx/conf.d/${dom}.conf"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# Pick the first free TCP port at or above $1. Used to assign the internal
# proxy listener.
_pick_free_port() {
    local p="${1:-8081}"
    while ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${p}\$"; do
        p=$((p + 1))
        [[ $p -gt 65535 ]] && { echo "0"; return 1; }
    done
    echo "$p"
}

# Detect scheme (http/https) served by a domain from its vhost.
_detect_scheme() {
    local vh="$1"
    if grep -qE 'listen\s+443|ssl_certificate' "$vh" 2>/dev/null; then
        echo "https"
    else
        echo "http"
    fi
}

# Parse top-level `root` of HTTPS server block (or HTTP if no HTTPS exists).
# Re-uses the same brace-counting awk as step 16.
_parse_doc_root() {
    local vh="$1"
    awk '
        BEGIN { depth = 0; in_server = 0; cur_listen = ""; best_443 = ""; best_80 = "" }
        {
            line = $0
            if (line ~ /^[[:space:]]*listen[[:space:]]+443/) cur_listen = "443"
            else if (line ~ /^[[:space:]]*listen[[:space:]]+80/ && cur_listen == "") cur_listen = "80"
            if (in_server && depth == 1 && line ~ /^[[:space:]]*root[[:space:]]+/) {
                sub(/^[[:space:]]*root[[:space:]]+/, "", line)
                sub(/;.*$/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (cur_listen == "443" && best_443 == "") best_443 = line
                else if (cur_listen != "443" && best_80 == "") best_80 = line
            }
            line2 = $0
            for (i = 1; i <= length(line2); i++) {
                c = substr(line2, i, 1)
                if (c == "{") {
                    if (!in_server) {
                        tail = substr(line2, 1, i - 1)
                        if (tail ~ /(^|[^A-Za-z_])server[[:space:]]*$/) {
                            in_server = 1; depth = 1; continue
                        }
                    } else { depth++ }
                } else if (c == "}" && in_server) {
                    depth--
                    if (depth == 0) { in_server = 0; cur_listen = "" }
                }
            }
        }
        END { print (best_443 != "" ? best_443 : best_80) }
    ' "$vh"
}

# Detect the sub-app's project type by looking at its docroot.
# Returns: moodle | laravel | wordpress | static | unknown
_detect_type() {
    local dr="$1"
    if [[ -f "${dr}/config.php" ]] && grep -q 'CFG->wwwroot' "${dr}/config.php" 2>/dev/null; then
        echo "moodle"; return
    fi
    # config.php might be one level up (some Moodle installs)
    if [[ -f "${dr%/}/../config.php" ]] && grep -q 'CFG->wwwroot' "${dr%/}/../config.php" 2>/dev/null; then
        echo "moodle"; return
    fi
    if [[ -d "${dr%/}/../moodledata" ]] || [[ -d "${dr%/}/../../moodledata" ]]; then
        echo "moodle"; return
    fi
    if [[ -f "${dr%/}/../artisan" ]]; then
        echo "laravel"; return
    fi
    if [[ -f "${dr}/wp-config.php" ]]; then
        echo "wordpress"; return
    fi
    if [[ -f "${dr}/index.html" || -f "${dr}/index.htm" ]] && ! find "$dr" -maxdepth 1 -name '*.php' 2>/dev/null | grep -q .; then
        echo "static"; return
    fi
    # PHP files present but no Moodle/Laravel/WP markers — treat as generic PHP (laravel-ish)
    if find "$dr" -maxdepth 1 -name '*.php' 2>/dev/null | head -1 | grep -q .; then
        echo "laravel"; return
    fi
    echo "unknown"
}

# Locate Moodle's config.php starting from docroot (may be one level up)
_find_moodle_config() {
    local dr="$1"
    for c in "${dr}/config.php" "${dr%/}/../config.php"; do
        [[ -f "$c" ]] && grep -q 'CFG->wwwroot' "$c" 2>/dev/null && { readlink -f "$c"; return 0; }
    done
    return 1
}

# Locate Laravel's .env relative to docroot. Laravel docroot is typically
# /var/www/<dom>/current/public, so .env is two levels up.
_find_laravel_env() {
    local dr="$1"
    for c in "${dr%/}/../.env" "${dr%/}/../../.env" "${dr%/}/.env"; do
        [[ -f "$c" ]] && { readlink -f "$c"; return 0; }
    done
    return 1
}

# Find sub-app's PHP-FPM socket. Prefer the per-project pool (named after the
# domain) so the subpath hits the right pool with its own env / limits.
# Falls back to the global socket for the configured PHP version.
_find_fpm_socket() {
    local dom="$1"
    local sock
    # Match either /etc/php/<v>/fpm/pool.d/<dom>.conf or pool [<dom>]
    for poolfile in /etc/php/*/fpm/pool.d/*.conf; do
        [[ -f "$poolfile" ]] || continue
        if grep -q "^\[${dom}\]\|^\[${dom//./_}\]" "$poolfile" 2>/dev/null \
           || [[ "$(basename "$poolfile")" == "${dom}.conf" ]]; then
            sock=$( { grep -m1 -E '^[[:space:]]*listen[[:space:]]*=' "$poolfile" || true; } \
                | sed -E 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//; s/[[:space:]]+$//')
            [[ -n "$sock" && "$sock" == /* ]] && { echo "$sock"; return 0; }
        fi
    done
    echo "/run/php/php${php_version}-fpm.sock"
}

# ============================================================================
# Reset mode — tear down the mount
# ============================================================================

if [[ "$MS_RESET" == "true" ]]; then
    [[ -z "$MS_HOST" || -z "$MS_SUB" || -z "$MS_PATH" ]] && {
        sre_error "--reset requires --host, --sub, and --path"
        exit 1
    }
    sre_header "Reset: Removing Subpath Mount"
    sre_info "Host: $MS_HOST"
    sre_info "Sub:  $MS_SUB"
    sre_info "Path: $MS_PATH"

    snippet_dir="/etc/nginx/snippets/${MS_HOST}-subpaths"
    safe_path="${MS_PATH#/}"; safe_path="${safe_path//\//_}"
    snippet_file="${snippet_dir}/${safe_path}.conf"
    internal_file="/etc/nginx/sites-available/${MS_SUB}-internal.conf"
    internal_link="/etc/nginx/sites-enabled/${MS_SUB}-internal.conf"
    redirect_file="/etc/nginx/sites-available/${MS_SUB}-redirect.conf"
    redirect_link="/etc/nginx/sites-enabled/${MS_SUB}-redirect.conf"

    set +e
    [[ -f "$snippet_file" ]]  && { rm -f "$snippet_file";  sre_success "Removed: $snippet_file"; }
    [[ -L "$internal_link" ]] && { rm -f "$internal_link"; sre_success "Removed: $internal_link"; }
    [[ -f "$internal_file" ]] && { rm -f "$internal_file"; sre_success "Removed: $internal_file"; }
    [[ -L "$redirect_link" ]] && { rm -f "$redirect_link"; sre_success "Removed: $redirect_link"; }
    [[ -f "$redirect_file" ]] && { rm -f "$redirect_file"; sre_success "Removed: $redirect_file"; }
    set -e

    if nginx -t 2>&1; then
        svc_reload nginx
        sre_success "Mount removed and nginx reloaded."
    else
        sre_error "nginx -t failed after reset; investigate manually."
        exit 1
    fi
    sre_warning "Sub-app's original vhost (${MS_SUB}.conf) was NOT touched — restore it manually if you disabled it."
    exit 0
fi

# ============================================================================
# Collect / prompt for inputs
# ============================================================================

if [[ -z "$MS_HOST" ]]; then
    MS_HOST=$(prompt_input "Host project domain (the one that serves the subpath)" "")
fi
if [[ -z "$MS_SUB" ]]; then
    MS_SUB=$(prompt_input "Sub-app domain (the one being mounted under the host)" "")
fi
if [[ -z "$MS_PATH" ]]; then
    MS_PATH=$(prompt_input "Subpath prefix (e.g. /lms)" "/lms")
fi
if [[ -z "$MS_MODE" ]]; then
    if [[ "$SRE_YES" == "true" ]]; then
        MS_MODE="proxy"
    else
        MS_MODE=$(prompt_choice "Mount mode (proxy is recommended):" "proxy" "alias")
    fi
fi
if [[ -z "$MS_REDIRECT_OLD" ]]; then
    if [[ "$SRE_YES" == "true" ]]; then
        MS_REDIRECT_OLD="yes"
    else
        prompt_yesno "301-redirect ${MS_SUB} to ${MS_HOST}${MS_PATH}?" "yes" && MS_REDIRECT_OLD="yes" || MS_REDIRECT_OLD="no"
    fi
fi
if [[ -z "$MS_REWRITE_APP" ]]; then
    if [[ "$SRE_YES" == "true" ]]; then
        MS_REWRITE_APP="yes"
    else
        prompt_yesno "Rewrite sub-app config (Moodle wwwroot / Laravel APP_URL) to ${MS_HOST}${MS_PATH}?" "yes" && MS_REWRITE_APP="yes" || MS_REWRITE_APP="no"
    fi
fi

# Sanity-check path
[[ "$MS_PATH" =~ ^/[A-Za-z0-9_-]+$ ]] || {
    sre_error "Path '$MS_PATH' is invalid. Required: leading /, no trailing /, [A-Za-z0-9_-] only."
    sre_error "Examples: /lms, /portal, /apps-v2"
    exit 1
}
[[ "$MS_MODE" == "proxy" || "$MS_MODE" == "alias" ]] || {
    sre_error "Mode '$MS_MODE' invalid (must be: proxy | alias)"
    exit 1
}

# ============================================================================
# Locate vhosts and detect sub-app properties
# ============================================================================

host_vhost=$(_find_vhost "$MS_HOST") || { sre_error "Host vhost not found for $MS_HOST"; exit 2; }
sub_vhost=$(_find_vhost "$MS_SUB")   || { sre_error "Sub-app vhost not found for $MS_SUB"; exit 2; }

sre_info "Host vhost:  $host_vhost"
sre_info "Sub vhost:   $sub_vhost"

host_scheme=$(_detect_scheme "$host_vhost")
sub_docroot=$(_parse_doc_root "$sub_vhost")
sub_type=$(_detect_type "$sub_docroot")
sub_fpm_sock=$(_find_fpm_socket "$MS_SUB")

[[ -d "$sub_docroot" ]] || {
    sre_error "Sub-app docroot not found: $sub_docroot"
    exit 2
}

sre_info "Host scheme: $host_scheme"
sre_info "Sub docroot: $sub_docroot"
sre_info "Sub type:    $sub_type"
sre_info "Sub FPM:     $sub_fpm_sock"
sre_info "Mode:        $MS_MODE"

# Verify the host vhost has the subpath include hook. If it doesn't, the user
# is on an older template; warn and offer manual fix.
if ! grep -q "snippets/${MS_HOST}-subpaths" "$host_vhost"; then
    sre_warning "Host vhost has no subpath include hook."
    sre_warning "Add this line near the bottom of the host's server block, then re-run:"
    sre_warning "  include /etc/nginx/snippets/${MS_HOST}-subpaths/*.conf;"
    if [[ "$SRE_FORCE" != "true" ]]; then
        sre_error "Re-run with --force to skip this check (you must add the include manually)."
        exit 1
    fi
fi

snippet_dir="/etc/nginx/snippets/${MS_HOST}-subpaths"
safe_path="${MS_PATH#/}"; safe_path="${safe_path//\//_}"
snippet_file="${snippet_dir}/${safe_path}.conf"

if [[ -f "$snippet_file" && "$SRE_FORCE" != "true" ]]; then
    sre_warning "Mount already exists: $snippet_file"
    if [[ "$SRE_YES" != "true" ]]; then
        prompt_yesno "Overwrite?" "no" || { sre_skipped "Cancelled."; exit 4; }
    else
        sre_error "Refusing to overwrite without --force. Use --reset first or pass --force."
        exit 1
    fi
fi

mkdir -p "$snippet_dir"
target_url="${host_scheme}://${MS_HOST}${MS_PATH}"

# ============================================================================
# Mode: proxy
# ============================================================================

write_proxy_snippet() {
    local port="$1"
    cat <<EOF
# Subpath mount: ${MS_PATH} → ${MS_SUB} (mode: proxy, written by step 19)
# Reverse-proxy to internal listener on 127.0.0.1:${port}. The sub-app's
# original vhost remains the source of truth for its docroot + FPM pool.
location ^~ ${MS_PATH}/ {
    proxy_pass http://127.0.0.1:${port}/;
    proxy_http_version 1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto ${host_scheme};
    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-Prefix ${MS_PATH};
    proxy_redirect off;
    proxy_buffering off;
    proxy_read_timeout 300;
    proxy_send_timeout 300;
    client_max_body_size 500M;
}

# Bare ${MS_PATH} → ${MS_PATH}/ (so /lms works as well as /lms/)
location = ${MS_PATH} {
    return 301 ${MS_PATH}/;
}
EOF
}

write_internal_vhost() {
    local port="$1"
    # The internal vhost is a stripped copy of the sub-app's serving rules,
    # bound to 127.0.0.1:PORT, so the host's proxy_pass hits it. We embed the
    # right PHP location block based on the detected sub-app type so the FPM
    # pool answers correctly. We do NOT touch the sub-app's public vhost.

    local php_block="" extra_block=""
    case "$sub_type" in
        moodle)
            php_block=$(cat <<PHPEOF
    location /pluginfile.php {
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
        fastcgi_read_timeout 300;
    }
    location /tokenpluginfile.php {
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
        fastcgi_read_timeout 300;
    }
    location ~ [^/]\\.php(/|\$) {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }
PHPEOF
            )
            extra_block="    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }"
            ;;
        laravel)
            php_block=$(cat <<PHPEOF
    location ~ \\.php\$ {
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }
PHPEOF
            )
            extra_block="    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }"
            ;;
        wordpress)
            php_block=$(cat <<PHPEOF
    location ~ \\.php\$ {
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }
PHPEOF
            )
            extra_block="    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$args; }"
            ;;
        static|*)
            extra_block="    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }"
            php_block=""
            ;;
    esac

    cat <<EOF
# Internal-only listener for ${MS_SUB} (consumed by the host vhost's proxy_pass).
# DO NOT add server_name with a public domain; this listener is reachable only
# from localhost.
server {
    listen 127.0.0.1:${port};
    server_name _;

    root ${sub_docroot};
    charset utf-8;

    access_log /var/log/nginx/${MS_SUB}-internal-access.log;
    error_log  /var/log/nginx/${MS_SUB}-internal-error.log;

    client_max_body_size 500M;
    client_body_timeout 300s;
    send_timeout 300s;

${extra_block}

${php_block}

    location ~ /\\. { deny all; }
}
EOF
}

# ============================================================================
# Mode: alias
# ============================================================================

write_alias_snippet() {
    # Alias mode: serves the sub-app's docroot from under MS_PATH on the host
    # vhost itself. PATH_INFO + SCRIPT_FILENAME with alias is a known nginx
    # footgun: SCRIPT_FILENAME must be built from $request_filename, not
    # $document_root + $fastcgi_script_name (which would resolve under the
    # host's docroot).
    local php_block=""
    case "$sub_type" in
        moodle)
            php_block=$(cat <<PHPEOF
    location ~ ^${MS_PATH}/.+\\.php(/|\$) {
        rewrite ^${MS_PATH}/(.*)\$ /\$1 break;
        root ${sub_docroot};
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }
PHPEOF
            )
            ;;
        laravel|wordpress)
            php_block=$(cat <<PHPEOF
    location ~ ^${MS_PATH}/.+\\.php\$ {
        rewrite ^${MS_PATH}/(.*)\$ /\$1 break;
        root ${sub_docroot};
        fastcgi_pass unix:${sub_fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }
PHPEOF
            )
            ;;
        static|*)
            php_block=""
            ;;
    esac

    local front_controller=""
    case "$sub_type" in
        moodle|laravel)
            front_controller="try_files \$uri \$uri/ ${MS_PATH}/index.php?\$query_string;"
            ;;
        wordpress)
            front_controller="try_files \$uri \$uri/ ${MS_PATH}/index.php?\$args;"
            ;;
        static|*)
            front_controller="try_files \$uri \$uri/ =404;"
            ;;
    esac

    cat <<EOF
# Subpath mount: ${MS_PATH} → ${MS_SUB} (mode: alias, written by step 19)
# WARNING: alias mode requires the host vhost's regex `location ~ \\.php\$`
# to NOT capture ${MS_PATH}/*.php — this block uses ^~ which beats regex.
location ^~ ${MS_PATH}/ {
    alias ${sub_docroot}/;
    ${front_controller}
}

${php_block}

# Bare ${MS_PATH} → ${MS_PATH}/
location = ${MS_PATH} {
    return 301 ${MS_PATH}/;
}
EOF
}

# ============================================================================
# Plan output
# ============================================================================

sre_header "Plan"
echo "  Host vhost:        $host_vhost"
echo "  Sub-app vhost:     $sub_vhost"
echo "  Sub-app docroot:   $sub_docroot"
echo "  Sub-app type:      $sub_type"
echo "  Sub-app FPM sock:  $sub_fpm_sock"
echo "  Mode:              $MS_MODE"
echo "  Subpath URL:       $target_url"
echo "  Snippet:           $snippet_file"
if [[ "$MS_MODE" == "proxy" ]]; then
    if [[ -z "$MS_INTERNAL_PORT" ]]; then
        MS_INTERNAL_PORT=$(_pick_free_port 8081)
        [[ "$MS_INTERNAL_PORT" == "0" ]] && { sre_error "No free port found above 8081"; exit 2; }
    fi
    echo "  Internal listener: 127.0.0.1:${MS_INTERNAL_PORT}"
fi
echo "  Redirect old host: $MS_REDIRECT_OLD"
echo "  Rewrite app:       $MS_REWRITE_APP"

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] No changes written. Exiting."
    exit 0
fi

# ============================================================================
# Write configs
# ============================================================================

sre_header "Writing Configuration"

# 1. Snippet (host-side glue)
if [[ "$MS_MODE" == "proxy" ]]; then
    write_proxy_snippet "$MS_INTERNAL_PORT" > "$snippet_file"
else
    write_alias_snippet > "$snippet_file"
fi
chmod 644 "$snippet_file"
sre_success "Wrote snippet: $snippet_file"

# 2. Internal listener (proxy mode only)
internal_file="/etc/nginx/sites-available/${MS_SUB}-internal.conf"
internal_link="/etc/nginx/sites-enabled/${MS_SUB}-internal.conf"
if [[ "$MS_MODE" == "proxy" ]]; then
    write_internal_vhost "$MS_INTERNAL_PORT" > "$internal_file"
    chmod 644 "$internal_file"
    ln -sf "$internal_file" "$internal_link"
    sre_success "Wrote internal listener: $internal_file"
fi

# 3. Old-domain 301 redirect (replaces the sub-app's original public vhost)
redirect_file="/etc/nginx/sites-available/${MS_SUB}-redirect.conf"
redirect_link="/etc/nginx/sites-enabled/${MS_SUB}-redirect.conf"
if [[ "$MS_REDIRECT_OLD" == "yes" ]]; then
    sub_has_ssl="no"
    grep -qE 'listen\s+443|ssl_certificate' "$sub_vhost" 2>/dev/null && sub_has_ssl="yes"

    # We back up the original sub-app vhost before disabling it, so a manual
    # rollback is one symlink away. We DO NOT delete it.
    backup_config "$sub_vhost"
    # Disable the original by removing its sites-enabled symlink (if present).
    sub_enabled_link="${sub_vhost/sites-available/sites-enabled}"
    if [[ -L "$sub_enabled_link" ]]; then
        rm -f "$sub_enabled_link"
        sre_info "Disabled original sub-app vhost: $sub_enabled_link"
    fi

    {
        echo "# 301 redirect: ${MS_SUB} → ${target_url} (written by step 19)"
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name ${MS_SUB};"
        echo ""
        echo "    location ^~ /.well-known/acme-challenge/ {"
        echo "        root /var/www/letsencrypt;"
        echo "    }"
        echo ""
        echo "    location / {"
        echo "        return 301 ${target_url}\$request_uri;"
        echo "    }"
        echo "}"
        if [[ "$sub_has_ssl" == "yes" ]]; then
            # Re-use the sub-app's existing cert paths so HTTPS clients hitting
            # the old host get a valid TLS handshake on the way to the redirect.
            cert=$( { grep -m1 -E '^[[:space:]]*ssl_certificate[[:space:]]' "$sub_vhost" || true; } \
                | sed -E 's/^[[:space:]]*ssl_certificate[[:space:]]+//; s/;.*$//; s/^[[:space:]]+|[[:space:]]+$//')
            key=$( { grep -m1 -E '^[[:space:]]*ssl_certificate_key[[:space:]]' "$sub_vhost" || true; } \
                | sed -E 's/^[[:space:]]*ssl_certificate_key[[:space:]]+//; s/;.*$//; s/^[[:space:]]+|[[:space:]]+$//')
            if [[ -n "$cert" && -n "$key" && -f "$cert" && -f "$key" ]]; then
                echo ""
                echo "server {"
                echo "    listen 443 ssl;"
                echo "    listen [::]:443 ssl;"
                echo "    http2 on;"
                echo "    server_name ${MS_SUB};"
                echo "    ssl_certificate     ${cert};"
                echo "    ssl_certificate_key ${key};"
                echo "    return 301 ${target_url}\$request_uri;"
                echo "}"
            else
                sre_warning "Sub-app had SSL but cert paths not found; HTTPS redirect block skipped."
            fi
        fi
    } > "$redirect_file"
    chmod 644 "$redirect_file"
    ln -sf "$redirect_file" "$redirect_link"
    sre_success "Wrote 301 redirect: $redirect_file"
fi

# ============================================================================
# Rewrite sub-app config (Moodle wwwroot / Laravel APP_URL)
# ============================================================================

if [[ "$MS_REWRITE_APP" == "yes" ]]; then
    sre_header "Rewriting Sub-App Config"
    case "$sub_type" in
        moodle)
            mcf=$(_find_moodle_config "$sub_docroot" || true)
            if [[ -z "$mcf" ]]; then
                sre_warning "Could not find Moodle config.php under $sub_docroot; skipping rewrite."
            else
                backup_config "$mcf"
                # Rewrite wwwroot to the new full subpath URL.
                sed -i -E "s|^([[:space:]]*\\\$CFG->wwwroot[[:space:]]*=[[:space:]]*)'[^']*'(.*)|\\1'${target_url}'\\2|" "$mcf"
                sed -i -E "s|^([[:space:]]*\\\$CFG->wwwroot[[:space:]]*=[[:space:]]*)\"[^\"]*\"(.*)|\\1\"${target_url}\"\\2|" "$mcf"

                # If proxy mode AND host is https, Moodle must know it's behind
                # a reverse proxy that terminates TLS, or it builds http links.
                if [[ "$MS_MODE" == "proxy" && "$host_scheme" == "https" ]]; then
                    grep -q 'CFG->reverseproxy' "$mcf" || \
                        sed -i "/CFG->wwwroot/a \\\$CFG->reverseproxy = true;" "$mcf"
                    grep -q 'CFG->sslproxy' "$mcf" || \
                        sed -i "/CFG->wwwroot/a \\\$CFG->sslproxy = true;" "$mcf"
                fi

                # Cookie path: namespace the session cookie to the subpath so
                # it doesn't collide with the host project's cookies.
                if grep -q 'CFG->sessioncookiepath' "$mcf"; then
                    sed -i -E "s|^([[:space:]]*\\\$CFG->sessioncookiepath[[:space:]]*=[[:space:]]*)'[^']*'(.*)|\\1'${MS_PATH}/'\\2|" "$mcf"
                else
                    sed -i "/CFG->wwwroot/a \\\$CFG->sessioncookiepath = '${MS_PATH}/';" "$mcf"
                fi

                sre_success "Moodle config.php rewritten (wwwroot=${target_url})"
                # Purge caches via Moodle CLI if available
                mc_dir=$(dirname "$mcf")
                if [[ -f "${mc_dir}/admin/cli/purge_caches.php" ]]; then
                    sudo -u www-data php "${mc_dir}/admin/cli/purge_caches.php" 2>&1 | head -5 || true
                    sre_success "Moodle caches purged."
                else
                    sre_warning "purge_caches.php not found; run it manually after this step."
                fi
            fi
            ;;
        laravel)
            env_file=$(_find_laravel_env "$sub_docroot" || true)
            if [[ -z "$env_file" ]]; then
                sre_warning "Could not find Laravel .env under $sub_docroot; skipping rewrite."
            else
                backup_config "$env_file"
                # APP_URL
                if grep -q '^APP_URL=' "$env_file"; then
                    sed -i -E "s|^APP_URL=.*|APP_URL=${target_url}|" "$env_file"
                else
                    echo "APP_URL=${target_url}" >> "$env_file"
                fi
                # ASSET_URL (for Vite/Mix asset() helper to prefix subpath)
                if grep -q '^ASSET_URL=' "$env_file"; then
                    sed -i -E "s|^ASSET_URL=.*|ASSET_URL=${target_url}|" "$env_file"
                else
                    echo "ASSET_URL=${target_url}" >> "$env_file"
                fi
                # Trust proxy (Laravel default middleware honors $TRUSTED_PROXIES)
                if [[ "$MS_MODE" == "proxy" ]]; then
                    if grep -q '^TRUSTED_PROXIES=' "$env_file"; then
                        sed -i -E "s|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|" "$env_file"
                    else
                        echo "TRUSTED_PROXIES=*" >> "$env_file"
                    fi
                fi
                sre_success "Laravel .env rewritten (APP_URL=${target_url})"
                # Cache clear
                env_dir=$(dirname "$env_file")
                if [[ -f "${env_dir}/artisan" ]]; then
                    (cd "$env_dir" && sudo -u www-data php artisan config:clear 2>&1 | head -3) || true
                    (cd "$env_dir" && sudo -u www-data php artisan cache:clear 2>&1 | head -3) || true
                    sre_success "Laravel caches cleared."
                fi
            fi
            ;;
        static)
            sre_info "Static site — no app config to rewrite."
            ;;
        *)
            sre_warning "Sub-app type '$sub_type' — no config rewrite available for this type."
            ;;
    esac
fi

# ============================================================================
# Validate + reload
# ============================================================================

sre_header "Validate & Reload"

if ! nginx -t 2>&1; then
    sre_error "nginx -t FAILED. Rolling back snippet (configs left at .bak siblings)."
    rm -f "$snippet_file"
    [[ -L "$internal_link" ]] && rm -f "$internal_link"
    [[ -L "$redirect_link" ]] && rm -f "$redirect_link"
    nginx -t || true
    exit 1
fi

svc_reload nginx
sre_success "Nginx reloaded."

# HTTP probe — `nginx -t` proves syntax, not routing. The host's regex
# `location ~ \.php$` can silently win over our prefix location if the
# template hook is below it; verify by hitting the subpath.
sre_header "HTTP Probe"
probe_url="${target_url}/"
case "$sub_type" in
    moodle)   probe_url="${target_url}/login/index.php" ;;
    laravel)  probe_url="${target_url}/" ;;
    wordpress)probe_url="${target_url}/" ;;
    static)   probe_url="${target_url}/" ;;
esac

probe_status=$(curl -k -s -o /dev/null -w "%{http_code}" -L --max-time 10 "$probe_url" 2>/dev/null || echo "000")
sre_info "GET $probe_url → HTTP $probe_status"
case "$probe_status" in
    200|301|302|303|401|403)
        sre_success "Subpath responds (HTTP $probe_status)."
        ;;
    404)
        sre_warning "HTTP 404 — subpath served but route not found. Check sub-app's expected URL."
        sre_warning "Sometimes the wwwroot rewrite hasn't propagated; try clearing caches again."
        ;;
    000)
        sre_warning "Probe failed to connect. DNS, firewall, or sub-app not running."
        ;;
    502|503|504)
        sre_warning "HTTP $probe_status — upstream (FPM or internal listener) not answering."
        [[ "$MS_MODE" == "proxy" ]] && sre_warning "Verify 127.0.0.1:${MS_INTERNAL_PORT} is listening: ss -lnt | grep ${MS_INTERNAL_PORT}"
        ;;
    *)
        sre_warning "Unexpected HTTP $probe_status; inspect /var/log/nginx/${MS_HOST}-error.log"
        ;;
esac

sre_header "Done"
sre_success "Subpath mount created: ${target_url}"
[[ "$MS_REDIRECT_OLD" == "yes" ]] && sre_info "Old hostname ${MS_SUB} now 301-redirects to ${target_url}"
sre_info "Snippet: $snippet_file"
[[ "$MS_MODE" == "proxy" ]] && sre_info "Internal listener: 127.0.0.1:${MS_INTERNAL_PORT}"

cat <<NEXTSTEPS

Manual verification (run on this server):
  curl -kI ${target_url}/
  curl -kI ${host_scheme}://${MS_SUB}/      # should be 301 → ${target_url}
NEXTSTEPS

[[ "$sub_type" == "moodle" ]] && cat <<MOODLE
  # Moodle-specific:
  curl -kI ${target_url}/login/index.php
  # If logins loop, re-run: sudo -u www-data php $(dirname "$mcf")/admin/cli/purge_caches.php
MOODLE

recommend_next_step "$CURRENT_STEP"
