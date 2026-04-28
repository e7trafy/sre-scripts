#!/bin/bash
################################################################################
# SRE Helpers - Step 8: Virtual Host Setup
# Creates a virtual host configuration for a project.
# Supports: Laravel, Moodle, Nuxt, Vue on Nginx or Apache.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=8

VHOST_DOMAIN=""
VHOST_TYPE=""
VHOST_ROOT=""
VHOST_PORT="3000"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 8: Virtual Host Setup
  Creates a web server virtual host for a project.
  Supports Laravel, Moodle, Nuxt, and Vue project types.

Prerequisites: Web server (step 3) must be installed.

Options:
  --domain <name>   Domain name (required, or prompted)
  --type <type>     Project type: laravel, moodle, wordpress, nuxt, vue, static (required, or prompted)
  --root <path>     Document root (default: /var/www/<domain>/current/public)
  --port <port>     Node.js port for Nuxt (default: 3000)
  --dry-run         Print planned actions without executing
  --yes             Accept defaults without prompting
  --config          Override config file path
  --log             Override log file path
  --help            Show this help

Examples:
  sudo bash $0 --domain app.example.com --type laravel
  sudo bash $0 --domain blog.example.com --type wordpress
  sudo bash $0 --domain landing.example.com --type static
  sudo bash $0 --domain spa.example.com --type vue --root /var/www/spa/dist
  sudo bash $0 --domain ssr.example.com --type nuxt --port 3001
EOF
}

# Parse script-specific args before common parsing
_raw_args=("$@")
sre_parse_args "08-vhost.sh" "${_raw_args[@]}"

# Parse extra args for --domain, --type, --root, --port
_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain) ((_i++)); VHOST_DOMAIN="${_raw_args[$_i]:-}" ;;
        --type)   ((_i++)); VHOST_TYPE="${_raw_args[$_i]:-}" ;;
        --root)   ((_i++)); VHOST_ROOT="${_raw_args[$_i]:-}" ;;
        --port)   ((_i++)); VHOST_PORT="${_raw_args[$_i]:-3000}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 8: Virtual Host Setup"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
ws_installed=$(config_get "SRE_WEB_SERVER_INSTALLED" "")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")
os_family=$(config_get "SRE_OS_FAMILY" "debian")

if [[ "$ws_installed" != "true" && -z "$web_server" ]]; then
    sre_error "Web server not installed. Run step 3 first."
    exit 2
fi

# --- Prompt for missing values ---
if [[ -z "$VHOST_DOMAIN" ]]; then
    VHOST_DOMAIN=$(prompt_input "Domain name" "")
    [[ -z "$VHOST_DOMAIN" ]] && { sre_error "Domain is required."; exit 1; }
fi

if [[ -z "$VHOST_TYPE" ]]; then
    VHOST_TYPE=$(prompt_choice "Project type:" "laravel" "moodle" "wordpress" "nuxt" "vue" "static")
fi

# Validate project type
case "$VHOST_TYPE" in
    laravel|moodle|wordpress|nuxt|vue|static) ;;
    *) sre_error "Invalid project type: $VHOST_TYPE (must be: laravel, moodle, wordpress, nuxt, vue, static)"; exit 1 ;;
esac

# Set default document root based on type
if [[ -z "$VHOST_ROOT" ]]; then
    case "$VHOST_TYPE" in
        laravel)   VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current/public" ;;
        moodle)    VHOST_ROOT="/var/www/${VHOST_DOMAIN}/public_html" ;;
        wordpress) VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current" ;;
        nuxt)      VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current" ;;
        vue)       VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current/dist" ;;
        static)    VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current" ;;
    esac
fi

