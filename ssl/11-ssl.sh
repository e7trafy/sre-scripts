#!/bin/bash
################################################################################
# SRE Helpers - Step 11: SSL Certificate Setup
# Obtains Let's Encrypt certificate via Certbot (certonly) and writes a full
# HTTP + HTTPS vhost config with HTTP→HTTPS redirect.
# Does NOT rely on certbot --nginx/--apache plugin rewriting the config.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=11

SSL_DOMAIN=""
SSL_EMAIL=""

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 11: SSL Certificate Setup
  Obtains a Let's Encrypt certificate via Certbot for a domain
  and configures the web server for HTTPS with HTTP→HTTPS redirect.

  Uses certbot certonly (webroot method) — does not rely on the
  certbot nginx/apache plugin rewriting your vhost config.

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
sre_parse_args "11-ssl.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain) ((_i++)); SSL_DOMAIN="${_raw_args[$_i]:-}" ;;
        --email)  ((_i++)); SSL_EMAIL="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 11: SSL Certificate Setup"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")

# --- Prompt for missing values ---
if [[ -z "$SSL_DOMAIN" ]]; then
    SSL_DOMAIN=$(prompt_input "Domain name for SSL certificate" "")
    [[ -z "$SSL_DOMAIN" ]] && { sre_error "Domain is required."; exit 1; }
fi

if [[ -z "$SSL_EMAIL" ]]; then
    SSL_EMAIL=$(prompt_input "Email for Let's Encrypt registration" "")
    [[ -z "$SSL_EMAIL" ]] && { sre_error "Email is required."; exit 1; }
fi

sre_info "Domain:     $SSL_DOMAIN"
sre_info "Email:      $SSL_EMAIL"
sre_info "Web server: $web_server"

# --- Locate existing vhost config ---
vhost_conf=""
case "$web_server" in
    nginx)
        case "$os_family" in
            debian) vhost_conf="/etc/nginx/sites-available/${SSL_DOMAIN}.conf" ;;
            rhel)   vhost_conf="/etc/nginx/conf.d/${SSL_DOMAIN}.conf" ;;
        esac
        ;;
    apache)
        case "$os_family" in
            debian) vhost_conf="/etc/apache2/sites-available/${SSL_DOMAIN}.conf" ;;
            rhel)   vhost_conf="/etc/httpd/conf.d/${SSL_DOMAIN}.conf" ;;
        esac
        ;;
esac

if [[ ! -f "$vhost_conf" ]]; then
    sre_error "No virtual host config found at: $vhost_conf"
    sre_error "Run step 8 first to create the vhost."
    exit 2
fi

sre_info "Vhost config: $vhost_conf"

# --- Extract document root from existing vhost ---
doc_root=""
case "$web_server" in
    nginx)
        doc_root=$(grep -m1 '^\s*root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
        ;;
    apache)
        doc_root=$(grep -im1 'DocumentRoot' "$vhost_conf" | awk '{print $2}')
        ;;
esac

if [[ -z "$doc_root" ]]; then
    sre_warning "Could not auto-detect document root from vhost. Using webroot method with /var/www/html."
    doc_root="/var/www/html"
fi
sre_info "Document root: $doc_root"

# --- Check for existing certificate ---
cert_dir="/etc/letsencrypt/live/${SSL_DOMAIN}"
if [[ -d "$cert_dir" ]]; then
    sre_warning "Certificate already exists for $SSL_DOMAIN"
    if ! prompt_yesno "Renew/replace the certificate?" "no"; then
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
            debian) pkg_install certbot ;;
            rhel)   pkg_install certbot ;;
        esac
        sre_success "Certbot installed"
    else
        sre_info "[DRY-RUN] Would install certbot"
    fi
fi

################################################################################
# Obtain Certificate (webroot method — does not touch vhost config)
################################################################################

sre_header "Obtaining SSL Certificate"

# Ensure .well-known/acme-challenge is accessible for webroot validation.
# We temporarily add a location block if using nginx and the vhost doesn't
# already have it — but the simplest approach is standalone mode if port 80
# is free, or webroot if the server is running.
#
# Strategy: try webroot first (server stays up), fall back to standalone.

acme_webroot="${doc_root}"

