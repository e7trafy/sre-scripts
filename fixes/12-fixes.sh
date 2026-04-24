#!/bin/bash
################################################################################
# SRE Helpers - Step 12: Quick Fixes & Common Problems
# Interactive menu of small fixes for issues encountered after provisioning.
# Each fix has its own Q&A prompts to ensure correct execution.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=12

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 12: Quick Fixes & Common Problems
  Interactive menu of post-provisioning fixes including:
    - File permissions & ownership
    - Filesystem ACLs
    - Log file issues
    - ImageMagick / Arabic rendering
    - PHP limits & extensions
    - Nginx / web server issues
    - Database charset
    - Locale & encoding

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

sre_parse_args "12-fixes.sh" "$@"
require_root

sre_header "Step 12: Quick Fixes & Common Problems"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

SRE_OS_FAMILY=$(config_get "SRE_OS_FAMILY" "debian")

################################################################################
# Fix: Permissions & Ownership
################################################################################

fix_permissions() {
    sre_header "Fix: Permissions & Ownership"

    local target_path
    target_path=$(prompt_input "Project path to fix" "/var/www")

    if [[ ! -d "$target_path" ]]; then
        sre_error "Path does not exist: $target_path"
        return 1
    fi

    local project_type
    project_type=$(prompt_choice "Project type:" "laravel" "moodle" "nuxt" "vue" "static")

    local web_user
    web_user=$(prompt_input "Web server user" "www-data")

    local web_group
    web_group=$(prompt_input "Web server group" "$web_user")

    sre_info "Target: $target_path"
    sre_info "Type: $project_type"
    sre_info "Owner: $web_user:$web_group"

    if ! prompt_yesno "Proceed with fixing permissions?" "yes"; then
        sre_skipped "Permissions fix cancelled"
        return 0
    fi

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        sre_info "Setting ownership..."
        chown -R "${web_user}:${web_group}" "$target_path"

        sre_info "Setting base permissions (dirs=755, files=644)..."
        find "$target_path" -type d -exec chmod 755 {} \;
        find "$target_path" -type f -exec chmod 644 {} \;

        case "$project_type" in
            laravel)
                for wd in storage bootstrap/cache; do
                    if [[ -d "${target_path}/${wd}" ]]; then
                        chmod -R 775 "${target_path}/${wd}"
                        sre_info "  775 on ${wd}/"
                    fi
                done
                [[ -f "${target_path}/artisan" ]] && chmod 755 "${target_path}/artisan"
                [[ -f "${target_path}/.env" ]] && chmod 640 "${target_path}/.env"
                # vendor/bin executables
                if [[ -d "${target_path}/vendor/bin" ]]; then
                    find "${target_path}/vendor/bin" -type f -exec chmod 755 {} \;
                fi
                if [[ -d "${target_path}/node_modules/.bin" ]]; then
                    find "${target_path}/node_modules/.bin" -type f -exec chmod 755 {} \;
                fi
                sre_success "Laravel permissions applied"
                ;;
            moodle)
                [[ -f "${target_path}/config.php" ]] && chmod 640 "${target_path}/config.php"
                for wd in localcache cache temp; do
                    if [[ -d "${target_path}/${wd}" ]]; then
                        chmod -R 775 "${target_path}/${wd}"
                        chown -R "${web_user}:${web_group}" "${target_path}/${wd}"
                    fi
                done
                # Ask about moodledata
                if prompt_yesno "Fix moodledata permissions too?" "yes"; then
                    local mdata_path
                    mdata_path=$(prompt_input "Moodledata path" "/var/www/moodledata")
                    if [[ -d "$mdata_path" ]]; then
                        chown -R "${web_user}:${web_group}" "$mdata_path"
                        chmod -R 775 "$mdata_path"
                        # Fix requestdir inside moodledata and /tmp
                        for tmpdir in "${mdata_path}/requestdir" "${mdata_path}/temp" "${mdata_path}/localcache" "/tmp"; do
                            mkdir -p "$tmpdir" 2>/dev/null || true
                            chown "${web_user}:${web_group}" "$tmpdir"
                            chmod 1775 "$tmpdir"
                        done
                        sre_success "Moodledata permissions fixed: $mdata_path"
                    else
                        sre_error "Moodledata path not found: $mdata_path"
                    fi
                fi
                # Fix /tmp for Moodle requestdir (invaliddatarootpermissions)
                sre_info "Fixing /tmp permissions for Moodle request storage..."
                chmod 1777 /tmp
                chown root:root /tmp
                # Ensure www-data can create dirs in /tmp
                if [[ -d /tmp/requestdir ]]; then
                    chown -R "${web_user}:${web_group}" /tmp/requestdir
                    chmod -R 775 /tmp/requestdir
                fi
                sre_success "Moodle permissions applied (including /tmp requestdir)"
                ;;
            nuxt)
                for wd in .nuxt .output node_modules; do
                    if [[ -d "${target_path}/${wd}" ]]; then
                        chmod -R 775 "${target_path}/${wd}"
                    fi
                done
                sre_success "Nuxt permissions applied"
                ;;
            vue|static)
                sre_success "Static/Vue permissions applied (read-only is fine)"
                ;;
        esac

        # Restore execute bit on shell scripts
        find "$target_path" -name "*.sh" -type f -exec chmod 755 {} \; 2>/dev/null || true
    else
        sre_info "[DRY-RUN] Would fix permissions on $target_path ($project_type)"
    fi
}

################################################################################
# Fix: Filesystem ACLs
################################################################################

