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
php_version=$(prompt_choice "Select PHP version:" "8.3" "8.2")
config_set "SRE_PHP_VERSION" "$php_version"
sre_info "Selected PHP version: $php_version"

# --- Database Engine ---
db_engine=$(prompt_choice "Select database engine:" "mariadb" "mysql" "postgresql" "none")
config_set "SRE_DB_ENGINE" "$db_engine"
sre_info "Selected database: $db_engine"

# --- Node.js ---
if prompt_yesno "Install Node.js?" "yes"; then
    node_version=$(prompt_choice "Select Node.js version:" "20" "22")
    config_set "SRE_NODE_VERSION" "$node_version"
    sre_info "Selected Node.js version: $node_version"
else
    config_set "SRE_NODE_VERSION" ""
    sre_info "Node.js: skipped"
fi

# --- Install Essential Packages ---
sre_header "Installing Essential Packages"

pkg_update

case "$SRE_OS_FAMILY" in
    debian)
        pkg_install curl wget git unzip software-properties-common \
            apt-transport-https ca-certificates gnupg lsb-release
        ;;
    rhel)
        pkg_install curl wget git unzip epel-release \
            ca-certificates gnupg2
        ;;
esac
sre_success "Essential packages installed"

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
