#!/bin/bash
################################################################################
# SRE Helpers - Step 4: PHP Installation
# Installs PHP-FPM with common extensions and applies secure php.ini defaults.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=4

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 4: PHP Installation
  Installs PHP-FPM and common extensions (mysql, pgsql, mbstring, xml, curl,
  zip, gd, intl, bcmath, soap, redis, imagick, opcache).
  Configures secure php.ini defaults.

Prerequisites: Step 1 (base-setup) and Step 3 (web-server) must be complete.

Options:
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes --dry-run
EOF
}

sre_parse_args "04-php.sh" "$@"
require_root

sre_header "Step 4: PHP Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

require_config_key "SRE_PHP_VERSION" "1" > /dev/null
require_config_key "SRE_WEB_SERVER_INSTALLED" "3" > /dev/null

SRE_OS_FAMILY="$(config_get SRE_OS_FAMILY)"
SRE_PHP_VERSION="$(config_get SRE_PHP_VERSION)"

sre_info "OS family: $SRE_OS_FAMILY"
sre_info "PHP version: $SRE_PHP_VERSION"

# --- Install PHP-FPM and Extensions ---
sre_header "Installing PHP ${SRE_PHP_VERSION}"

local_ver="${SRE_PHP_VERSION}"

case "$SRE_OS_FAMILY" in
    debian)
        # Add ondrej/php PPA if not already present
        if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
            sre_info "Adding ondrej/php PPA..."
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                pkg_install software-properties-common
                add-apt-repository -y ppa:ondrej/php
                pkg_update
            else
                sre_info "[DRY-RUN] Would add ondrej/php PPA"
            fi
        else
            sre_skipped "ondrej/php PPA already present"
        fi

        php_packages=(
            "php${local_ver}-fpm"
            "php${local_ver}-cli"
            "php${local_ver}-mysql"
            "php${local_ver}-pgsql"
            "php${local_ver}-mbstring"
            "php${local_ver}-xml"
            "php${local_ver}-curl"
            "php${local_ver}-zip"
            "php${local_ver}-gd"
            "php${local_ver}-intl"
            "php${local_ver}-bcmath"
            "php${local_ver}-soap"
            "php${local_ver}-redis"
            "php${local_ver}-imagick"
            "php${local_ver}-opcache"
        )

        sre_info "Installing PHP packages: ${php_packages[*]}"
        pkg_install "${php_packages[@]}"
        ;;

    rhel)
        # Enable Remi repository for PHP 8.x
        if ! rpm -q remi-release &>/dev/null; then
            sre_info "Enabling Remi repository for PHP ${local_ver}..."
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                os_ver=""
                os_ver="$(config_get SRE_OS_VERSION)"
                remi_major="${os_ver%%.*}"
                dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${remi_major}.rpm" || true
                dnf module -y reset php 2>/dev/null || true
                remi_stream="${local_ver//./}"
                dnf module -y enable "php:remi-${local_ver}" 2>/dev/null || true
            else
                sre_info "[DRY-RUN] Would enable Remi repository"
            fi
        else
            sre_skipped "Remi repository already enabled"
        fi

        php_packages=(
            php-fpm
            php-cli
            php-mysqlnd
            php-pgsql
            php-mbstring
            php-xml
            php-curl
            php-zip
            php-gd
            php-intl
            php-bcmath
            php-soap
            php-pecl-redis
            php-imagick
            php-opcache
        )

        sre_info "Installing PHP packages: ${php_packages[*]}"
        pkg_install "${php_packages[@]}"
        ;;
esac

sre_success "PHP ${local_ver} packages installed"

# --- Configure Secure php.ini Defaults ---
sre_header "Configuring php.ini"

case "$SRE_OS_FAMILY" in
    debian)
        php_ini="/etc/php/${local_ver}/fpm/php.ini"
        ;;
    rhel)
        php_ini="/etc/php.ini"
        ;;
esac

if [[ ! -f "$php_ini" ]]; then
    sre_error "php.ini not found at $php_ini"
    exit 1
fi

sre_info "Configuring $php_ini"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    backup_config "$php_ini"

    # Security settings
    sed -i 's/^expose_php\s*=.*/expose_php = Off/' "$php_ini"

    # Disable dangerous functions — keep exec/proc_open/popen for Laravel, Composer, Horizon
    # Only block functions with no legitimate use in web apps
    sed -i 's/^[;]*\s*disable_functions\s*=.*/disable_functions = passthru,shell_exec,system/' "$php_ini"

    # Upload and memory limits — sed handles both active and commented lines
    sed -i 's/^[;]*\s*upload_max_filesize\s*=.*/upload_max_filesize = 64M/' "$php_ini"
    sed -i 's/^[;]*\s*post_max_size\s*=.*/post_max_size = 64M/' "$php_ini"
    sed -i 's/^[;]*\s*memory_limit\s*=.*/memory_limit = 256M/' "$php_ini"
    sed -i 's/^[;]*\s*max_execution_time\s*=.*/max_execution_time = 300/' "$php_ini"

    sre_success "php.ini configured with secure defaults"
else
    sre_info "[DRY-RUN] Would configure $php_ini:"
    sre_info "  expose_php = Off"
    sre_info "  disable_functions = passthru,shell_exec,system"
    sre_info "  upload_max_filesize = 64M"
    sre_info "  post_max_size = 64M"
    sre_info "  memory_limit = 256M"
    sre_info "  max_execution_time = 300"
fi

# --- Enable and Start PHP-FPM ---
sre_header "Starting PHP-FPM"

case "$SRE_OS_FAMILY" in
    debian)
        fpm_service="php${local_ver}-fpm"
        ;;
    rhel)
        fpm_service="php-fpm"
        ;;
esac

sre_info "Enabling and starting $fpm_service..."
svc_enable_start "$fpm_service"
sre_success "$fpm_service is running"

# --- Persist config ---
config_set "SRE_PHP_INSTALLED" "true"

sre_success "PHP ${local_ver} installation and configuration complete!"
sre_info "Config saved to: $SRE_CONFIG_FILE"

recommend_next_step "$CURRENT_STEP"