fix_acl() {
    sre_header "Fix: Filesystem ACLs"

    require_acl

    local target_path
    target_path=$(prompt_input "Path to apply ACLs on" "/var/www")

    if [[ ! -d "$target_path" ]]; then
        sre_error "Path does not exist: $target_path"
        return 1
    fi

    local acl_user
    acl_user=$(prompt_input "User to grant access" "www-data")

    local acl_perms
    acl_perms=$(prompt_choice "Permission level:" "rwX" "rX" "r")

    if prompt_yesno "Set default ACL too? (new files inherit permissions)" "yes"; then
        local set_default="yes"
    else
        local set_default="no"
    fi

    # Check if path is on block storage
    local mount_point
    mount_point=$(df "$target_path" --output=target 2>/dev/null | tail -1)
    if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
        if ! mount | grep "$mount_point" | grep -q "acl"; then
            sre_warning "Filesystem at $mount_point may not have ACL support enabled"
            if ! prompt_yesno "Continue anyway?" "yes"; then
                sre_skipped "ACL fix cancelled"
                return 0
            fi
        fi
    fi

    sre_info "Target: $target_path"
    sre_info "User: $acl_user"
    sre_info "Permissions: $acl_perms"
    sre_info "Default ACL: $set_default"

    if ! prompt_yesno "Apply ACLs now?" "yes"; then
        sre_skipped "ACL fix cancelled"
        return 0
    fi

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        setfacl -R -m "u:${acl_user}:${acl_perms}" "$target_path"
        sre_success "ACL applied: u:${acl_user}:${acl_perms} on $target_path"

        if [[ "$set_default" == "yes" ]]; then
            setfacl -R -d -m "u:${acl_user}:${acl_perms}" "$target_path"
            sre_success "Default ACL set: new files inherit u:${acl_user}:${acl_perms}"
        fi

        # Also grant root
        if prompt_yesno "Also grant root the same ACL?" "yes"; then
            setfacl -R -m "u:root:${acl_perms}" "$target_path"
            setfacl -R -d -m "u:root:${acl_perms}" "$target_path"
            sre_success "Root ACL applied"
        fi

        sre_info "Current ACL on $target_path:"
        getfacl "$target_path" 2>/dev/null | grep -E "^(user|group|default)" | head -10
    else
        sre_info "[DRY-RUN] Would apply ACL u:${acl_user}:${acl_perms} on $target_path"
    fi
}

################################################################################
# Fix: Log Files
################################################################################

fix_logs() {
    sre_header "Fix: Log File Issues"

    local issue
    issue=$(prompt_choice "What's the issue?" \
        "logs-not-writable" \
        "logs-too-large" \
        "create-missing-log-dirs" \
        "fix-logrotate")

    case "$issue" in
        logs-not-writable)
            local log_path
            log_path=$(prompt_input "Log file or directory path" "/var/www")

            if [[ ! -e "$log_path" ]]; then
                sre_error "Path does not exist: $log_path"
                return 1
            fi

            local log_user
            log_user=$(prompt_input "Owner user" "www-data")

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                if [[ -d "$log_path" ]]; then
                    chown -R "${log_user}:${log_user}" "$log_path"
                    chmod -R 775 "$log_path"
                    setfacl -R -m "u:${log_user}:rwX" "$log_path"
                    setfacl -R -d -m "u:${log_user}:rwX" "$log_path"
                else
                    chown "${log_user}:${log_user}" "$log_path"
                    chmod 664 "$log_path"
                fi
                sre_success "Log permissions fixed: $log_path"
            else
                sre_info "[DRY-RUN] Would fix log permissions on $log_path"
            fi
            ;;

        logs-too-large)
            local log_file
            log_file=$(prompt_input "Log file to truncate" "")

            if [[ -z "$log_file" || ! -f "$log_file" ]]; then
                sre_error "Invalid log file: $log_file"
                return 1
            fi

            local log_size
            log_size=$(du -h "$log_file" 2>/dev/null | awk '{print $1}')
            sre_warning "File size: $log_size"

            if prompt_yesno "Truncate this log file? (keeps file, empties content)" "no"; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    : > "$log_file"
                    sre_success "Log truncated: $log_file"
                else
                    sre_info "[DRY-RUN] Would truncate $log_file"
                fi
            fi

            if prompt_yesno "Set up logrotate for this file?" "yes"; then
                _setup_logrotate_for "$log_file"
            fi
            ;;

        create-missing-log-dirs)
            local project_path
            project_path=$(prompt_input "Project root path" "/var/www")

            local log_user
            log_user=$(prompt_input "Owner user" "www-data")

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                for log_dir in \
                    "${project_path}/storage/logs" \
                    "${project_path}/shared/storage/logs" \
                    "/var/log/nginx" \
                    "/var/log/php-fpm"; do
                    if [[ ! -d "$log_dir" ]]; then
                        mkdir -p "$log_dir"
                        chown "${log_user}:${log_user}" "$log_dir"
                        chmod 775 "$log_dir"
                        sre_success "Created: $log_dir"
                    else
                        sre_skipped "Already exists: $log_dir"
                    fi
                done
            else
                sre_info "[DRY-RUN] Would create missing log directories"
            fi
            ;;

        fix-logrotate)
            local log_file
            log_file=$(prompt_input "Log file to configure rotation for" "")
            _setup_logrotate_for "$log_file"
            ;;
    esac
}

_setup_logrotate_for() {
    local log_file="$1"
    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        sre_error "Invalid log file: $log_file"
        return 1
    fi

    local rotate_days
    rotate_days=$(prompt_input "Keep logs for how many days?" "14")

    local max_size
    max_size=$(prompt_input "Max size before rotation" "100M")

    local base_name
    base_name=$(basename "$log_file" | tr '.' '_')
    local rotate_conf="/etc/logrotate.d/sre-${base_name}"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        cat > "$rotate_conf" <<ROTATEEOF
${log_file} {
    daily
    rotate ${rotate_days}
    size ${max_size}
    compress
    delaycompress
    missingok
    notifempty
    create 0664 www-data www-data
    copytruncate
}
ROTATEEOF
        sre_success "Logrotate configured: $rotate_conf"
    else
        sre_info "[DRY-RUN] Would create logrotate config at $rotate_conf"
    fi
}

################################################################################
# Fix: ImageMagick & Arabic Rendering
################################################################################

