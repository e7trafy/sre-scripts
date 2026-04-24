#!/bin/bash
################################################################################
# SRE Helpers - Step 1: Base Server Setup
# Detects OS and specs, prompts for stack choices, installs essentials,
# configures swap, optionally hardens SSH.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=1

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 1: Base Server Setup
  Detects server hardware, prompts for stack choices (LAMP/LEMP),
  installs essential packages, configures swap, and optionally hardens SSH.

Options:
  --dry-run   Print planned actions without executing
  --yes       Accept all defaults without prompting
  --config    Override config file path (default: /etc/sre-helpers/setup.conf)
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes --dry-run
EOF
}

sre_parse_args "01-base-setup.sh" "$@"
require_root

sre_header "Step 1: Base Server Setup"

# Check if already completed -- still re-detect specs but skip prompts
if config_load && [[ "$(config_get SRE_BASE_SETUP_DONE)" == "true" ]]; then
    sre_info "Base setup was previously completed. Re-detecting specs..."
fi

# Detect OS and specs
detect_os
detect_specs

# Initialize config
config_init

# Persist detected values
config_set "SRE_OS_FAMILY" "$SRE_OS_FAMILY"
config_set "SRE_OS_ID" "$SRE_OS_ID"
config_set "SRE_OS_VERSION" "$SRE_OS_VERSION"
config_set "SRE_CPU_CORES" "$SRE_CPU_CORES"
config_set "SRE_RAM_MB" "$SRE_RAM_MB"
config_set "SRE_DISK_TYPE" "$SRE_DISK_TYPE"
config_set "SRE_HOSTNAME" "$SRE_HOSTNAME"

# --- Stack Choice ---
sre_header "Stack Selection"

stack=$(prompt_choice "Select web stack:" "lemp" "lamp")
if [[ "$stack" == "lamp" ]]; then
    web_server="apache"
else
    web_server="nginx"
fi
config_set "SRE_STACK" "$stack"
config_set "SRE_WEB_SERVER" "$web_server"
sre_info "Selected stack: $stack (web server: $web_server)"

# --- PHP Version ---
php_version=$(prompt_choice "Select default PHP version:" "8.3" "8.1" "8.2" "8.4")
config_set "SRE_PHP_VERSION" "$php_version"
sre_info "Default PHP version: $php_version"

# Additional PHP versions
extra_php_versions=""
if prompt_yesno "Install additional PHP versions? (for multi-project support)" "no"; then
    sre_info "Select extra versions to install (comma-separated):"
    sre_info "  Available: 8.1, 8.2, 8.3, 8.4"
    sre_info "  Default ($php_version) is already included"
    extra_php_versions=$(prompt_input "Extra PHP versions (e.g. 8.1,8.2)" "")
    if [[ -n "$extra_php_versions" ]]; then
        config_set "SRE_PHP_EXTRA_VERSIONS" "$extra_php_versions"
        sre_info "Extra PHP versions: $extra_php_versions"
    fi
else
    config_set "SRE_PHP_EXTRA_VERSIONS" ""
fi

# --- Database Engines (multi-select) ---
sre_info "You can install multiple database engines side by side."
sre_info "Note: MariaDB and MySQL are mutually exclusive (cannot coexist)."

db_engines=""

mysql_compat=$(prompt_choice "MySQL-compatible engine:" "mariadb" "mysql" "skip")
if [[ "$mysql_compat" != "skip" ]]; then
    db_engines="$mysql_compat"
fi

if prompt_yesno "Also install PostgreSQL?" "no"; then
    [[ -n "$db_engines" ]] && db_engines="${db_engines},postgresql" || db_engines="postgresql"
fi

[[ -z "$db_engines" ]] && db_engines="none"
config_set "SRE_DB_ENGINE" "$db_engines"
sre_info "Selected database(s): $db_engines"

# --- Redis ---
if prompt_yesno "Install Redis? (caching, sessions, queues)" "yes"; then
    config_set "SRE_REDIS" "true"
    sre_info "Redis: will be installed"
