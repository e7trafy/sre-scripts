#!/bin/bash
################################################################################
# SRE Helpers - Step 2: Firewall Configuration
# Configures ufw (Debian) or firewalld (RHEL) with standard ports.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=2

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 2: Firewall Configuration
  Configures ufw (Debian) or firewalld (RHEL) to allow ports 22, 80, 443.
  Optionally opens additional ports.

Prerequisites: Step 1 (base-setup) must be complete.

Options:
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes
EOF
}

sre_parse_args "02-firewall.sh" "$@"
require_root

sre_header "Step 2: Firewall Configuration"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

require_config_key "SRE_OS_FAMILY" "1" > /dev/null

sre_info "OS family: $(config_get SRE_OS_FAMILY)"

# --- Ask for additional ports ---
extra_ports=$(prompt_input "Additional ports to open (comma-separated, or leave empty)" "")

# --- Configure Firewall ---
case "$(config_get SRE_OS_FAMILY)" in
    debian)
        sre_info "Configuring ufw..."
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            pkg_is_installed ufw || pkg_install ufw
            ufw --force reset >/dev/null 2>&1
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow 22/tcp comment "SSH"
            ufw allow 80/tcp comment "HTTP"
            ufw allow 443/tcp comment "HTTPS"

            if [[ -n "$extra_ports" ]]; then
                IFS=',' read -ra ports <<< "$extra_ports"
                for port in "${ports[@]}"; do
                    port=$(echo "$port" | tr -d ' ')
                    ufw allow "$port" comment "Custom"
                    sre_info "Opened port: $port"
                done
            fi

            ufw --force enable
            sre_success "ufw configured and enabled"
        else
            sre_info "[DRY-RUN] Would configure ufw: allow 22, 80, 443${extra_ports:+, $extra_ports}"
        fi
        ;;
    rhel)
        sre_info "Configuring firewalld..."
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            pkg_is_installed firewalld || pkg_install firewalld
            svc_enable_start firewalld
            firewall-cmd --permanent --add-service=ssh
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https

            if [[ -n "$extra_ports" ]]; then
                IFS=',' read -ra ports <<< "$extra_ports"
                for port in "${ports[@]}"; do
                    port=$(echo "$port" | tr -d ' ')
                    firewall-cmd --permanent --add-port="${port}/tcp"
                    sre_info "Opened port: $port"
                done
            fi

            firewall-cmd --reload
            sre_success "firewalld configured and enabled"
        else
            sre_info "[DRY-RUN] Would configure firewalld: allow ssh, http, https${extra_ports:+, $extra_ports}"
        fi
        ;;
esac

config_set "SRE_FIREWALL_DONE" "true"

sre_success "Firewall configuration complete!"

recommend_next_step "$CURRENT_STEP"