fix_imagick() {
    sre_header "Fix: ImageMagick & Arabic Rendering"

    local issue
    issue=$(prompt_choice "What's the issue?" \
        "arabic-text-broken" \
        "imagick-not-loaded" \
        "wrong-imagick-version" \
        "policy-blocking-operations")

    case "$issue" in
        arabic-text-broken)
            sre_info "Checking Arabic rendering requirements..."

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                local missing=()

                # Check fonts
                if ! fc-list :lang=ar 2>/dev/null | grep -qi "noto\|amiri\|kacst"; then
                    missing+=("arabic-fonts")
                    sre_warning "No Arabic fonts found"
                else
                    sre_success "Arabic fonts: installed"
                fi

                # Check harfbuzz/fribidi/raqm support in ImageMagick
                local im_delegates=""
                if command -v magick &>/dev/null; then
                    im_delegates=$(magick -list configure 2>/dev/null | grep DELEGATES || true)
                elif command -v convert &>/dev/null; then
                    im_delegates=$(convert -list configure 2>/dev/null | grep DELEGATES || true)
                fi

                if [[ -z "$im_delegates" ]]; then
                    sre_warning "Cannot detect ImageMagick delegates"
                    missing+=("imagemagick")
                else
                    echo "$im_delegates" | grep -qi "harfbuzz" || { missing+=("harfbuzz"); sre_warning "Missing: harfbuzz"; }
                    echo "$im_delegates" | grep -qi "fribidi" || { missing+=("fribidi"); sre_warning "Missing: fribidi"; }
                    echo "$im_delegates" | grep -qi "raqm" || { missing+=("raqm"); sre_warning "Missing: raqm"; }
                    echo "$im_delegates" | grep -qi "pango" || { missing+=("pango"); sre_warning "Missing: pango"; }
                fi

                # Check fontconfig
                if ! command -v fc-cache &>/dev/null; then
                    missing+=("fontconfig")
                    sre_warning "fontconfig not installed"
                fi

                if [[ ${#missing[@]} -eq 0 ]]; then
                    sre_success "All Arabic rendering dependencies are present"
                    sre_info "If text still renders incorrectly, check your code uses:"
                    sre_info "  - Explicit Arabic font path (fc-list :lang=ar)"
                    sre_info "  - RTL text direction in Imagick"
                else
                    sre_warning "Missing components: ${missing[*]}"
                    if prompt_yesno "Install missing Arabic rendering dependencies?" "yes"; then
                        case "$SRE_OS_FAMILY" in
                            debian)
                                [[ " ${missing[*]} " =~ "arabic-fonts" ]] && \
                                    pkg_install fonts-noto fonts-arabeyes fonts-hosny-amiri fonts-kacst fonts-kacst-one
                                [[ " ${missing[*]} " =~ "fontconfig" ]] && pkg_install fontconfig
                                [[ " ${missing[*]} " =~ "harfbuzz" ]] && pkg_install libharfbuzz-dev
                                [[ " ${missing[*]} " =~ "fribidi" ]] && pkg_install libfribidi-dev libfribidi0
                                [[ " ${missing[*]} " =~ "raqm" ]] && pkg_install libraqm-dev
                                [[ " ${missing[*]} " =~ "pango" ]] && pkg_install libpango1.0-dev
                                ;;
                            rhel)
                                [[ " ${missing[*]} " =~ "arabic-fonts" ]] && \
                                    pkg_install google-noto-sans-arabic-fonts google-noto-naskh-arabic-fonts
                                [[ " ${missing[*]} " =~ "fontconfig" ]] && pkg_install fontconfig
                                [[ " ${missing[*]} " =~ "harfbuzz" ]] && pkg_install harfbuzz-devel
                                [[ " ${missing[*]} " =~ "fribidi" ]] && pkg_install fribidi-devel
                                [[ " ${missing[*]} " =~ "raqm" ]] && pkg_install libraqm-devel
                                [[ " ${missing[*]} " =~ "pango" ]] && pkg_install pango-devel
                                ;;
                        esac
                        fc-cache -f 2>/dev/null || true
                        sre_success "Dependencies installed"
                        sre_warning "If harfbuzz/fribidi/raqm were missing, ImageMagick needs to be recompiled"
                        sre_warning "Run this fix again and select 'wrong-imagick-version' to rebuild"
                    fi
                fi
            else
                sre_info "[DRY-RUN] Would check and install Arabic rendering dependencies"
            fi
            ;;

        imagick-not-loaded)
            sre_info "Checking PHP imagick extension..."

            local php_ver
            php_ver=$(config_get "SRE_PHP_VERSION" "8.3")

            if php -m 2>/dev/null | grep -qi imagick; then
                sre_success "imagick extension is loaded in CLI"
            else
                sre_warning "imagick extension NOT loaded"

                if prompt_yesno "Install/rebuild imagick extension via PECL?" "yes"; then
                    if [[ "$SRE_DRY_RUN" != "true" ]]; then
                        pkg_install "php${php_ver}-dev" 2>/dev/null || pkg_install php-devel
                        printf "\n" | pecl install imagick 2>/dev/null || true

                        local ini_dir=""
                        case "$SRE_OS_FAMILY" in
                            debian) ini_dir="/etc/php/${php_ver}/mods-available" ;;
                            rhel)   ini_dir="/etc/php.d" ;;
                        esac

                        if [[ -n "$ini_dir" ]]; then
                            mkdir -p "$ini_dir"
                            echo "extension=imagick.so" > "${ini_dir}/imagick.ini"
                            case "$SRE_OS_FAMILY" in
                                debian) phpenmod -v "$php_ver" imagick 2>/dev/null || true ;;
                            esac
                        fi

                        svc_restart "$(get_phpfpm_svc "$php_ver")"
                        sre_success "imagick extension installed and PHP-FPM restarted"
                    fi
                fi
            fi
            ;;

        wrong-imagick-version)
            sre_info "Checking ImageMagick version..."

            local current_ver=""
            if command -v magick &>/dev/null; then
                current_ver=$(magick --version 2>/dev/null | head -1)
            elif command -v convert &>/dev/null; then
                current_ver=$(convert --version 2>/dev/null | head -1)
            fi

            if [[ -n "$current_ver" ]]; then
                sre_info "Current: $current_ver"
            else
                sre_warning "ImageMagick not found"
            fi

            if prompt_yesno "Rebuild ImageMagick 7 from source? (required for Arabic support)" "yes"; then
                sre_info "This will compile ImageMagick 7 with Arabic text support."
                sre_info "It takes 5-10 minutes depending on server specs."
                if prompt_yesno "Continue?" "yes"; then
                    sre_warning "Please run step 4 (PHP) which includes the full IM7 build."
                    sre_info "  sudo bash ${SRE_SCRIPTS_DIR}/stack/04-php.sh"
                fi
            fi
            ;;

        policy-blocking-operations)
            sre_info "Checking ImageMagick policy..."

            local policy_path=""
            for p in /usr/local/etc/ImageMagick-7/policy.xml /etc/ImageMagick-7/policy.xml \
                     /etc/ImageMagick-6/policy.xml /etc/ImageMagick/policy.xml; do
                [[ -f "$p" ]] && policy_path="$p" && break
            done

            if [[ -z "$policy_path" ]]; then
                sre_warning "No policy.xml found"
                return 0
            fi

            sre_info "Policy file: $policy_path"

            local blocked
            blocked=$(grep -i 'rights="none"' "$policy_path" 2>/dev/null || true)
            if [[ -n "$blocked" ]]; then
                sre_warning "Blocked operations found:"
                echo "$blocked" | head -10

                if prompt_yesno "Remove TEXT/LABEL/PANGO restrictions?" "yes"; then
                    if [[ "$SRE_DRY_RUN" != "true" ]]; then
                        backup_config "$policy_path"
                        sed -i '/<policy domain="coder" rights="none" pattern="TEXT"/d' "$policy_path"
                        sed -i '/<policy domain="coder" rights="none" pattern="LABEL"/d' "$policy_path"
                        sed -i '/<policy domain="coder" rights="none" pattern="PANGO"/d' "$policy_path"
                        sre_success "TEXT/LABEL/PANGO restrictions removed"
                    fi
                fi

                if prompt_yesno "Remove PDF/PS restrictions too? (needed for PDF generation)" "no"; then
                    if [[ "$SRE_DRY_RUN" != "true" ]]; then
                        sed -i '/<policy domain="coder" rights="none" pattern="PDF"/d' "$policy_path"
                        sed -i '/<policy domain="coder" rights="none" pattern="PS"/d' "$policy_path"
                        sed -i '/<policy domain="coder" rights="none" pattern="EPS"/d' "$policy_path"
                        sre_success "PDF/PS/EPS restrictions removed"
                    fi
                fi
            else
                sre_success "No blocked operations found in policy"
            fi
            ;;
    esac
}