# Select PHP version for this project (Laravel/Moodle/WordPress only)
if [[ "$VHOST_TYPE" == "laravel" || "$VHOST_TYPE" == "moodle" || "$VHOST_TYPE" == "wordpress" ]]; then
    extra_versions=$(config_get "SRE_PHP_EXTRA_VERSIONS" "")
    if [[ -n "$extra_versions" ]]; then
        # Build list of available versions
        available_versions=("$php_version")
        IFS=',' read -ra _extra <<< "$extra_versions"
        for v in "${_extra[@]}"; do
            v=$(echo "$v" | tr -d ' ')
            [[ -n "$v" && "$v" != "$php_version" ]] && available_versions+=("$v")
        done

        if [[ ${#available_versions[@]} -gt 1 ]]; then
            php_version=$(prompt_choice "PHP version for this project:" "${available_versions[@]}")
        fi
    fi
    sre_info "PHP version: $php_version"
fi

sre_info "Domain: $VHOST_DOMAIN"
sre_info "Type: $VHOST_TYPE"
sre_info "Root: $VHOST_ROOT"
sre_info "Web Server: $web_server"
[[ "$VHOST_TYPE" == "nuxt" ]] && sre_info "Node port: $VHOST_PORT"

# --- Select and process template ---
TEMPLATE_DIR="${SCRIPT_DIR}/vhost/templates"
template_file="${TEMPLATE_DIR}/${web_server}-${VHOST_TYPE}.conf"

if [[ ! -f "$template_file" ]]; then
    sre_error "Template not found: $template_file"
    sre_error "Supported combinations: ${web_server}-laravel, ${web_server}-moodle"
    [[ "$web_server" == "nginx" ]] && sre_error "Also: nginx-nuxt, nginx-vue"
    exit 1
fi

sre_info "Using template: $template_file"

# Read and substitute placeholders
vhost_content=$(cat "$template_file")
vhost_content="${vhost_content//\{DOMAIN\}/$VHOST_DOMAIN}"
vhost_content="${vhost_content//\{DOCUMENT_ROOT\}/$VHOST_ROOT}"
vhost_content="${vhost_content//\{PHP_VERSION\}/$php_version}"
vhost_content="${vhost_content//\{PORT\}/$VHOST_PORT}"

# --- Determine destination path ---
case "$web_server" in
    nginx)
        case "$os_family" in
            debian)
                vhost_dest="/etc/nginx/sites-available/${VHOST_DOMAIN}.conf"
                vhost_link="/etc/nginx/sites-enabled/${VHOST_DOMAIN}.conf"
                ;;
            rhel)
                vhost_dest="/etc/nginx/conf.d/${VHOST_DOMAIN}.conf"
                vhost_link="" # RHEL uses conf.d directly
                ;;
        esac
        ;;
    apache)
        case "$os_family" in
            debian)
                vhost_dest="/etc/apache2/sites-available/${VHOST_DOMAIN}.conf"
                vhost_link="/etc/apache2/sites-enabled/${VHOST_DOMAIN}.conf"
                ;;
            rhel)
                vhost_dest="/etc/httpd/conf.d/${VHOST_DOMAIN}.conf"
                vhost_link=""
                ;;
        esac
        ;;
esac

# --- Check for existing vhost ---
if [[ -f "$vhost_dest" ]]; then
    sre_warning "Vhost config already exists: $vhost_dest"
    if prompt_yesno "Overwrite? (backup will be created)" "yes"; then
        backup_config "$vhost_dest"
    else
        sre_skipped "Vhost creation cancelled"
        exit 4
    fi
fi

# --- Write vhost config ---
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    # Create document root if it doesn't exist
    mkdir -p "$VHOST_ROOT" 2>/dev/null || true

    # --- Set FACL permissions on project and data directories ---
    sre_info "Setting filesystem ACLs for www-data access..."

    require_acl

    project_base="/var/www/${VHOST_DOMAIN}"

    # Set ownership
    chown -R www-data:www-data "$project_base"

    # Default ACL: www-data gets rwx on all new files/dirs automatically
    setfacl -R -m u:www-data:rwX "$project_base"
    setfacl -R -d -m u:www-data:rwX "$project_base"

    # For Moodle: set ACL on moodledata (may be on external block storage)
    if [[ "$VHOST_TYPE" == "moodle" ]]; then
        default_moodledata="/var/www/${VHOST_DOMAIN}/moodledata"
        moodledata=$(prompt_input "Moodledata path (may be on block storage)" "$default_moodledata")

        mkdir -p "$moodledata"
        chown -R www-data:www-data "$moodledata"
        setfacl -R -m u:www-data:rwX "$moodledata"
        setfacl -R -d -m u:www-data:rwX "$moodledata"
        chmod 2770 "$moodledata"

        # Ensure the filesystem supports ACLs (block storage may need acl mount option)
        mount_point=$(df "$moodledata" --output=target 2>/dev/null | tail -1)
        if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
            if ! mount | grep "$mount_point" | grep -q "acl"; then
                sre_warning "Block storage at $mount_point may need 'acl' mount option"
                sre_warning "Add 'acl' to mount options in /etc/fstab if ACLs don't persist after reboot"
            fi
        fi

        sre_success "FACL set on moodledata: $moodledata"
    fi

    # For Laravel: ensure storage and cache dirs have proper ACLs
    if [[ "$VHOST_TYPE" == "laravel" ]]; then
        for subdir in storage bootstrap/cache; do
            target="${project_base}/current/${subdir}"
            if [[ -d "$target" ]]; then
                setfacl -R -m u:www-data:rwX "$target"
                setfacl -R -d -m u:www-data:rwX "$target"
            fi
        done
        # Also set on shared storage (symlinked)
        # shared_storage="${project_base}/shared/storage"
        shared_storage="${project_base}/current/storage"
        if [[ -d "$shared_storage" ]]; then
            setfacl -R -m u:www-data:rwX "$shared_storage"
            setfacl -R -d -m u:www-data:rwX "$shared_storage"
        fi
    fi

    sre_success "FACL permissions configured on $project_base"

    echo "$vhost_content" > "$vhost_dest"
    sre_success "Written vhost config: $vhost_dest"

    # Create symlink for Debian-style sites-enabled
    if [[ -n "$vhost_link" ]]; then
        ln -sf "$vhost_dest" "$vhost_link"
        sre_success "Enabled site: $vhost_link"
    fi

    # Test configuration
    case "$web_server" in
        nginx)
            if nginx -t 2>&1; then
                sre_success "Nginx config test passed"
                svc_reload nginx
                sre_success "Nginx reloaded"
            else
                sre_error "Nginx config test failed! Check: $vhost_dest"
                exit 1
            fi
            ;;
        apache)
            test_cmd=""
            case "$os_family" in
                debian) test_cmd="apachectl configtest" ;;
                rhel)   test_cmd="httpd -t" ;;
            esac
            if $test_cmd 2>&1; then
                sre_success "Apache config test passed"
                case "$os_family" in
                    debian) svc_reload apache2 ;;
                    rhel)   svc_reload httpd ;;
                esac
                sre_success "Apache reloaded"
            else
                sre_error "Apache config test failed! Check: $vhost_dest"
                exit 1
            fi
            ;;
    esac
