#!/bin/bash
################################################################################
# SRE Helpers - Step 6: Node.js & Composer Installation
# Installs Node.js via NodeSource (if selected), PM2, and Composer.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=6

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 6: Node.js & Composer Installation
  Installs Node.js via NodeSource (if configured in step 1), PM2 globally,
  and Composer for PHP dependency management.

Prerequisites: Step 1 (base-setup) must be complete.

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

sre_parse_args "06-node.sh" "$@"
require_root

sre_header "Step 6: Node.js & Composer Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

require_config_key "SRE_OS_FAMILY" "1" > /dev/null

SRE_NODE_VERSION=$(config_get "SRE_NODE_VERSION" "")

# --- Node.js Installation ---
if [[ -z "$SRE_NODE_VERSION" ]]; then
    sre_skipped "Node.js installation skipped (not selected in step 1)"
else
    sre_info "Installing Node.js ${SRE_NODE_VERSION}.x..."

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$(config_get SRE_OS_FAMILY)" in
            debian)
                curl -fsSL "https://deb.nodesource.com/setup_${SRE_NODE_VERSION}.x" | bash -
                pkg_install nodejs
                ;;
            rhel)
                curl -fsSL "https://rpm.nodesource.com/setup_${SRE_NODE_VERSION}.x" | bash -
                pkg_install nodejs
                ;;
        esac
        sre_success "Node.js $(node --version 2>/dev/null || echo "${SRE_NODE_VERSION}.x") installed"
    else
        sre_info "[DRY-RUN] Would install Node.js ${SRE_NODE_VERSION}.x via NodeSource"
    fi

    # --- PM2 ---
    sre_info "Installing PM2 globally..."
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        npm install -g pm2
        sre_success "PM2 $(pm2 --version 2>/dev/null || echo 'latest') installed"
    else
        sre_info "[DRY-RUN] Would install PM2 globally via npm"
    fi

    config_set "SRE_NODE_INSTALLED" "true"
fi

# --- Composer Installation (always) ---
sre_header "Composer Installation"

if command -v composer &>/dev/null; then
    sre_skipped "Composer already installed: $(composer --version 2>/dev/null | head -1)"
else
    sre_info "Installing Composer..."
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
        chmod +x /usr/local/bin/composer
        sre_success "Composer $(composer --version 2>/dev/null | head -1) installed"
    else
        sre_info "[DRY-RUN] Would install Composer to /usr/local/bin/composer"
    fi
fi

config_set "SRE_COMPOSER_INSTALLED" "true"

sre_success "Node.js & Composer installation complete!"

recommend_next_step "$CURRENT_STEP"