################################################################################
# Fix: Change PHP Version for a Project
################################################################################

fix_php_version() {
    sre_header "Fix: Change PHP Version for a Project"

    local domain
    domain=$(prompt_input "Domain name" "")
    [[ -z "$domain" ]] && { sre_error "Domain is required."; return 1; }

    local web_server
    web_server=$(config_get "SRE_WEB_SERVER" "nginx")
    local os_family
    os_family=$(config_get "SRE_OS_FAMILY" "debian")

    # Detect installed PHP versions
    sre_info "Detecting installed PHP versions..."
    local installed_versions=()
    if [[ "$os_family" == "debian" ]]; then
        while IFS= read -r fpm_svc; do
            local ver
            ver=$(echo "$fpm_svc" | grep -oP 'php\K[0-9]+\.[0-9]+')
            [[ -n "$ver" ]] && installed_versions+=("$ver")
        done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
    else
        installed_versions+=("$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.3")")
    fi

    if [[ ${#installed_versions[@]} -eq 0 ]]; then
        sre_error "No PHP-FPM versions detected"
        return 1
    fi

    if [[ ${#installed_versions[@]} -eq 1 ]]; then
        sre_warning "Only one PHP version installed: ${installed_versions[0]}"
        sre_info "Install additional versions with step 4 (set SRE_PHP_EXTRA_VERSIONS in config first)"
        return 0
    fi

    sre_info "Installed PHP versions: ${installed_versions[*]}"

    # Detect current version from vhost config
    local vhost_file=""
    case "$web_server" in
        nginx)
            vhost_file="/etc/nginx/sites-available/${domain}.conf"
            [[ ! -f "$vhost_file" ]] && vhost_file="/etc/nginx/conf.d/${domain}.conf"
            ;;
        apache)
            vhost_file="/etc/apache2/sites-available/${domain}.conf"
            [[ ! -f "$vhost_file" ]] && vhost_file="/etc/httpd/conf.d/${domain}.conf"
            ;;
    esac

    if [[ ! -f "$vhost_file" ]]; then
        sre_error "Vhost config not found for $domain"
        return 1
    fi

    local current_ver
    current_ver=$(grep -oP 'php\K[0-9]+\.[0-9]+' "$vhost_file" | head -1)
    [[ -n "$current_ver" ]] && sre_info "Current PHP version in vhost: $current_ver"

    local new_ver
    new_ver=$(prompt_choice "Select new PHP version:" "${installed_versions[@]}")

    if [[ "$new_ver" == "$current_ver" ]]; then
        sre_skipped "Already using PHP $new_ver"
        return 0
    fi

    sre_info "Switching $domain from PHP ${current_ver:-unknown} to PHP $new_ver"

    if ! prompt_yesno "Proceed?" "yes"; then
        sre_skipped "PHP version change cancelled"
        return 0
    fi

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        backup_config "$vhost_file"

        # Replace PHP version in vhost config (socket path and any version references)
        if [[ -n "$current_ver" ]]; then
            sed -i "s|php${current_ver}|php${new_ver}|g" "$vhost_file"
        else
            sre_warning "Could not detect current version — updating socket path manually"
            sed -i "s|php[0-9]\+\.[0-9]\+-fpm|php${new_ver}-fpm|g" "$vhost_file"
        fi

        # Verify new FPM service is running
        local new_fpm
        new_fpm=$(get_phpfpm_svc "$new_ver")
        if ! systemctl is-active --quiet "$new_fpm" 2>/dev/null; then
            sre_warning "$new_fpm not running — starting it..."
            svc_enable_start "$new_fpm"
        fi

        # Also update PHP-FPM pool if it exists
        local pool_dir
        pool_dir=$(get_phpfpm_pool_dir "$new_ver")
        local old_pool_dir
        old_pool_dir=$(get_phpfpm_pool_dir "${current_ver:-$new_ver}")

        if [[ -n "$current_ver" && -f "${old_pool_dir}/${domain}.conf" && "$old_pool_dir" != "$pool_dir" ]]; then
            cp "${old_pool_dir}/${domain}.conf" "${pool_dir}/${domain}.conf"
            # Update socket path in pool config
            sed -i "s|php${current_ver}|php${new_ver}|g" "${pool_dir}/${domain}.conf"
            sre_success "Pool config copied to ${pool_dir}/${domain}.conf"
            svc_restart "$new_fpm"
        fi

        # Test and reload web server
        case "$web_server" in
            nginx)
                if nginx -t 2>&1; then
                    svc_reload nginx
                    sre_success "Nginx reloaded"
                else
                    sre_error "Nginx config test failed! Restoring backup..."
                    cp "${vhost_file}.bak."* "$vhost_file" 2>/dev/null || true
                    return 1
                fi
                ;;
            apache)
                local test_cmd="apachectl configtest"
                [[ "$os_family" == "rhel" ]] && test_cmd="httpd -t"
                if $test_cmd 2>&1; then
                    svc_reload "$(get_webserver_svc apache)"
                    sre_success "Apache reloaded"
                else
                    sre_error "Apache config test failed!"
                    return 1
                fi
                ;;
        esac

        sre_success "PHP version for $domain changed to $new_ver"
    else
        sre_info "[DRY-RUN] Would switch $domain from PHP ${current_ver:-unknown} to PHP $new_ver"
    fi
}

################################################################################
# Fix: Moodle Temp/Request Directories (invaliddatarootpermissions)
################################################################################

fix_moodle_temp() {
    sre_header "Fix: Moodle Temp & Request Directories"

    sre_info "This fixes the 'invaliddatarootpermissions' error:"
    sre_info "  '/tmp/requestdir/xxx can not be created, check permissions'"
    echo ""

    local web_user
    web_user=$(prompt_input "Web server user" "www-data")

    local moodledata
    moodledata=$(prompt_input "Moodledata path" "/var/www/moodledata")

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        # Fix /tmp permissions (must be 1777 — sticky bit)
        sre_info "Fixing /tmp permissions..."
        chmod 1777 /tmp
        chown root:root /tmp

        # Clean stale requestdir owned by wrong user
        if [[ -d /tmp/requestdir ]]; then
            sre_info "Fixing existing /tmp/requestdir..."
            chown -R "${web_user}:${web_user}" /tmp/requestdir
            chmod -R 775 /tmp/requestdir
        fi

        # Fix moodledata and its subdirs
        if [[ -d "$moodledata" ]]; then
            sre_info "Fixing moodledata permissions: $moodledata"
            chown -R "${web_user}:${web_user}" "$moodledata"
            chmod 775 "$moodledata"

            # Create and fix all Moodle writable subdirectories
            for subdir in temp localcache cache requestdir trashdir sessions filedir lang; do
                mkdir -p "${moodledata}/${subdir}"
                chown -R "${web_user}:${web_user}" "${moodledata}/${subdir}"
                chmod -R 775 "${moodledata}/${subdir}"
            done
            sre_success "Moodledata subdirectories fixed"

            # Set default ACLs so new files inherit correct ownership
            if command -v setfacl &>/dev/null; then
                setfacl -R -m "u:${web_user}:rwX" "$moodledata"
                setfacl -R -d -m "u:${web_user}:rwX" "$moodledata"
                sre_success "Default ACLs applied on moodledata"
            fi
        else
            sre_warning "Moodledata path not found: $moodledata"
            if prompt_yesno "Create it?" "yes"; then
                mkdir -p "$moodledata"
                chown -R "${web_user}:${web_user}" "$moodledata"
                chmod 775 "$moodledata"
                sre_success "Created: $moodledata"
            fi
        fi

        # Check if localrequestdir is configured in config.php
        if prompt_yesno "Check Moodle config.php for custom temp paths?" "yes"; then
            local config_php
            config_php=$(prompt_input "Path to config.php" "/var/www/${moodledata%%/moodledata*}/public_html/config.php")

            if [[ -f "$config_php" ]]; then
                local has_requestdir
                has_requestdir=$(grep -c 'localrequestdir\|tempdir\|localcachedir' "$config_php" 2>/dev/null || echo "0")

                if [[ "$has_requestdir" -eq 0 ]]; then
                    sre_info "No custom temp paths in config.php"
                    sre_info "Moodle is using /tmp for request storage"
                    sre_info "Consider adding to config.php:"
                    sre_info "  \$CFG->localrequestdir = '${moodledata}/requestdir';"
                    sre_info "  \$CFG->tempdir = '${moodledata}/temp';"
                    sre_info "  \$CFG->localcachedir = '${moodledata}/localcache';"

                    if prompt_yesno "Add these lines to config.php now?" "yes"; then
                        # Insert before the require_once line at end of config.php
                        sed -i "/require_once.*setup\.php/i\\
\$CFG->localrequestdir = '${moodledata}/requestdir';\\
\$CFG->tempdir = '${moodledata}/temp';\\
\$CFG->localcachedir = '${moodledata}/localcache';\\
\$CFG->directorypermissions = 0775;" "$config_php"
                        chown "${web_user}:${web_user}" "$config_php"
                        sre_success "config.php updated with custom temp paths"
                    fi
                else
                    sre_info "Custom temp paths already configured in config.php:"
                    grep -E 'localrequestdir|tempdir|localcachedir' "$config_php" | sed 's/^/  /'
                fi
            else
                sre_warning "config.php not found at: $config_php"
            fi
        fi

        sre_success "Moodle temp/request directory fix complete"
    else
        sre_info "[DRY-RUN] Would fix /tmp (1777), moodledata permissions, and configure localrequestdir"
    fi
}

################################################################################
# Fix: PHP Limits & Extensions
################################################################################

fix_php() {
    sre_header "Fix: PHP Limits & Extensions"

    local issue
    issue=$(prompt_choice "What's the issue?" \
        "upload-size-too-small" \
        "memory-limit-too-low" \
        "extension-not-loaded" \
        "fpm-not-running" \
        "show-current-limits")

    local php_ver
    php_ver=$(config_get "SRE_PHP_VERSION" "8.3")

    case "$issue" in
        upload-size-too-small)
            local new_size
            new_size=$(prompt_input "New upload_max_filesize (e.g. 256M, 512M)" "256M")

            local post_size
            post_size=$(prompt_input "New post_max_size (should be >= upload size)" "$new_size")

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                for ini_file in "/etc/php/${php_ver}/fpm/php.ini" "/etc/php/${php_ver}/cli/php.ini" "/etc/php.ini"; do
                    [[ ! -f "$ini_file" ]] && continue
                    sed -i "s/^[;]*\s*upload_max_filesize\s*=.*/upload_max_filesize = ${new_size}/" "$ini_file"
                    sed -i "s/^[;]*\s*post_max_size\s*=.*/post_max_size = ${post_size}/" "$ini_file"
                    sre_success "Updated: $ini_file"
                done
                svc_restart "$(get_phpfpm_svc "$php_ver")"

                # Also fix nginx
                if prompt_yesno "Also update nginx client_max_body_size to match?" "yes"; then
                    local nginx_conf="/etc/nginx/conf.d/security.conf"
                    if [[ -f "$nginx_conf" ]]; then
                        if grep -q "client_max_body_size" "$nginx_conf"; then
                            sed -i "s/client_max_body_size.*/client_max_body_size ${new_size};/" "$nginx_conf"
                        else
                            echo "client_max_body_size ${new_size};" >> "$nginx_conf"
                        fi
                        nginx -t 2>/dev/null && svc_reload nginx
                        sre_success "Nginx client_max_body_size updated to ${new_size}"
                    else
                        sre_warning "Nginx security.conf not found at $nginx_conf"
                    fi
                fi
            else
                sre_info "[DRY-RUN] Would set upload_max_filesize=$new_size, post_max_size=$post_size"
            fi
            ;;

        memory-limit-too-low)
            local new_limit
            new_limit=$(prompt_input "New memory_limit (e.g. 512M, 1024M, 2048M)" "1024M")

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                for ini_file in "/etc/php/${php_ver}/fpm/php.ini" "/etc/php/${php_ver}/cli/php.ini" "/etc/php.ini"; do
                    [[ ! -f "$ini_file" ]] && continue
                    sed -i "s/^[;]*\s*memory_limit\s*=.*/memory_limit = ${new_limit}/" "$ini_file"
                    sre_success "Updated: $ini_file"
                done
                svc_restart "$(get_phpfpm_svc "$php_ver")"
                sre_success "PHP memory_limit set to $new_limit"
            else
                sre_info "[DRY-RUN] Would set memory_limit=$new_limit"
            fi
            ;;

        extension-not-loaded)
            local ext_name
            ext_name=$(prompt_input "Extension name (e.g. imagick, redis, gd, intl)" "")

            if [[ -z "$ext_name" ]]; then
                sre_error "Extension name is required"
                return 1
            fi

            if php -m 2>/dev/null | grep -qi "$ext_name"; then
                sre_success "Extension '$ext_name' is already loaded"
                return 0
            fi

            sre_warning "Extension '$ext_name' is NOT loaded"

            if prompt_yesno "Try to install php${php_ver}-${ext_name}?" "yes"; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    case "$SRE_OS_FAMILY" in
                        debian) pkg_install "php${php_ver}-${ext_name}" ;;
                        rhel)   pkg_install "php-${ext_name}" ;;
                    esac
                    svc_restart "$(get_phpfpm_svc "$php_ver")"

                    if php -m 2>/dev/null | grep -qi "$ext_name"; then
                        sre_success "Extension '$ext_name' installed and loaded"
                    else
                        sre_warning "Package installed but extension not loading. Check php.ini."
                    fi
                fi
            fi
            ;;

        fpm-not-running)
            local fpm_svc
            fpm_svc=$(get_phpfpm_svc "$php_ver")
            sre_info "Checking $fpm_svc status..."

            if systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                sre_success "$fpm_svc is running"
            else
                sre_warning "$fpm_svc is NOT running"
                sre_info "Recent logs:"
                journalctl -u "$fpm_svc" --no-pager -n 10 2>/dev/null || true

                if prompt_yesno "Try to start $fpm_svc?" "yes"; then
                    if [[ "$SRE_DRY_RUN" != "true" ]]; then
                        svc_enable_start "$fpm_svc"
                        if systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                            sre_success "$fpm_svc started successfully"
                        else
                            sre_error "$fpm_svc failed to start. Check: journalctl -u $fpm_svc"
                        fi
                    fi
                fi
            fi
            ;;

        show-current-limits)
            sre_info "PHP CLI limits:"
            php -i 2>/dev/null | grep -E "upload_max_filesize|post_max_size|memory_limit|max_execution_time|max_input_time|max_file_uploads" | head -10
            echo ""
            sre_info "PHP-FPM config files:"
            for ini_file in "/etc/php/${php_ver}/fpm/php.ini" "/etc/php.ini"; do
                if [[ -f "$ini_file" ]]; then
                    sre_info "  $ini_file:"
                    grep -E "^(upload_max_filesize|post_max_size|memory_limit|max_execution_time|max_input_time)" "$ini_file" | sed 's/^/    /'
                fi
            done
            ;;
    esac
}

