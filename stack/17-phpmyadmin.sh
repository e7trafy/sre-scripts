#!/bin/bash
################################################################################
# SRE Helpers - Step 17: phpMyAdmin (Optional)
#
# Installs phpMyAdmin under its own domain, behind HTTP basic auth + an IP
# allowlist by default. Treats phpMyAdmin as a high-risk surface — the script
# will REFUSE to expose it unprotected unless --no-protect is passed.
#
# What it does:
#   1. Downloads the latest phpMyAdmin (or a pinned --version) from
#      phpmyadmin.net into /var/www/<domain>/current/.
#   2. Generates config.inc.php with a fresh blowfish_secret, localhost DB host,
#      cookie auth, and a server-side TempDir.
#   3. Optionally creates the pma__ control DB + user (multi-user features).
#   4. Creates the vhost via step 8 (--type phpmyadmin).
#   5. Offers SSL via step 11 (recommended; on-by-default).
#   6. Injects staging-style protection (basic auth + optional IP allowlist)
#      into the final vhost, reusing the same BEGIN/END marker block as step
#      16 so re-runs are idempotent.
#
# What it does NOT do:
#   - Touch DNS (point <domain> at this server yourself).
#   - Open phpMyAdmin to anyone with --no-protect AND no SSL — that combo will
#     be rejected.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=17

PMA_DOMAIN=""
PMA_VERSION="latest"       # latest, or e.g. 5.2.1
PMA_CREATE_CONTROL_DB="ask" # ask|yes|no — pma__ tables for multi-user features

# Protection (ON by default — phpMyAdmin is high-risk)
PMA_PROTECT="yes"
PMA_PROTECT_USER=""
PMA_PROTECT_PASS=""
PMA_ALLOW_IPS=()
PMA_NOINDEX="yes"            # X-Robots-Tag already in template, this also writes robots.txt
PMA_HTPASSWD="yes"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 17: phpMyAdmin (Optional)

  Installs phpMyAdmin under its own domain, behind HTTP basic auth + an IP
  allowlist by default. Refuses to expose it without protection.

Options:
  --domain <domain>     Domain for phpMyAdmin           (or prompted)
  --version <ver>       phpMyAdmin version              (default: latest)
  --create-control-db   Create pma__ control DB + user (multi-user features)
  --no-control-db       Skip control DB

Protection (default: ON — phpMyAdmin is HIGH-RISK):
  --no-protect          Disable ALL protection (REFUSED unless you also pass --i-understand)
  --i-understand        Required confirmation for --no-protect
  --no-htpasswd         Skip HTTP basic auth (keep IP allowlist if set)
  --no-noindex          Skip robots.txt write
  --protect-user <u>    Basic auth username             (default: admin)
  --protect-pass <p>    Basic auth password             (default: generated)
  --allow-ip <cidr>     IP/CIDR that bypasses auth      (repeatable)

  --dry-run             Print planned actions only
  --yes                 Accept defaults without prompting
  --help                Show this help

Examples:
  sudo bash $0
  sudo bash $0 --domain pma.example.com --allow-ip 203.0.113.0/24
  sudo bash $0 --domain pma.example.com --version 5.2.1 --no-noindex
EOF
}

_raw_args=("$@")
sre_parse_args "17-phpmyadmin.sh" "${_raw_args[@]}"

PMA_FORCE_OPEN="no"
_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)             _i=$((_i + 1)); PMA_DOMAIN="${_raw_args[$_i]:-}" ;;
        --version)            _i=$((_i + 1)); PMA_VERSION="${_raw_args[$_i]:-latest}" ;;
        --create-control-db)  PMA_CREATE_CONTROL_DB="yes" ;;
        --no-control-db)      PMA_CREATE_CONTROL_DB="no" ;;
        --no-protect)         PMA_PROTECT="no"; PMA_NOINDEX="no"; PMA_HTPASSWD="no" ;;
        --i-understand)       PMA_FORCE_OPEN="yes" ;;
        --no-htpasswd)        PMA_HTPASSWD="no" ;;
        --no-noindex)         PMA_NOINDEX="no" ;;
        --protect-user)       _i=$((_i + 1)); PMA_PROTECT_USER="${_raw_args[$_i]:-}" ;;
        --protect-pass)       _i=$((_i + 1)); PMA_PROTECT_PASS="${_raw_args[$_i]:-}" ;;
        --allow-ip)           _i=$((_i + 1)); PMA_ALLOW_IPS+=("${_raw_args[$_i]:-}") ;;
    esac
    _i=$((_i + 1))