else
    sre_info "[DRY-RUN] Would set FACL on /var/www/${VHOST_DOMAIN} (www-data:rwX + default ACL)"
    [[ "$VHOST_TYPE" == "moodle" ]] && sre_info "[DRY-RUN] Would set FACL on moodledata (prompted path, may be external block storage)"
    [[ "$VHOST_TYPE" == "laravel" ]] && sre_info "[DRY-RUN] Would set FACL on storage + bootstrap/cache"
    sre_info "[DRY-RUN] Would write vhost config to: $vhost_dest"
    sre_info "[DRY-RUN] Template content preview:"
    echo "$vhost_content" | head -5
    echo "..."
fi

sre_success "Virtual host created for $VHOST_DOMAIN ($VHOST_TYPE)"

# --- Supervisor Queue Worker (Laravel only) ---
if [[ "$VHOST_TYPE" == "laravel" ]] && [[ "$(config_get SRE_SUPERVISOR)" == "true" ]]; then
    if prompt_yesno "Setup Supervisor queue worker for this Laravel project?" "yes"; then
        sre_header "Supervisor Queue Worker"

        project_base="/var/www/${VHOST_DOMAIN}"

        worker_queue=$(prompt_input "Queue name" "default")
        worker_processes=$(prompt_input "Number of worker processes" "2")
        worker_tries=$(prompt_input "Max retries per job" "3")
        worker_timeout=$(prompt_input "Job timeout (seconds)" "90")

        setup_horizon="no"
        if prompt_yesno "Use Laravel Horizon instead of default queue:work?" "no"; then
            setup_horizon="yes"
        fi

        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            supervisor_conf_dir="/etc/supervisor/conf.d"
            [[ "$SRE_OS_FAMILY" == "rhel" ]] && supervisor_conf_dir="/etc/supervisord.d"
            mkdir -p "$supervisor_conf_dir"

            if [[ "$setup_horizon" == "yes" ]]; then
                cat > "${supervisor_conf_dir}/${VHOST_DOMAIN}-horizon.conf" <<HORIZONEOF
[program:${VHOST_DOMAIN}-horizon]
process_name=%(program_name)s
command=php ${project_base}/current/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${project_base}/current/storage/logs/horizon.log
stopwaitsecs=3600
HORIZONEOF
                sre_success "Horizon worker config created: ${supervisor_conf_dir}/${VHOST_DOMAIN}-horizon.conf"
            else
                cat > "${supervisor_conf_dir}/${VHOST_DOMAIN}-worker.conf" <<WORKEREOF
[program:${VHOST_DOMAIN}-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${project_base}/current/artisan queue:work --sleep=3 --tries=${worker_tries} --timeout=${worker_timeout} --queue=${worker_queue}
autostart=true
autorestart=true
user=www-data
numprocs=${worker_processes}
redirect_stderr=true
stdout_logfile=${project_base}/current/storage/logs/worker.log
stopwaitsecs=3600
WORKEREOF
                sre_success "Queue worker config created: ${supervisor_conf_dir}/${VHOST_DOMAIN}-worker.conf"
            fi

            # Setup scheduler cron
            if prompt_yesno "Also setup Laravel scheduler cron?" "yes"; then
                cron_line="* * * * * www-data cd ${project_base}/current && php artisan schedule:run >> /dev/null 2>&1"
                cron_file="/etc/cron.d/${VHOST_DOMAIN//\./-}-scheduler"
                echo "$cron_line" > "$cron_file"
                chmod 644 "$cron_file"
                sre_success "Scheduler cron created: $cron_file"
            fi

            supervisorctl reread 2>/dev/null || true
            supervisorctl update 2>/dev/null || true
            sre_success "Supervisor updated — workers starting"
        else
            sre_info "[DRY-RUN] Would create supervisor worker config for $VHOST_DOMAIN"
            [[ "$setup_horizon" == "yes" ]] && sre_info "[DRY-RUN] Using Horizon" || sre_info "[DRY-RUN] Using queue:work ($worker_processes processes)"
        fi
    fi
fi

recommend_next_step "$CURRENT_STEP"