################################################################################
# Fix: Nginx / Web Server
################################################################################

fix_nginx() {
    sre_header "Fix: Nginx / Web Server"

    local issue
    issue=$(prompt_choice "What's the issue?" \
        "body-too-large" \
        "502-bad-gateway" \
        "config-test-failed" \
        "reload-nginx" \
        "show-error-log")

    case "$issue" in
        body-too-large)
            sre_info "This is the 'client intended to send too large body' error"
            local new_size
            new_size=$(prompt_input "New client_max_body_size" "256M")

            local scope
            scope=$(prompt_choice "Apply to:" "global" "specific-vhost")

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                if [[ "$scope" == "global" ]]; then
                    local conf="/etc/nginx/conf.d/security.conf"
                    if [[ -f "$conf" ]]; then
                        if grep -q "client_max_body_size" "$conf"; then
                            sed -i "s/client_max_body_size.*/client_max_body_size ${new_size};/" "$conf"
                        else
                            echo "client_max_body_size ${new_size};" >> "$conf"
                        fi
                    else
                        echo "client_max_body_size ${new_size};" > "$conf"
                    fi
                    sre_success "Global client_max_body_size set to ${new_size}"
                else
                    local vhost_domain
                    vhost_domain=$(prompt_input "Domain name" "")
                    local vhost_file="/etc/nginx/sites-available/${vhost_domain}.conf"
                    [[ ! -f "$vhost_file" ]] && vhost_file="/etc/nginx/conf.d/${vhost_domain}.conf"

                    if [[ -f "$vhost_file" ]]; then
                        if grep -q "client_max_body_size" "$vhost_file"; then
                            sed -i "s/client_max_body_size.*/client_max_body_size ${new_size};/" "$vhost_file"
                        else
                            sed -i "/server_name/a\\    client_max_body_size ${new_size};" "$vhost_file"
                        fi
                        sre_success "Vhost client_max_body_size set to ${new_size}"
                    else
                        sre_error "Vhost config not found for $vhost_domain"
                        return 1
                    fi
                fi

                if nginx -t 2>&1; then
                    svc_reload nginx
                    sre_success "Nginx reloaded"
                else
                    sre_error "Nginx config test failed!"
                fi
            else
                sre_info "[DRY-RUN] Would set client_max_body_size to ${new_size}"
            fi
            ;;

        502-bad-gateway)
            sre_info "502 usually means PHP-FPM is down or socket mismatch"

            local php_ver
            php_ver=$(config_get "SRE_PHP_VERSION" "8.3")
            local fpm_svc
            fpm_svc=$(get_phpfpm_svc "$php_ver")

            sre_info "Checking $fpm_svc..."
            if systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                sre_success "$fpm_svc is running"
                sre_info "Check socket path matches nginx config:"
                grep -r "fastcgi_pass\|php-fpm" /etc/nginx/sites-enabled/ 2>/dev/null | head -5
                sre_info "FPM listen directive:"
                grep -r "^listen\s*=" /etc/php/${php_ver}/fpm/pool.d/ 2>/dev/null | head -5
            else
                sre_warning "$fpm_svc is NOT running"
                if prompt_yesno "Restart $fpm_svc?" "yes"; then
                    if [[ "$SRE_DRY_RUN" != "true" ]]; then
                        svc_restart "$fpm_svc"
                        sre_success "$fpm_svc restarted"
                    fi
                fi
            fi
            ;;

        config-test-failed)
            sre_info "Running nginx -t..."
            nginx -t 2>&1
            ;;

        reload-nginx)
            if nginx -t 2>&1; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    svc_reload nginx
                    sre_success "Nginx reloaded successfully"
                fi
            else
                sre_error "Config test failed — fix errors first"
            fi
            ;;

        show-error-log)
            local lines
            lines=$(prompt_input "Number of lines to show" "50")
            sre_info "Last $lines lines of /var/log/nginx/error.log:"
            tail -n "$lines" /var/log/nginx/error.log 2>/dev/null || sre_error "Cannot read nginx error log"
            ;;
    esac
}

