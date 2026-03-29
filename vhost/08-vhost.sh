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
  --type <type>     Project type: laravel, moodle, nuxt, vue (required, or prompted)
  --root <path>     Document root (default: /var/www/<domain>/current/public)
  --port <port>     Node.js port for Nuxt (default: 3000)
  --dry-run         Print planned actions without executing
  --yes             Accept defaults without prompting
  --config          Override config file path
  --log             Override log file path
  --help            Show this help

Examples:
  sudo bash $0 --domain app.example.com --type laravel
  sudo bash $0 --domain blog.example.com --type vue --root /var/www/blog/dist
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
    VHOST_TYPE=$(prompt_choice "Project type:" "laravel" "moodle" "nuxt" "vue")
fi

# Validate project type
case "$VHOST_TYPE" in
    laravel|moodle|nuxt|vue) ;;
    *) sre_error "Invalid project type: $VHOST_TYPE (must be: laravel, moodle, nuxt, vue)"; exit 1 ;;
esac

# Set default document root based on type
if [[ -z "$VHOST_ROOT" ]]; then
    case "$VHOST_TYPE" in
        laravel) VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current/public" ;;
        moodle)  VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current" ;;
        nuxt)    VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current" ;;
        vue)     VHOST_ROOT="/var/www/${VHOST_DOMAIN}/current/dist" ;;
    esac
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
    sre_info "[DRY-RUN] Would write vhost config to: $vhost_dest"
    sre_info "[DRY-RUN] Template content preview:"
    echo "$vhost_content" | head -5
    echo "..."
fi

sre_success "Virtual host created for $VHOST_DOMAIN ($VHOST_TYPE)"

recommend_next_step "$CURRENT_STEP"