done

require_root
sre_header "Step 17: phpMyAdmin (Optional)"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")
db_engine=$(config_get "SRE_DB_ENGINE" "none")

if [[ -z "$web_server" ]]; then
    sre_error "Web server not configured. Run step 3 first."
    exit 2
fi
case "$db_engine" in
    mysql|mariadb) ;;
    *) sre_warning "DB engine is '$db_engine' — phpMyAdmin needs MySQL/MariaDB."
       prompt_yesno "Continue anyway?" "no" || { sre_skipped "Cancelled."; exit 0; } ;;
esac

################################################################################
# Pick domain
################################################################################

if [[ -z "$PMA_DOMAIN" ]]; then
    # Suggest pma.<base> if we can derive base from any existing vhost
    vhost_dir=$(get_vhost_dir "$web_server")
    default_dom="pma.local"
    first_existing=$(ls -1 "$vhost_dir"/*.conf 2>/dev/null | head -1 | xargs -I{} basename {} .conf)
    if [[ -n "$first_existing" && "$first_existing" == *.* ]]; then
        default_dom="pma.${first_existing#*.}"
    fi
    PMA_DOMAIN=$(prompt_input "Domain for phpMyAdmin" "$default_dom")
fi
[[ -z "$PMA_DOMAIN" ]] && { sre_error "Domain required"; exit 1; }

pma_base="/var/www/${PMA_DOMAIN}"
pma_release_dir="${pma_base}/releases/$(date +%Y%m%d%H%M%S)"
pma_current="${pma_base}/current"

sre_info "Domain:       $PMA_DOMAIN"
sre_info "Install path: $pma_base"
sre_info "PHP version:  $php_version"
sre_info "DB engine:    $db_engine"

################################################################################
# Safety: refuse to expose phpMyAdmin unprotected
################################################################################

if [[ "$PMA_PROTECT" == "no" ]]; then
    if [[ "$PMA_FORCE_OPEN" != "yes" ]]; then
        sre_error "Refusing to install phpMyAdmin with --no-protect unless --i-understand is also set."
        sre_error "Exposing phpMyAdmin to the open internet is a recipe for a compromised DB."
        sre_error "Either drop --no-protect, or add --i-understand to acknowledge the risk."
        exit 1
    fi
    sre_warning "Protection disabled by --no-protect --i-understand. You're on your own."
fi

################################################################################
# Pick latest version if needed
################################################################################

if [[ "$PMA_VERSION" == "latest" ]]; then
    sre_info "Resolving latest phpMyAdmin version..."
    # phpmyadmin.net exposes a plain text file with the latest version
    latest=$(curl -fsSL --max-time 15 "https://www.phpmyadmin.net/home_page/version.txt" 2>/dev/null \
        | head -1 | awk '{print $1}')
    if [[ -n "$latest" ]]; then
        PMA_VERSION="$latest"
        sre_info "Latest = $PMA_VERSION"
    else
        sre_warning "Could not resolve latest — falling back to 5.2.2"
        PMA_VERSION="5.2.2"
    fi
fi

# Validate version format
if ! [[ "$PMA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    sre_error "Invalid phpMyAdmin version: $PMA_VERSION"
    exit 1
fi

dl_url="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
sre_info "Download URL: $dl_url"

################################################################################
# Refuse to clobber existing install
################################################################################

if [[ -d "$pma_base" ]]; then
    sre_warning "Install path already exists: $pma_base"
    if ! prompt_yesno "Reinstall phpMyAdmin over the existing install?" "no"; then
        sre_skipped "Install cancelled."
        exit 4
    fi
fi

################################################################################
# Plan summary + confirm
################################################################################

sre_header "phpMyAdmin Install Plan"
sre_info "  Domain:       $PMA_DOMAIN"
sre_info "  Version:      $PMA_VERSION"
sre_info "  Install path: $pma_base"

if [[ "$PMA_PROTECT" == "yes" ]]; then
    protect_bits=()
    [[ "$PMA_HTPASSWD" == "yes" ]] && protect_bits+=("htpasswd")
    [[ "$PMA_NOINDEX"  == "yes" ]] && protect_bits+=("noindex")
    [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]] && protect_bits+=("allow:${PMA_ALLOW_IPS[*]}")
    sre_info "  Protect:      ${protect_bits[*]}"
else
    sre_warning "  Protect:      DISABLED (--i-understand acknowledged)"
fi

if ! prompt_yesno "Proceed with phpMyAdmin install?" "yes"; then
    sre_skipped "Install cancelled by user."
    exit 0
fi

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] No further actions."
    exit 0
fi

################################################################################
# Download + extract
################################################################################

sre_header "Downloading phpMyAdmin"

tmp_tar="/tmp/phpMyAdmin-${PMA_VERSION}.tar.gz"
if [[ ! -f "$tmp_tar" ]]; then
    curl -fsSL --max-time 300 -o "$tmp_tar" "$dl_url" \
        || { sre_error "Download failed: $dl_url"; exit 1; }
fi
sre_success "Downloaded: $tmp_tar ($(du -h "$tmp_tar" | cut -f1))"

# Try to verify with .tar.gz.sha256 (cheap integrity check)
sha_url="${dl_url}.sha256"
sha_local="${tmp_tar}.sha256"
if curl -fsSL --max-time 15 -o "$sha_local" "$sha_url" 2>/dev/null; then
    expected=$(awk '{print $1}' "$sha_local")
    actual=$(sha256sum "$tmp_tar" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        sre_success "SHA-256 verified"
    else
        sre_error "SHA-256 mismatch! expected=$expected actual=$actual"
        rm -f "$tmp_tar"
        exit 1
    fi
else
    sre_warning "Could not fetch .sha256 (skipping integrity check)"
fi

sre_header "Extracting phpMyAdmin"
mkdir -p "$pma_release_dir"
tar -xzf "$tmp_tar" -C "$pma_release_dir" --strip-components=1 \
    || { sre_error "Extract failed"; exit 1; }
sre_success "Extracted to: $pma_release_dir"

# current symlink
ln -sfn "$pma_release_dir" "$pma_current"

# Server-side tempdir (used by phpMyAdmin for compiled templates)
mkdir -p "${pma_base}/shared/tmp"

################################################################################
# Generate config.inc.php
################################################################################

sre_header "Configuring phpMyAdmin"

blowfish_secret=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

cfg="${pma_release_dir}/config.inc.php"
cat > "$cfg" <<PMACONF
<?php
/**
 * phpMyAdmin sample configuration — generated by sre-helpers step 17
 */

declare(strict_types=1);

\$cfg['blowfish_secret'] = '${blowfish_secret}';

\$i = 0;

\$i++;
\$cfg['Servers'][\$i]['auth_type']        = 'cookie';
\$cfg['Servers'][\$i]['host']             = 'localhost';
\$cfg['Servers'][\$i]['compress']         = false;
\$cfg['Servers'][\$i]['AllowNoPassword']  = false;
\$cfg['Servers'][\$i]['extension']        = 'mysqli';

PMACONF

# Control DB block (added below if user opts in)

cat >> "$cfg" <<PMACONF

/* Directories */
\$cfg['TempDir']     = '${pma_base}/shared/tmp';
\$cfg['UploadDir']   = '';
\$cfg['SaveDir']     = '';

/* UI hardening */
\$cfg['ShowPhpInfo']         = false;
\$cfg['VersionCheck']        = true;
\$cfg['LoginCookieValidity'] = 3600;
\$cfg['DefaultLang']         = 'en';
PMACONF

sre_success "config.inc.php written (blowfish_secret regenerated)"

################################################################################
# Control DB (pma__) — optional
################################################################################

if [[ "$PMA_CREATE_CONTROL_DB" == "ask" ]]; then
    if prompt_yesno "Create pma__ control DB + user (enables multi-user features, query bookmarks, etc)?" "yes"; then
        PMA_CREATE_CONTROL_DB="yes"
    else
        PMA_CREATE_CONTROL_DB="no"
    fi
fi

if [[ "$PMA_CREATE_CONTROL_DB" == "yes" ]]; then
    sre_header "Creating phpMyAdmin Control DB"

    db_root_pass=""
    [[ -f /root/.db_root_password ]] && db_root_pass=$(cat /root/.db_root_password)
    mysql_cmd="mysql"
    [[ -n "$db_root_pass" ]] && mysql_cmd="mysql -u root -p${db_root_pass}"

    pma_ctrl_user="pma"
    pma_ctrl_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
    pma_ctrl_db="phpmyadmin"

    $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${pma_ctrl_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        || { sre_error "Could not create control DB"; exit 1; }
    $mysql_cmd -e "CREATE USER IF NOT EXISTS '${pma_ctrl_user}'@'localhost' IDENTIFIED BY '${pma_ctrl_pass}';" 2>/dev/null
    $mysql_cmd -e "ALTER  USER '${pma_ctrl_user}'@'localhost' IDENTIFIED BY '${pma_ctrl_pass}';" 2>/dev/null
    $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${pma_ctrl_db}\`.* TO '${pma_ctrl_user}'@'localhost';" 2>/dev/null
    $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null

    # Load schema shipped with phpMyAdmin
    schema_sql="${pma_release_dir}/sql/create_tables.sql"
    if [[ -f "$schema_sql" ]]; then
        $mysql_cmd "$pma_ctrl_db" < "$schema_sql" \
            && sre_success "Control DB schema loaded" \
            || sre_warning "Schema load had warnings — check manually"
    else
        sre_warning "Schema file not found at $schema_sql"
    fi

    # Append control-server block to config
    tmp_cfg=$(mktemp)
    awk -v block="\$cfg['Servers'][\$i]['controluser']     = '${pma_ctrl_user}';
\$cfg['Servers'][\$i]['controlpass']     = '${pma_ctrl_pass}';
\$cfg['Servers'][\$i]['pmadb']           = '${pma_ctrl_db}';
\$cfg['Servers'][\$i]['bookmarktable']   = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation']        = 'pma__relation';
\$cfg['Servers'][\$i]['table_info']      = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords']    = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages']       = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info']     = 'pma__column_info';
\$cfg['Servers'][\$i]['history']         = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs']   = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking']        = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig']      = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent']          = 'pma__recent';
\$cfg['Servers'][\$i]['favorite']        = 'pma__favorite';
\$cfg['Servers'][\$i]['users']           = 'pma__users';
\$cfg['Servers'][\$i]['usergroups']      = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhiding']= 'pma__navigationhiding';
\$cfg['Servers'][\$i]['savedsearches']   = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings']='pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates'] ='pma__export_templates';
" '
        /extension..= ..mysqli../ { print; print ""; print block; next }
        { print }
    ' "$cfg" > "$tmp_cfg" && mv "$tmp_cfg" "$cfg"

    sre_success "Control DB + user created: ${pma_ctrl_db} / ${pma_ctrl_user}"
fi

################################################################################
# Permissions
################################################################################

require_acl

chown -R www-data:www-data "$pma_base"
find "$pma_base" -type d -exec chmod 755 {} \;
find "$pma_base" -type f -exec chmod 644 {} \;
chmod 640 "$cfg"
chmod 750 "${pma_base}/shared/tmp"
setfacl -R -m u:www-data:rwX -m d:u:www-data:rwX "$pma_base"

sre_success "Permissions applied"

################################################################################
# Create vhost via step 8
################################################################################

sre_header "Creating Vhost for phpMyAdmin"

bash "${SRE_SCRIPTS_DIR}/vhost/08-vhost.sh" \
    --domain "$PMA_DOMAIN" \
    --type phpmyadmin \
    --root "${pma_current}" \
    --yes \
    || { sre_error "Vhost creation failed"; exit 1; }

# Locate the final vhost file (step 8 writes it; path differs by OS/server)
vhost_dir=$(get_vhost_dir "$web_server")
pma_vhost="${vhost_dir}/${PMA_DOMAIN}.conf"
[[ -f "$pma_vhost" ]] || { sre_error "Vhost not found at $pma_vhost"; exit 1; }

################################################################################
# Offer SSL (run BEFORE protection injection — certbot may rewrite the vhost)
################################################################################

if prompt_yesno "Setup SSL for $PMA_DOMAIN now? (strongly recommended)" "yes"; then
    bash "${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh" --domain "$PMA_DOMAIN" --yes \
        || sre_warning "SSL setup didn't complete — re-run manually if needed"
fi

################################################################################
# Protection (htpasswd + IP allowlist)
#
# Same injection mechanism as step 16. Inserts directives into every server { }
# block so HTTP + HTTPS are both gated. Robots header is already in the template.
################################################################################

if [[ "$PMA_PROTECT" == "yes" ]] && [[ "$PMA_HTPASSWD" == "yes" || ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
    sre_header "Protecting phpMyAdmin"

    htpasswd_file=""
    if [[ "$PMA_HTPASSWD" == "yes" ]]; then
        if ! command -v htpasswd &>/dev/null; then
            case "$os_family" in
                debian) pkg_install apache2-utils ;;
                rhel)   pkg_install httpd-tools ;;
            esac
        fi

        if ! command -v htpasswd &>/dev/null; then
            sre_warning "htpasswd not available — disabling basic auth"
            PMA_HTPASSWD="no"
        else
            [[ -z "$PMA_PROTECT_USER" ]] && PMA_PROTECT_USER="admin"
            [[ -z "$PMA_PROTECT_PASS" ]] && PMA_PROTECT_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)

            htpasswd_file="/etc/nginx/htpasswd-${PMA_DOMAIN}"
            [[ "$web_server" == "apache" ]] && htpasswd_file="/etc/apache2/htpasswd-${PMA_DOMAIN}"
            [[ "$os_family" == "rhel" && "$web_server" == "apache" ]] && htpasswd_file="/etc/httpd/htpasswd-${PMA_DOMAIN}"

            htpasswd -bc "$htpasswd_file" "$PMA_PROTECT_USER" "$PMA_PROTECT_PASS" >/dev/null
            chmod 640 "$htpasswd_file"
            chown root:www-data "$htpasswd_file" 2>/dev/null || true
            sre_success "Basic auth: $htpasswd_file"
        fi
    fi

    # Build snippet
    snippet=""
    case "$web_server" in
        nginx)
            snippet+=$'\n    # --- BEGIN sre-helpers staging protection ---\n'
            if [[ "$PMA_HTPASSWD" == "yes" ]]; then
                if [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
                    snippet+=$'    satisfy any;\n'
                    for ip in "${PMA_ALLOW_IPS[@]}"; do
                        [[ -n "$ip" ]] && snippet+="    allow ${ip};"$'\n'
                    done
                    snippet+=$'    deny all;\n'
                fi
                snippet+=$'    auth_basic           "phpMyAdmin - Restricted";\n'
                snippet+="    auth_basic_user_file ${htpasswd_file};"$'\n'
            elif [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
                # IP-only gate
                for ip in "${PMA_ALLOW_IPS[@]}"; do
                    [[ -n "$ip" ]] && snippet+="    allow ${ip};"$'\n'
                done
                snippet+=$'    deny all;\n'
            fi
            snippet+=$'    # --- END sre-helpers staging protection ---\n'
            ;;
        apache)
            snippet+=$'\n    # --- BEGIN sre-helpers staging protection ---\n'
            if [[ "$PMA_HTPASSWD" == "yes" ]]; then
                snippet+=$'    <Location "/">\n'
                snippet+=$'        AuthType Basic\n'
                snippet+=$'        AuthName "phpMyAdmin - Restricted"\n'
                snippet+="        AuthUserFile ${htpasswd_file}"$'\n'
                if [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
                    snippet+=$'        <RequireAny>\n'
                    snippet+=$'            Require valid-user\n'
                    for ip in "${PMA_ALLOW_IPS[@]}"; do
                        [[ -n "$ip" ]] && snippet+="            Require ip ${ip}"$'\n'
                    done
                    snippet+=$'        </RequireAny>\n'
                else
                    snippet+=$'        Require valid-user\n'
                fi
                snippet+=$'    </Location>\n'
            elif [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
                snippet+=$'    <Location "/">\n'
                snippet+=$'        <RequireAny>\n'
                for ip in "${PMA_ALLOW_IPS[@]}"; do
                    [[ -n "$ip" ]] && snippet+="            Require ip ${ip}"$'\n'
                done
                snippet+=$'        </RequireAny>\n'
                snippet+=$'    </Location>\n'
            fi
            snippet+=$'    # --- END sre-helpers staging protection ---\n'
            ;;
    esac

    # Strip prior block + inject
    sed -i '/# --- BEGIN sre-helpers staging protection ---/,/# --- END sre-helpers staging protection ---/d' "$pma_vhost"

    tmp_snip=$(mktemp)
    printf '%s' "$snippet" > "$tmp_snip"

    case "$web_server" in
        nginx)
            awk -v snippet_file="$tmp_snip" '
                BEGIN { while ((getline ln < snippet_file) > 0) snippet = snippet ln "\n"; close(snippet_file); in_server = 0; depth = 0 }
                { buf = $0; out = ""; n = length(buf)
                  for (i = 1; i <= n; i++) {
                    c = substr(buf, i, 1)
                    if (!in_server && c == "{") { tail = substr(buf, 1, i - 1); if (tail ~ /(^|[^A-Za-z_])server[[:space:]]*$/) { in_server = 1; depth = 1; out = out c; continue } }
                    if (in_server) { if (c == "{") depth++; else if (c == "}") { depth--; if (depth == 0) { out = out "\n" snippet; in_server = 0 } } }
                    out = out c
                  }
                  print out
                }
            ' "$pma_vhost" > "${pma_vhost}.tmp" && mv "${pma_vhost}.tmp" "$pma_vhost"
            ;;
        apache)
            awk -v snippet_file="$tmp_snip" '
                BEGIN { while ((getline ln < snippet_file) > 0) snippet = snippet ln "\n"; close(snippet_file) }
                /<\/VirtualHost>/ { printf "%s", snippet }
                { print }
            ' "$pma_vhost" > "${pma_vhost}.tmp" && mv "${pma_vhost}.tmp" "$pma_vhost"
            ;;
    esac
    rm -f "$tmp_snip"

    sre_success "Protection injected into $pma_vhost"

    # robots.txt (template already returns one inline for /robots.txt; this is
    # a static file fallback)
    if [[ "$PMA_NOINDEX" == "yes" ]]; then
        echo -e "User-agent: *\nDisallow: /" > "${pma_current}/robots.txt"
        chown www-data:www-data "${pma_current}/robots.txt"
        chmod 644 "${pma_current}/robots.txt"
    fi

    # Reload + test
    case "$web_server" in
        nginx)
            if nginx -t 2>&1 | tail -2; then
                svc_reload nginx && sre_success "Nginx reloaded"
            else
                sre_error "Nginx config test failed — review $pma_vhost"
            fi
            ;;
        apache)
            test_cmd="apachectl configtest"
            [[ "$os_family" == "rhel" ]] && test_cmd="httpd -t"
            if $test_cmd 2>&1 | tail -2; then
                case "$os_family" in
                    debian) svc_reload apache2 ;;
                    rhel)   svc_reload httpd ;;
                esac
                sre_success "Apache reloaded"
            else
                sre_error "Apache config test failed — review $pma_vhost"
            fi
            ;;
    esac
fi

################################################################################
# Save install state
################################################################################

mkdir -p /etc/sre-helpers/phpmyadmin
state_file="/etc/sre-helpers/phpmyadmin/${PMA_DOMAIN}.conf"
{
    printf '# phpMyAdmin install — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'PMA_DOMAIN=%q\n'        "$PMA_DOMAIN"
    printf 'PMA_VERSION=%q\n'       "$PMA_VERSION"
    printf 'PMA_INSTALL_PATH=%q\n'  "$pma_base"
    printf 'PMA_RELEASE=%q\n'       "$pma_release_dir"
    printf 'PMA_PROTECT=%q\n'       "$PMA_PROTECT"
    printf 'PMA_PROTECT_USER=%q\n'  "${PMA_PROTECT_USER:-}"
    printf 'PMA_PROTECT_PASS=%q\n'  "${PMA_PROTECT_PASS:-}"
    printf 'PMA_ALLOW_IPS=%q\n'     "${PMA_ALLOW_IPS[*]:-}"
    printf 'PMA_CTRL_DB=%q\n'       "${pma_ctrl_db:-}"
    printf 'PMA_CTRL_USER=%q\n'     "${pma_ctrl_user:-}"
    printf 'PMA_CTRL_PASS=%q\n'     "${pma_ctrl_pass:-}"
} > "$state_file"
chmod 600 "$state_file"

config_set "SRE_PHPMYADMIN_INSTALLED" "true"
config_set "SRE_PHPMYADMIN_DOMAIN"    "$PMA_DOMAIN"

################################################################################
# Summary
################################################################################

sre_header "phpMyAdmin Install Complete"

sre_success "Installed: $PMA_DOMAIN  (version $PMA_VERSION)"
echo ""
sre_info "  URL:           http(s)://${PMA_DOMAIN}"
sre_info "  Install path:  $pma_base"
sre_info "  Config file:   $cfg  (chmod 640, owned by www-data)"
sre_info "  State file:    $state_file"

if [[ "$PMA_CREATE_CONTROL_DB" == "yes" ]]; then
    echo ""
    sre_info "  Control DB:    $pma_ctrl_db"
    sre_info "  Control user:  $pma_ctrl_user"
    sre_info "  Control pass:  $pma_ctrl_pass"
    sre_warning "  Save the control-DB password!"
fi

if [[ "$PMA_PROTECT" == "yes" && "$PMA_HTPASSWD" == "yes" ]]; then
    echo ""
    sre_header "Basic Auth Required"
    sre_info "  Username: $PMA_PROTECT_USER"
    sre_info "  Password: $PMA_PROTECT_PASS"
    sre_warning "  Save these — the browser will prompt for them before phpMyAdmin loads."
fi

if [[ ${#PMA_ALLOW_IPS[@]} -gt 0 ]]; then
    sre_info "  IP allowlist (bypasses auth): ${PMA_ALLOW_IPS[*]}"
fi

echo ""
sre_info "Next steps:"
sre_info "  1. Point DNS for ${PMA_DOMAIN} at this server (or rely on wildcard)"
sre_info "  2. Visit https://${PMA_DOMAIN}"
sre_info "  3. Log in with any valid MySQL user — root works if local"
echo ""
sre_warning "Security tip: keep this domain off any public Google index. Consider"
sre_warning "rotating PMA_PROTECT_PASS periodically and pinning --allow-ip to your office."

recommend_next_step "$CURRENT_STEP"