################################################################################
# Fix: Database Charset
################################################################################

fix_db_charset() {
    sre_header "Fix: Database Charset (UTF-8/Arabic)"

    local db_engines_cfg
    db_engines_cfg=$(config_get "SRE_DB_ENGINE" "mariadb")

    # Check if any MySQL-compatible engine is installed
    local db_engine=""
    if [[ ",$db_engines_cfg," == *",mariadb,"* ]]; then
        db_engine="mariadb"
    elif [[ ",$db_engines_cfg," == *",mysql,"* ]]; then
        db_engine="mysql"
    else
        sre_info "No MySQL/MariaDB engine found. PostgreSQL uses UTF-8 by default."
        return 0
    fi

    local issue
    issue=$(prompt_choice "What's the issue?" \
        "set-server-default-utf8mb4" \
        "convert-database" \
        "convert-table" \
        "check-current-charset")

    case "$issue" in
        set-server-default-utf8mb4)
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                local cnf_dir="/etc/mysql/conf.d"
                [[ "$SRE_OS_FAMILY" == "rhel" ]] && cnf_dir="/etc/my.cnf.d"
                mkdir -p "$cnf_dir"

                cat > "${cnf_dir}/utf8mb4.cnf" <<'EOCNF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
EOCNF

                svc_restart "$(get_db_svc "$db_engine")"
                sre_success "Server default charset set to utf8mb4"
            else
                sre_info "[DRY-RUN] Would set server default to utf8mb4"
            fi
            ;;

        convert-database)
            local db_name
            db_name=$(prompt_input "Database name to convert" "")

            if [[ -z "$db_name" ]]; then
                sre_error "Database name is required"
                return 1
            fi

            local collation
            collation=$(prompt_choice "Collation:" "utf8mb4_unicode_ci" "utf8mb4_general_ci" "utf8mb4_bin")

            sre_warning "This will convert database '$db_name' to utf8mb4 / $collation"
            if prompt_yesno "Proceed? (make sure you have a backup)" "no"; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    mysql -e "ALTER DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE ${collation};" 2>&1
                    sre_success "Database '$db_name' converted to utf8mb4"
                    sre_warning "Individual tables may still need conversion — use 'convert-table' option"
                fi
            fi
            ;;

        convert-table)
            local db_name
            db_name=$(prompt_input "Database name" "")
            local table_name
            table_name=$(prompt_input "Table name (or 'all' for all tables)" "all")

            local collation
            collation=$(prompt_choice "Collation:" "utf8mb4_unicode_ci" "utf8mb4_general_ci")

            sre_warning "This will convert tables to utf8mb4 / $collation"
            if prompt_yesno "Proceed? (make sure you have a backup)" "no"; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    if [[ "$table_name" == "all" ]]; then
                        local tables
                        tables=$(mysql -N -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_name}';")
                        local count=0
                        while IFS= read -r tbl; do
                            [[ -z "$tbl" ]] && continue
                            mysql -e "ALTER TABLE \`${db_name}\`.\`${tbl}\` CONVERT TO CHARACTER SET utf8mb4 COLLATE ${collation};" 2>&1 || true
                            ((count++))
                        done <<< "$tables"
                        sre_success "Converted $count tables in '$db_name' to utf8mb4"
                    else
                        mysql -e "ALTER TABLE \`${db_name}\`.\`${table_name}\` CONVERT TO CHARACTER SET utf8mb4 COLLATE ${collation};" 2>&1
                        sre_success "Table '${db_name}.${table_name}' converted to utf8mb4"
                    fi
                fi
            fi
            ;;

        check-current-charset)
            sre_info "Server-level charset:"
            mysql -e "SHOW VARIABLES LIKE 'character_set%';" 2>/dev/null || sre_error "Cannot connect to MySQL"
            echo ""
            sre_info "Server-level collation:"
            mysql -e "SHOW VARIABLES LIKE 'collation%';" 2>/dev/null || true

            if prompt_yesno "Check a specific database?" "no"; then
                local db_name
                db_name=$(prompt_input "Database name" "")
                if [[ -n "$db_name" ]]; then
                    sre_info "Database '$db_name' charset:"
                    mysql -e "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}';" 2>/dev/null
                    echo ""
                    sre_info "Tables with non-utf8mb4 charset:"
                    mysql -e "SELECT TABLE_NAME, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_name}' AND TABLE_COLLATION NOT LIKE 'utf8mb4%';" 2>/dev/null
                fi
            fi
            ;;
    esac
}

