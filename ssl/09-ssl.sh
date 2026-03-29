#!/bin/bash
################################################################################
# SRE Helpers - Step 9: SSL Certificate Setup
# Obtains Let's Encrypt certificate via Certbot and configures HTTPS.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=9

SSL_DOMAIN=""
SSL_EMAIL=""

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 9: SSL Certificate Setup
  Obtains a Let's Encrypt certificate via Certbot for a domain
  and configures the web server for HTTPS with HTTP-to-HTTPS redirect.

Prerequisites: Virtual host (step 8) must exist for the domain.

Options:
  --domain <name>   Domain name (required, or prompted)
  --email <addr>    Email for Let's Encrypt registration (required, or prompted)
  --dry-run         Print planned actions without executing
  --yes             Accept defaults without prompting
  --config          Override config file path
  --log             Override log file path
  --help            Show this help

Examples:
  sudo bash $0 --domain app.example.com --email admin@example.com
  sudo bash $0 --domain app.example.com --email admin@example.com --dry-run
EOF
}

# Parse script-specific args
_raw_args=("$@")
sre_parse_args "09-ssl.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain) ((_i++)); SSL_DOMAIN="${_raw_args[$_i]:-}" ;;
        --email)  ((_i++)); SSL_EMAIL="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 9: SSL Certificate Setup"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")

# --- Prompt for missing values ---
if [[ -z "$SSL_DOMAIN" ]]; then
    SSL_DOMAIN=$(prompt_input "Domain name for SSL certificate" "")
    [[ -z "$SSL_DOMAIN" ]] && { sre_error "Domain is required."; exit 1; }
fi

if [[ -z "$SSL_EMAIL" ]]; then
    SSL_EMAIL=$(prompt_input "Email for Let's Encrypt registration" "")
    [[ -z "$SSL_EMAIL" ]] && { sre_error "Email is required."; exit 1; }
fi

sre_info "Domain: $SSL_DOMAIN"
sre_info "Email: $SSL_EMAIL"
sre_info "Web Server: $web_server"

# --- Verify vhost exists ---
vhost_exists=false
case "$web_server" in
    nginx)
        case "$os_family" in
            debian) [[ -f "/etc/nginx/sites-available/${SSL_DOMAIN}.conf" ]] && vhost_exists=true ;;
            rhel)   [[ -f "/etc/nginx/conf.d/${SSL_DOMAIN}.conf" ]] && vhost_exists=true ;;
        esac
        ;;
    apache)
        case "$os_family" in
            debian) [[ -f "/etc/apache2/sites-available/${SSL_DOMAIN}.conf" ]] && vhost_exists=true ;;
            rhel)   [[ -f "/etc/httpd/conf.d/${SSL_DOMAIN}.conf" ]] && vhost_exists=true ;;
        esac
        ;;
esac

if [[ "$vhost_exists" != "true" ]]; then
    sre_error "No virtual host found for $SSL_DOMAIN. Run step 8 first."
    exit 2
fi

# --- Check for existing certificate ---
if [[ -d "/etc/letsencrypt/live/${SSL_DOMAIN}" ]]; then
    sre_warning "Certificate already exists for $SSL_DOMAIN"
    if prompt_yesno "Renew/replace the certificate?" "no"; then
        sre_info "Will attempt to renew certificate"
    else
        sre_skipped "SSL setup skipped (certificate already exists)"
        recommend_next_step "$CURRENT_STEP"
        exit 0
    fi
fi

# --- Install Certbot if needed ---
if ! command -v certbot &>/dev/null; then
    sre_info "Installing Certbot..."
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$os_family" in
            debian)
                pkg_install certbot
                case "$web_server" in
                    nginx) pkg_install python3-certbot-nginx ;;
                    apache) pkg_install python3-certbot-apache ;;
                esac
                ;;
            rhel)
                pkg_install certbot
                case "$web_server" in
                    nginx) pkg_install python3-certbot-nginx ;;
                    apache) pkg_install python3-certbot-apache ;;
                esac
                ;;
        esac
        sre_success "Certbot installed"
    else
        sre_info "[DRY-RUN] Would install certbot and web server plugin"
    fi
fi

# --- Obtain Certificate ---
sre_header "Obtaining SSL Certificate"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    certbot_cmd=""
    case "$web_server" in
        nginx)
            certbot_cmd="certbot --nginx -d ${SSL_DOMAIN} --non-interactive --agree-tos --email ${SSL_EMAIL} --redirect"
            ;;
        apache)
            certbot_cmd="certbot --apache -d ${SSL_DOMAIN} --non-interactive --agree-tos --email ${SSL_EMAIL} --redirect"
            ;;
    esac

    sre_info "Running: $certbot_cmd"
    if eval "$certbot_cmd"; then
        sre_success "SSL certificate obtained and configured for $SSL_DOMAIN"
    else
        sre_error "Certbot failed. Check DNS records and ensure port 80 is accessible."
        sre_error "You can retry manually: $certbot_cmd"
        exit 1
    fi

    # Verify auto-renewal timer
    if systemctl list-timers | grep -q certbot; then
        sre_success "Certbot auto-renewal timer is active"
    else
        sre_info "Setting up auto-renewal..."
        systemctl enable --now certbot-renew.timer 2>/dev/null || \
        systemctl enable --now certbot.timer 2>/dev/null || \
        sre_warning "Could not enable auto-renewal timer. Add a cron job: 0 0 * * * certbot renew --quiet"
    fi
else
    sre_info "[DRY-RUN] Would run: certbot --${web_server} -d ${SSL_DOMAIN} --non-interactive --agree-tos --email ${SSL_EMAIL} --redirect"
fi

sre_success "SSL setup complete for $SSL_DOMAIN!"

# This is the last step in the sequence
recommend_next_step "$CURRENT_STEP"
