#!/bin/bash
################################################################################
# SRE Helpers - Step 3: Web Server Installation
# Installs and configures Nginx or Apache with secure defaults.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=3

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 3: Web Server Installation
  Installs Nginx or Apache based on the SRE_WEB_SERVER config value
  set during step 1. Applies secure defaults (hide version, add
  security headers).

Prerequisites: Step 1 (base-setup) must be complete.

Options:
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --dry-run
EOF
}

sre_parse_args "03-web-server.sh" "$@"
require_root

sre_header "Step 3: Web Server Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(require_config_key "SRE_WEB_SERVER" "1")
os_family=$(require_config_key "SRE_OS_FAMILY" "1")

sre_info "Web server selected: $web_server"
sre_info "OS family: $os_family"

# --- Check for port conflicts ---
if port_in_use 80; then
    sre_warning "Port 80 is already in use. Installation will continue but the service may fail to start."
fi
if port_in_use 443; then
    sre_warning "Port 443 is already in use. Installation will continue but the service may fail to start."
fi

# --- Install and configure web server ---
case "$web_server" in
    nginx)
        sre_info "Installing Nginx..."

        if pkg_is_installed nginx; then
            sre_skipped "Nginx is already installed."
        else
            pkg_install nginx
            sre_success "Nginx installed."
        fi

        svc_enable_start nginx

        # Apply secure defaults
        local_nginx_conf="/etc/nginx/nginx.conf"
        local_snippets_dir="/etc/nginx/conf.d"

        sre_info "Applying secure Nginx defaults..."

        nginx_security_conf="${local_snippets_dir}/security.conf"
        nginx_security_content=$(cat <<'NGINX_EOF'
# SRE Helpers - Nginx security defaults
server_tokens off;

add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
NGINX_EOF
)

        sre_write_file "$nginx_security_conf" "$nginx_security_content"

        # Validate and reload
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            if nginx -t 2>/dev/null; then
                svc_reload nginx
                sre_success "Nginx configuration validated and reloaded."
            else
                sre_warning "Nginx configuration test failed. Check the config manually."
            fi
        else
            sre_info "[DRY-RUN] Would validate and reload Nginx."
        fi
        ;;

    apache)
        sre_info "Installing Apache..."

        case "$os_family" in
            debian)
                if pkg_is_installed apache2; then
                    sre_skipped "Apache is already installed."
                else
                    pkg_install apache2
                    sre_success "Apache installed."
                fi

                # Enable required modules
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    for mod in mpm_event rewrite headers ssl proxy_fcgi; do
                        a2enmod -q "$mod" 2>/dev/null || true
                        sre_info "Enabled Apache module: $mod"
                    done
                else
                    sre_info "[DRY-RUN] Would enable modules: mpm_event, rewrite, headers, ssl, proxy_fcgi"
                fi

                svc_enable_start apache2

                # Apply secure defaults
                apache_security_conf="/etc/apache2/conf-available/security.conf"
                apache_security_content=$(cat <<'APACHE_EOF'
# SRE Helpers - Apache security defaults
ServerTokens Prod
ServerSignature Off

Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
APACHE_EOF
)

                sre_write_file "$apache_security_conf" "$apache_security_content"

                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    a2enconf security 2>/dev/null || true
                    if apachectl configtest 2>/dev/null; then
                        svc_reload apache2
                        sre_success "Apache configuration validated and reloaded."
                    else
                        sre_warning "Apache configuration test failed. Check the config manually."
                    fi
                else
                    sre_info "[DRY-RUN] Would enable security conf and reload Apache."
                fi
                ;;

            rhel)
                if pkg_is_installed httpd; then
                    sre_skipped "Apache (httpd) is already installed."
                else
                    pkg_install httpd mod_ssl
                    sre_success "Apache (httpd) and mod_ssl installed."
                fi

                svc_enable_start httpd

                # Apply secure defaults
                apache_security_conf="/etc/httpd/conf.d/security.conf"
                apache_security_content=$(cat <<'APACHE_EOF'
# SRE Helpers - Apache security defaults
ServerTokens Prod
ServerSignature Off

Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
APACHE_EOF
)

                sre_write_file "$apache_security_conf" "$apache_security_content"

                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    if httpd -t 2>/dev/null; then
                        svc_reload httpd
                        sre_success "Apache configuration validated and reloaded."
                    else
                        sre_warning "Apache configuration test failed. Check the config manually."
                    fi
                else
                    sre_info "[DRY-RUN] Would validate and reload Apache (httpd)."
                fi
                ;;
        esac
        ;;

    *)
        sre_error "Unknown web server: $web_server. Expected 'nginx' or 'apache'."
        exit 2
        ;;
esac

config_set "SRE_WEB_SERVER_INSTALLED" "true"

sre_success "Web server ($web_server) installation complete!"

recommend_next_step "$CURRENT_STEP"