################################################################################
# Fix: Locale & Encoding
################################################################################

fix_locale() {
    sre_header "Fix: Locale & Encoding"

    sre_info "Current locale:"
    locale 2>/dev/null | head -5
    echo ""

    local issue
    issue=$(prompt_choice "What to fix?" \
        "install-arabic-locale" \
        "set-system-utf8" \
        "check-available-locales")

    case "$issue" in
        install-arabic-locale)
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                case "$SRE_OS_FAMILY" in
                    debian)
                        pkg_install locales language-pack-ar language-pack-en 2>/dev/null || pkg_install locales
                        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
                        sed -i 's/^# *ar_SA.UTF-8 UTF-8/ar_SA.UTF-8 UTF-8/' /etc/locale.gen
                        grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
                        grep -q '^ar_SA.UTF-8 UTF-8' /etc/locale.gen || echo 'ar_SA.UTF-8 UTF-8' >> /etc/locale.gen
                        locale-gen
                        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                        ;;
                    rhel)
                        pkg_install glibc-langpack-en glibc-langpack-ar
                        localectl set-locale LANG=en_US.UTF-8
                        ;;
                esac
                sre_success "Arabic and English UTF-8 locales installed"
            else
                sre_info "[DRY-RUN] Would install ar_SA.UTF-8 and en_US.UTF-8 locales"
            fi
            ;;

        set-system-utf8)
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                case "$SRE_OS_FAMILY" in
                    debian) update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ;;
                    rhel)   localectl set-locale LANG=en_US.UTF-8 ;;
                esac
                sre_success "System locale set to en_US.UTF-8"
                sre_warning "You may need to log out and back in for changes to take effect"
            fi
            ;;

        check-available-locales)
            sre_info "Available Arabic/English locales:"
            locale -a 2>/dev/null | grep -Ei "^(ar|en)" || sre_warning "No matching locales found"
            ;;
    esac
}