if [[ "$SRE_DRY_RUN" != "true" ]]; then

    # Ensure webroot exists for ACME challenge
    mkdir -p "${acme_webroot}/.well-known/acme-challenge"
    case "$web_server" in
        nginx)
            # Add temporary acme-challenge location if not present
            if ! grep -q 'well-known' "$vhost_conf"; then
                sed -i '/server_name/a\    location ^~ /.well-known/acme-challenge/ { root '"${acme_webroot}"'; }' "$vhost_conf"
                svc_reload nginx 2>/dev/null || true
                _added_acme_location=true
            fi
            ;;
        apache)
            if ! grep -qi 'well-known' "$vhost_conf"; then
                sed -i "/<\/VirtualHost>/i\\    Alias /.well-known/acme-challenge/ \"${acme_webroot}/.well-known/acme-challenge/\"" "$vhost_conf"
                case "$os_family" in
                    debian) svc_reload apache2 2>/dev/null || true ;;
                    rhel)   svc_reload httpd   2>/dev/null || true ;;
                esac
                _added_acme_location=true
            fi
            ;;
    esac

    certbot_args=(
        "certonly"
        "--webroot"
        "-w" "$acme_webroot"
        "-d" "$SSL_DOMAIN"
        "--non-interactive"
        "--agree-tos"
        "--email" "$SSL_EMAIL"
    )

    sre_info "Running: certbot ${certbot_args[*]}"
    if ! certbot "${certbot_args[@]}"; then
        sre_warning "Webroot method failed. Trying standalone (requires port 80 free)..."

        # Stop web server temporarily for standalone
        case "$web_server" in
            nginx)  systemctl stop nginx  2>/dev/null || true ;;
            apache) case "$os_family" in
                        debian) systemctl stop apache2 2>/dev/null || true ;;
                        rhel)   systemctl stop httpd   2>/dev/null || true ;;
                    esac ;;
        esac

        certbot certonly \
            --standalone \
            -d "$SSL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --email "$SSL_EMAIL" || {
            sre_error "Certbot failed (both webroot and standalone)."
            sre_error "Check:"
            sre_error "  1. DNS: dig $SSL_DOMAIN  (must point to this server)"
            sre_error "  2. Port 80 is open in your firewall/security group"
            sre_error "  3. Port 443 is open in your firewall/security group"
            # Restart web server before exiting
            case "$web_server" in
                nginx)  systemctl start nginx  2>/dev/null || true ;;
                apache) case "$os_family" in
                            debian) systemctl start apache2 2>/dev/null || true ;;
                            rhel)   systemctl start httpd   2>/dev/null || true ;;
                        esac ;;
            esac
            exit 1
        }

        # Restart web server after standalone
        case "$web_server" in
            nginx)  systemctl start nginx  2>/dev/null || true ;;
            apache) case "$os_family" in
                        debian) systemctl start apache2 2>/dev/null || true ;;
                        rhel)   systemctl start httpd   2>/dev/null || true ;;
                    esac ;;
        esac
    fi

    sre_success "Certificate obtained: $cert_dir"

else
    sre_info "[DRY-RUN] Would run: certbot certonly --webroot -w $acme_webroot -d $SSL_DOMAIN ..."
fi

################################################################################
# Write full HTTPS vhost config (HTTP redirect + HTTPS server block)
################################################################################

sre_header "Writing HTTPS Vhost Config"

cert_pem="${cert_dir}/fullchain.pem"
cert_key="${cert_dir}/privkey.pem"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    backup_config "$vhost_conf"
fi

case "$web_server" in
    nginx)
        # Detect vhost type from existing config content to preserve PHP/proxy setup
        vhost_type="generic"
        if grep -q 'fastcgi_pass' "$vhost_conf" 2>/dev/null; then
            if grep -q 'pluginfile.php\|moodledata' "$vhost_conf" 2>/dev/null; then
                vhost_type="moodle"
            else
                vhost_type="laravel"
            fi
        elif grep -q 'proxy_pass' "$vhost_conf" 2>/dev/null; then
            vhost_type="nuxt"
        elif grep -q 'try_files.*index.html' "$vhost_conf" 2>/dev/null; then
            vhost_type="vue"
        fi

        sre_info "Detected vhost type: $vhost_type"

        # Read the existing server block content (everything inside the braces)
        # and reuse it for the HTTPS block — preserving all location/PHP config
        existing_inner=""
        existing_inner=$(sed -n '/^server {/,/^}$/p' "$vhost_conf" \
            | sed '1d;$d' \
            | grep -v 'listen 80\|listen \[::\]:80\|well-known\|acme-challenge')

        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            cat > "$vhost_conf" <<NGINX_CONF
# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${SSL_DOMAIN};

    # Allow ACME challenge through before redirect
    location ^~ /.well-known/acme-challenge/ {
        root ${acme_webroot};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name ${SSL_DOMAIN};

    ssl_certificate     ${cert_pem};
    ssl_certificate_key ${cert_key};

    # Modern SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS (6 months)
    add_header Strict-Transport-Security "max-age=15768000" always;

${existing_inner}
}
NGINX_CONF
            sre_success "HTTPS vhost written: $vhost_conf"

            # Test and reload
            if nginx -t 2>&1; then
                sre_success "Nginx config test passed"
                svc_reload nginx
                sre_success "Nginx reloaded"
            else
                sre_error "Nginx config test failed — restoring backup"
                backup_file=$(ls -t "${vhost_conf}".*.bak 2>/dev/null | head -1)
                [[ -n "$backup_file" ]] && cp "$backup_file" "$vhost_conf"
                svc_reload nginx
                exit 1
            fi
        else
            sre_info "[DRY-RUN] Would write HTTPS nginx config to $vhost_conf"
        fi
        ;;

    apache)
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            # Enable required modules
            a2enmod ssl rewrite headers 2>/dev/null || true

            # Read existing VirtualHost inner content (port 80 block)
            existing_inner=""
            existing_inner=$(sed -n '/<VirtualHost/,/<\/VirtualHost>/p' "$vhost_conf" \
                | sed '1d;$d' \
                | grep -v 'well-known\|acme-challenge')

            cat > "$vhost_conf" <<APACHE_CONF
# HTTP → HTTPS redirect
<VirtualHost *:80>
    ServerName ${SSL_DOMAIN}

    # Allow ACME challenge
    Alias /.well-known/acme-challenge/ "${acme_webroot}/.well-known/acme-challenge/"
    <Directory "${acme_webroot}/.well-known/acme-challenge/">
        Require all granted
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/.well-known/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

# HTTPS server
<VirtualHost *:443>
    ServerName ${SSL_DOMAIN}

    SSLEngine on
    SSLCertificateFile    ${cert_pem}
    SSLCertificateKeyFile ${cert_key}

    # Modern SSL settings
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder off
    SSLSessionTickets off

    # HSTS
    Header always set Strict-Transport-Security "max-age=15768000"

${existing_inner}
</VirtualHost>
APACHE_CONF
            sre_success "HTTPS vhost written: $vhost_conf"

            # Test and reload
            test_cmd=""
            reload_cmd=""
            case "$os_family" in
                debian)
                    test_cmd="apachectl configtest"
                    reload_svc="apache2"
                    ;;
                rhel)
                    test_cmd="httpd -t"
                    reload_svc="httpd"
                    ;;
            esac

            if $test_cmd 2>&1; then
                sre_success "Apache config test passed"
                svc_reload "$reload_svc"
                sre_success "Apache reloaded"
            else
                sre_error "Apache config test failed — restoring backup"
                backup_file=$(ls -t "${vhost_conf}".*.bak 2>/dev/null | head -1)
                [[ -n "$backup_file" ]] && cp "$backup_file" "$vhost_conf"
                svc_reload "$reload_svc"
                exit 1
            fi
        else
            sre_info "[DRY-RUN] Would write HTTPS apache config to $vhost_conf"
        fi
        ;;
esac

################################################################################
# Auto-renewal
################################################################################

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    renewal_enabled=false
    for timer_name in certbot-renew.timer certbot.timer snap.certbot.renew.timer; do
        if systemctl list-unit-files "$timer_name" &>/dev/null 2>&1; then
            systemctl enable --now "$timer_name" 2>/dev/null && renewal_enabled=true && break
        fi
    done
    if [[ "$renewal_enabled" == "true" ]]; then
        sre_success "Auto-renewal timer enabled"
    else
        sre_warning "Could not enable auto-renewal timer — adding cron fallback..."
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true'") | crontab -
        sre_success "Auto-renewal cron added (daily 03:00)"
    fi
fi

sre_success "SSL setup complete for ${SSL_DOMAIN}!"
sre_info "  HTTP  → redirects to HTTPS"
sre_info "  HTTPS → https://${SSL_DOMAIN}"
sre_info "  Cert  → ${cert_pem}"
echo ""
sre_warning "If HTTPS is still unreachable, check your firewall/security group:"
sre_warning "  Port 443 must be open (Oracle Cloud: Security Lists → Ingress Rules)"

recommend_next_step "$CURRENT_STEP"
