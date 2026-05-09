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
SSL_PREFER_WILDCARD="yes"   # auto-detect existing wildcard cert before LE
SSL_WILDCARD_DIR=""         # extra search dir for non-LE wildcard certs
SSL_FORCE_LE="false"        # skip wildcard detection entirely

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 11: SSL Certificate Setup
  Configures HTTPS for a domain with HTTP→HTTPS redirect.

  Cert source precedence (highest first):
    1. Existing WILDCARD certificate covering the domain
       Searches /etc/letsencrypt/live/* and any --wildcard-dir.
    2. Existing exact-match certificate at /etc/letsencrypt/live/<domain>
    3. Let's Encrypt via Certbot (webroot, then standalone fallback)

  Uses certbot certonly (webroot method) when issuing — does not rely on
  the certbot nginx/apache plugin rewriting your vhost config.

Prerequisites: Virtual host (step 8) must exist for the domain.

Options:
  --domain <name>      Domain name (required, or prompted)
  --email <addr>       Email for Let's Encrypt (required only if no wildcard)
  --wildcard-dir <p>   Extra dir to scan for non-LE wildcard certs.
                       Layout: <p>/<base.domain>/{fullchain.pem,privkey.pem}
  --no-wildcard        Skip wildcard detection, force Let's Encrypt
  --dry-run            Print planned actions without executing
  --yes                Accept defaults without prompting
  --config             Override config file path
  --log                Override log file path
  --help               Show this help

Examples:
  sudo bash $0 --domain app.example.com --email admin@example.com
  sudo bash $0 --domain app.example.com --no-wildcard --email admin@example.com
  sudo bash $0 --domain app.example.com --wildcard-dir /etc/ssl/wildcards
EOF
}

# Parse script-specific args
_raw_args=("$@")
sre_parse_args "11-ssl.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)        _i=$((_i + 1)); SSL_DOMAIN="${_raw_args[$_i]:-}" ;;
        --email)         _i=$((_i + 1)); SSL_EMAIL="${_raw_args[$_i]:-}" ;;
        --wildcard-dir)  _i=$((_i + 1)); SSL_WILDCARD_DIR="${_raw_args[$_i]:-}" ;;
        --no-wildcard)   SSL_FORCE_LE="true"; SSL_PREFER_WILDCARD="no" ;;
    esac
    _i=$((_i + 1))
done

require_root

sre_header "Step 11: SSL Certificate Setup"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")

# --- List available domains ---
sre_header "Available Domains"

available_domains=()
case "$web_server" in
    nginx)
        case "$os_family" in
            debian) vhost_dir="/etc/nginx/sites-available" ;;
            rhel)   vhost_dir="/etc/nginx/conf.d" ;;
        esac
        ;;
    apache)
        case "$os_family" in
            debian) vhost_dir="/etc/apache2/sites-available" ;;
            rhel)   vhost_dir="/etc/httpd/conf.d" ;;
        esac
        ;;
esac

if [[ -d "$vhost_dir" ]]; then
    while IFS= read -r conf_file; do
        domain_name=$(basename "$conf_file" .conf)
        # Skip default configs
        [[ "$domain_name" == "default" || "$domain_name" == "000-default" || "$domain_name" == "security" ]] && continue
        # Check if already has SSL
        if grep -q "ssl_certificate\|SSLCertificateFile" "$conf_file" 2>/dev/null; then
            sre_info "  [SSL] $domain_name"
        else
            sre_info "  [HTTP] $domain_name"
            available_domains+=("$domain_name")
        fi
    done < <(find "$vhost_dir" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)
fi

if [[ ${#available_domains[@]} -eq 0 && -z "$SSL_DOMAIN" ]]; then
    sre_warning "No HTTP-only domains found. All domains may already have SSL."
    sre_info "You can still specify a domain manually to renew/replace its certificate."
fi

# --- Prompt for missing values ---
if [[ -z "$SSL_DOMAIN" ]]; then
    if [[ ${#available_domains[@]} -gt 0 ]]; then
        SSL_DOMAIN=$(prompt_choice "Select domain for SSL:" "${available_domains[@]}")
    else
        SSL_DOMAIN=$(prompt_input "Domain name for SSL certificate" "")
    fi
    [[ -z "$SSL_DOMAIN" ]] && { sre_error "Domain is required."; exit 1; }
fi

sre_info "Domain:     $SSL_DOMAIN"
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

# --- Extract proxy port from existing vhost (Nuxt reverse proxy) ---
nuxt_port=""
if grep -q 'proxy_pass' "$vhost_conf" 2>/dev/null; then
    nuxt_port=$(grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "$vhost_conf" | head -1)
    [[ -z "$nuxt_port" ]] && nuxt_port="3000"
    sre_info "Nuxt proxy port: $nuxt_port"
fi

# --- Check for existing certificate ---
cert_dir="/etc/letsencrypt/live/${SSL_DOMAIN}"

################################################################################
# Wildcard certificate detection
#
# If a wildcard cert (e.g. *.example.com) covers the domain, reuse it instead
# of requesting a new Let's Encrypt cert. Skips Certbot entirely on hit.
#
# Search locations (in order):
#   1. /etc/letsencrypt/live/*           — LE-issued wildcards
#   2. $SSL_WILDCARD_DIR/<base>/         — manually-installed wildcards
#   3. /etc/ssl/wildcards/<base>/        — default extra location
#
# A cert "matches" the domain if its SANs include *.<parent> for any parent
# label of the domain, OR the bare parent itself.
################################################################################

SSL_USE_WILDCARD="false"
SSL_WILDCARD_CERT=""
SSL_WILDCARD_KEY=""
SSL_WILDCARD_SOURCE=""

# Build list of parent domains that a wildcard could match.
# For app.staging.example.com, candidates are:
#   *.staging.example.com  (matches app)
#   *.example.com          (matches staging.example.com — only if domain has 3+ labels with that parent)
# Wildcards match exactly one label so we generate one entry per ancestor with
# at least one label below it.
_build_wildcard_candidates() {
    local d="$1"
    local result=()
    # Strip first label until 1 label remains
    while [[ "$d" == *.* ]]; do
        local parent="${d#*.}"
        # Only meaningful if parent itself has a dot (skip "tld" alone)
        [[ "$parent" == *.* ]] || break
        result+=("*.${parent}")
        d="$parent"
    done
    printf '%s\n' "${result[@]}"
}

# Verify a cert+key pair covers the domain via a wildcard SAN match
# Args: cert_path
# Returns 0 + prints matching SAN if match, 1 otherwise
_cert_covers_domain() {
    local cert="$1" domain="$2"
    [[ ! -r "$cert" ]] && return 1
    command -v openssl &>/dev/null || return 1

    # Get all SANs (DNS:foo, DNS:*.bar) from the cert
    local sans
    sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | grep -oP 'DNS:\K[^,\s]+' || true)
    [[ -z "$sans" ]] && return 1

    # Direct exact match (rare but possible)
    while IFS= read -r san; do
        [[ -z "$san" ]] && continue
        if [[ "$san" == "$domain" ]]; then
            echo "$san"
            return 0
        fi
        # Wildcard *.parent matches first label of domain only
        if [[ "$san" == \*.* ]]; then
            local parent="${san#*.}"
            # Domain must end with .parent and have exactly one extra label before it
            if [[ "$domain" == *.${parent} ]]; then
                local prefix="${domain%.${parent}}"
                # prefix must be a single label (no dots)
                if [[ -n "$prefix" && "$prefix" != *.* ]]; then
                    echo "$san"
                    return 0
                fi
            fi
        fi
    done <<<"$sans"
    return 1
}

# Verify cert is not expired and warn if expiring soon (<30d)
_cert_expiry_check() {
    local cert="$1"
    if ! openssl x509 -in "$cert" -noout -checkend 0 &>/dev/null; then
        sre_error "  Certificate is EXPIRED: $cert"
        return 1
    fi
    if ! openssl x509 -in "$cert" -noout -checkend $((30*86400)) &>/dev/null; then
        local enddate
        enddate=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        sre_warning "  Certificate expires within 30 days: $enddate"
    fi
    return 0
}

# Search dirs and emit matching cert paths
_find_wildcard_cert() {
    local domain="$1"
    local search_dirs=()
    [[ -d /etc/letsencrypt/live ]] && search_dirs+=(/etc/letsencrypt/live)
    [[ -n "$SSL_WILDCARD_DIR" && -d "$SSL_WILDCARD_DIR" ]] && search_dirs+=("$SSL_WILDCARD_DIR")
    [[ -d /etc/ssl/wildcards ]] && search_dirs+=(/etc/ssl/wildcards)

    [[ ${#search_dirs[@]} -eq 0 ]] && return 1

    local d cert_path key_path matched_san
    for d in "${search_dirs[@]}"; do
        # Each subdir holds a fullchain.pem + privkey.pem (LE convention)
        while IFS= read -r cert_path; do
            [[ -z "$cert_path" ]] && continue
            [[ ! -f "$cert_path" ]] && continue

            # Skip the exact-match dir for the domain we're configuring —
            # that's not a "wildcard reuse", that's a normal renewal.
            local subdir
            subdir=$(basename "$(dirname "$cert_path")")
            [[ "$subdir" == "$domain" ]] && continue

            # Try matching
            if matched_san=$(_cert_covers_domain "$cert_path" "$domain"); then
                # Only consider it a "wildcard" hit if the matching SAN is *.something
                # (don't auto-reuse another exact-match cert for a different domain)
                [[ "$matched_san" != \*.* ]] && continue

                # Look for sibling key
                local certdir
                certdir=$(dirname "$cert_path")
                key_path="${certdir}/privkey.pem"
                [[ ! -f "$key_path" ]] && continue

                # Validate not expired
                _cert_expiry_check "$cert_path" || continue

                printf '%s|%s|%s\n' "$cert_path" "$key_path" "$matched_san"
                return 0
            fi
        done < <(find "$d" -maxdepth 2 -name 'fullchain.pem' -type f 2>/dev/null)
    done
    return 1
}

if [[ "$SSL_FORCE_LE" != "true" ]] && [[ "$SSL_PREFER_WILDCARD" == "yes" ]]; then
    sre_header "Checking for Existing Wildcard Certificate"

    if ! command -v openssl &>/dev/null; then
        sre_warning "openssl not found — cannot scan for wildcard certs. Falling back to Let's Encrypt."
    else
        sre_info "Scanning for wildcard certs covering $SSL_DOMAIN..."
        wc_match=$(_find_wildcard_cert "$SSL_DOMAIN" || true)
        if [[ -n "$wc_match" ]]; then
            IFS='|' read -r SSL_WILDCARD_CERT SSL_WILDCARD_KEY matched_san <<<"$wc_match"
            SSL_WILDCARD_SOURCE=$(dirname "$SSL_WILDCARD_CERT")
            SSL_USE_WILDCARD="true"
            sre_success "Found wildcard certificate covering $SSL_DOMAIN"
            sre_info "  Matched SAN:  $matched_san"
            sre_info "  Cert path:    $SSL_WILDCARD_CERT"
            sre_info "  Key path:     $SSL_WILDCARD_KEY"

            if ! prompt_yesno "Use this wildcard cert (skip Let's Encrypt)?" "yes"; then
                SSL_USE_WILDCARD="false"
                sre_info "User declined wildcard — will request Let's Encrypt cert"
            fi
        else
            sre_info "No wildcard cert found — will use Let's Encrypt"
        fi
    fi
fi

if [[ "$SSL_USE_WILDCARD" != "true" ]] && [[ -d "$cert_dir" ]]; then
    sre_warning "Certificate already exists for $SSL_DOMAIN"
    if ! prompt_yesno "Renew/replace the certificate?" "no"; then
        sre_skipped "SSL setup skipped (certificate already exists)"
        recommend_next_step "$CURRENT_STEP"
        exit 0
    fi
fi

# Acme webroot used both by Let's Encrypt issuance and by the HTTP→HTTPS
# redirect server block (so future LE renewals on top of a wildcard still work).
acme_webroot="/var/www/letsencrypt"

if [[ "$SSL_USE_WILDCARD" == "true" ]]; then
    sre_header "Using Existing Wildcard Certificate"
    sre_info "  Source:  $SSL_WILDCARD_SOURCE"
    sre_info "  Cert:    $SSL_WILDCARD_CERT"
    sre_info "  Key:     $SSL_WILDCARD_KEY"
    sre_info "Skipping Certbot — wildcard is renewed by whoever issued it."

    # Ensure ACME webroot still exists (vhost will reference it)
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        mkdir -p "${acme_webroot}/.well-known/acme-challenge"
    fi
else
    # --- Email prompt (only needed when we're actually calling Certbot) ---
    if [[ -z "$SSL_EMAIL" ]]; then
        SSL_EMAIL=$(prompt_input "Email for Let's Encrypt registration" "me@abdullah.link")
        [[ -z "$SSL_EMAIL" ]] && { sre_error "Email is required."; exit 1; }
    fi
    sre_info "Email:      $SSL_EMAIL"

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

    ############################################################################
    # Obtain Certificate (webroot method — does not touch vhost config)
    ############################################################################

    sre_header "Obtaining SSL Certificate"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then

        # Ensure the dedicated webroot exists and is served
        mkdir -p "${acme_webroot}/.well-known/acme-challenge"

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
fi

################################################################################
# Write full HTTPS vhost config (HTTP redirect + HTTPS server block)
################################################################################

sre_header "Writing HTTPS Vhost Config"

if [[ "$SSL_USE_WILDCARD" == "true" ]]; then
    cert_pem="$SSL_WILDCARD_CERT"
    cert_key="$SSL_WILDCARD_KEY"
else
    cert_pem="${cert_dir}/fullchain.pem"
    cert_key="${cert_dir}/privkey.pem"
fi

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
            elif grep -q 'wp-config\.php\|wp-content' "$vhost_conf" 2>/dev/null \
                 || [[ -f "${doc_root}/wp-config.php" ]]; then
                vhost_type="wordpress"
            else
                vhost_type="laravel"
            fi
        elif grep -q 'proxy_pass' "$vhost_conf" 2>/dev/null; then
            vhost_type="nuxt"
        elif grep -q 'try_files.*index.html' "$vhost_conf" 2>/dev/null; then
            vhost_type="vue"
        elif grep -q 'try_files.*=404' "$vhost_conf" 2>/dev/null; then
            vhost_type="static"
        fi

        sre_info "Detected vhost type: $vhost_type"

        # Re-read inner content from the original template (clean, no injected bits)
        # so we avoid re-parsing a potentially modified vhost file.
        template_file="${SCRIPT_DIR}/vhost/templates/nginx-${vhost_type}.conf"
        if [[ ! -f "$template_file" ]]; then
            template_file="${SCRIPT_DIR}/vhost/templates/nginx-laravel.conf"
            sre_warning "Template for $vhost_type not found, falling back to laravel template"
        fi

        # Extract inner lines: strip outer server{} wrapper, listen 80,
        # and the acme-challenge block (HTTPS block doesn't need it)
        existing_inner=$(sed -n '/^server {/,/^}$/p' "$template_file" \
            | sed '1d;$d' \
            | grep -v 'listen 80\|listen \[::\]:80' \
            | sed '/well-known/,/}/d' \
            | sed "s|{DOMAIN}|${SSL_DOMAIN}|g" \
            | sed "s|{DOCUMENT_ROOT}|${doc_root}|g" \
            | sed "s|{PHP_VERSION}|${php_version}|g" \
            | sed "s|{PORT}|${nuxt_port:-3000}|g")

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
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name ${SSL_DOMAIN};

    ssl_certificate     ${cert_pem};
    ssl_certificate_key ${cert_key};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

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

            # Read inner content from original template (clean, no injected bits)
            apache_type="laravel"
            if grep -qi 'moodle\|pluginfile' "$vhost_conf" 2>/dev/null; then
                apache_type="moodle"
            elif grep -qi 'wp-config\|wp-content' "$vhost_conf" 2>/dev/null \
                 || [[ -f "${doc_root}/wp-config.php" ]]; then
                apache_type="wordpress"
            fi
            apache_template="${SCRIPT_DIR}/vhost/templates/apache-${apache_type}.conf"
            [[ ! -f "$apache_template" ]] && apache_template="${SCRIPT_DIR}/vhost/templates/apache-laravel.conf"

            existing_inner=$(sed -n '/<VirtualHost/,/<\/VirtualHost>/p' "$apache_template" \
                | sed '1d;$d' \
                | sed "s|{DOMAIN}|${SSL_DOMAIN}|g" \
                | sed "s|{DOCUMENT_ROOT}|${doc_root}|g" \
                | sed "s|{PHP_VERSION}|${php_version}|g")

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
# Auto-renewal (only when we issued a per-domain LE cert; wildcards are
# renewed by whoever issued them, not by us)
################################################################################

if [[ "$SSL_USE_WILDCARD" != "true" ]] && [[ "$SRE_DRY_RUN" != "true" ]]; then
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
elif [[ "$SSL_USE_WILDCARD" == "true" ]]; then
    sre_info "Skipping auto-renewal setup — wildcard cert is renewed by its issuer."
    sre_info "When the wildcard renews, reload the web server to pick up the new file:"
    case "$web_server" in
        nginx)  sre_info "  systemctl reload nginx" ;;
        apache)
            case "$os_family" in
                debian) sre_info "  systemctl reload apache2" ;;
                rhel)   sre_info "  systemctl reload httpd" ;;
            esac
            ;;
    esac
fi

sre_success "SSL setup complete for ${SSL_DOMAIN}!"
sre_info "  HTTP  → redirects to HTTPS"
sre_info "  HTTPS → https://${SSL_DOMAIN}"
sre_info "  Cert  → ${cert_pem}"
if [[ "$SSL_USE_WILDCARD" == "true" ]]; then
    sre_info "  Source: wildcard ($SSL_WILDCARD_SOURCE)"
fi
echo ""
sre_warning "If HTTPS is still unreachable, check your firewall/security group:"
sre_warning "  Port 443 must be open (Oracle Cloud: Security Lists → Ingress Rules)"

recommend_next_step "$CURRENT_STEP"