################################################################################
# Main Menu
################################################################################

_run_fix_menu() {
    while true; do
        sre_header "Quick Fixes Menu"

        local fix_choice
        fix_choice=$(prompt_choice "Select a fix category:" \
            "permissions-ownership" \
            "filesystem-acl" \
            "change-php-version" \
            "moodle-temp-dirs" \
            "log-files" \
            "imagick-arabic" \
            "php-limits-extensions" \
            "nginx-webserver" \
            "database-charset" \
            "locale-encoding" \
            "exit")

        case "$fix_choice" in
            permissions-ownership)  fix_permissions ;;
            filesystem-acl)         fix_acl ;;
            change-php-version)     fix_php_version ;;
            moodle-temp-dirs)       fix_moodle_temp ;;
            log-files)              fix_logs ;;
            imagick-arabic)         fix_imagick ;;
            php-limits-extensions)  fix_php ;;
            nginx-webserver)        fix_nginx ;;
            database-charset)       fix_db_charset ;;
            locale-encoding)        fix_locale ;;
            exit)
                sre_info "Exiting fixes menu."
                break
                ;;
        esac

        echo ""
        if ! prompt_yesno "Run another fix?" "yes"; then
            break
        fi
    done
}

_run_fix_menu

sre_success "Fixes session complete!"

recommend_next_step "$CURRENT_STEP"