else
    config_set "SRE_REDIS" "false"
    sre_info "Redis: skipped"
fi

# --- Node.js ---
if prompt_yesno "Install Node.js?" "yes"; then
    node_version=$(prompt_choice "Select Node.js version:" "20" "22")
    config_set "SRE_NODE_VERSION" "$node_version"
    sre_info "Selected Node.js version: $node_version"
else
    config_set "SRE_NODE_VERSION" ""
    sre_info "Node.js: skipped"
fi

# --- Supervisor ---
if prompt_yesno "Install Supervisor? (process manager for Laravel queues, Horizon, etc.)" "yes"; then
    config_set "SRE_SUPERVISOR" "true"
    sre_info "Supervisor: will be installed"
else
    config_set "SRE_SUPERVISOR" "false"
    sre_info "Supervisor: skipped"
fi

# --- Install Essential Packages ---
sre_header "Installing Essential Packages"

pkg_update

case "$SRE_OS_FAMILY" in
    debian)
        pkg_install curl wget git unzip acl software-properties-common \
            apt-transport-https ca-certificates gnupg lsb-release
        ;;
    rhel)
        pkg_install curl wget git unzip acl epel-release \
            ca-certificates gnupg2
        ;;
esac
sre_success "Essential packages installed"

# Install supervisor if selected
if [[ "$(config_get SRE_SUPERVISOR)" == "true" ]]; then
    sre_info "Installing Supervisor..."
    pkg_install supervisor
    svc_enable_start supervisor
    sre_success "Supervisor installed and running"
fi

# --- Locale Setup (Arabic + English UTF-8) ---
sre_header "Locale Configuration"

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
    sre_success "Locales configured: en_US.UTF-8, ar_SA.UTF-8"
else
    sre_info "[DRY-RUN] Would configure en_US.UTF-8 and ar_SA.UTF-8 locales"
fi

config_set "SRE_LOCALE_CONFIGURED" "true"

# --- Swap Configuration ---
sre_header "Swap Configuration"

if [[ "$SRE_RAM_MB" -lt 2048 ]]; then
    if ! swapon --show | grep -q '/'; then
        sre_info "RAM < 2GB and no swap detected. Configuring 2GB swap..."
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            sre_success "2GB swap configured"
        else
            sre_info "[DRY-RUN] Would create 2GB swap at /swapfile"
        fi
    else
        sre_skipped "Swap already configured"
    fi
else
    sre_skipped "RAM >= 2GB, swap configuration skipped"
fi

# --- Fix /tmp Permissions ---
sre_header "Temp Directory Permissions"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    # Ensure /tmp has correct permissions (1777 sticky bit)
    # Prevents Moodle invaliddatarootpermissions and other apps failing to write temp files
    chmod 1777 /tmp
    chown root:root /tmp
    sre_success "/tmp permissions set to 1777 (sticky bit)"
else
    sre_info "[DRY-RUN] Would set /tmp permissions to 1777"
fi

# --- SSH Hardening (Optional) ---
sre_header "SSH Hardening"

if prompt_yesno "Harden SSH? (disable root password login, enforce key auth)" "yes"; then
    sshd_config="/etc/ssh/sshd_config"
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        backup_config "$sshd_config"
        # Disable root password login
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_config"
        svc_restart sshd
        sre_success "SSH hardened: root password login disabled, key auth enforced"
    else
        sre_info "[DRY-RUN] Would harden SSH configuration"
    fi
    config_set "SRE_SSH_HARDENED" "true"
else
    sre_skipped "SSH hardening skipped"
    config_set "SRE_SSH_HARDENED" "false"
fi

# --- Set timezone ---
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    timedatectl set-timezone UTC 2>/dev/null || true
    sre_info "Timezone set to UTC"
fi

config_set "SRE_BASE_SETUP_DONE" "true"

sre_success "Base setup complete!"
sre_info "Config saved to: $SRE_CONFIG_FILE"

recommend_next_step "$CURRENT_STEP"
