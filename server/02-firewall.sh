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
  Configures ufw (Debian) or firewalld (RHEL) to allow the detected SSH
  port plus 80 and 443.
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

            # Do NOT reset on every run: that wipes rules added by other steps
            # or by hand, which breaks idempotency (constitution IV). ufw allow
            # is already idempotent, so a reset is only useful on a first run.
            if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
                ufw --force reset >/dev/null 2>&1
            else
                sre_info "ufw already active — adding rules without resetting"
            fi

            ufw default deny incoming
            ufw default allow outgoing

            # Open the port sshd ACTUALLY listens on. Hardcoding 22 locks you
            # out of any host running ssh elsewhere. Read it from the effective
            # sshd config, not from `ss`: on socket-activated Ubuntu 24.04 the
            # listener shows up as systemd, not sshd.
            ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
            [[ -n "$ssh_port" ]] || ssh_port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
            [[ -n "$ssh_port" ]] || ssh_port="22"
            ufw allow "${ssh_port}/tcp" comment "SSH"
            [[ "$ssh_port" != "22" ]] && sre_info "Opened detected SSH port: $ssh_port"
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
            # --add-service=ssh only covers port 22; add the real port too.
            firewall-cmd --permanent --add-service=ssh
            ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
            [[ -n "$ssh_port" ]] || ssh_port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
            if [[ -n "$ssh_port" && "$ssh_port" != "22" ]]; then
                firewall-cmd --permanent --add-port="${ssh_port}/tcp"
                sre_info "Opened detected SSH port: $ssh_port"
            fi
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
