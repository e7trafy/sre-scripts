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
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        # Refuse to turn off password auth unless a usable key is already
        # installed, or this run locks the operator out of the box. This
        # defaults to "yes", so under --yes it applied unattended.
        #
        # Check the invoking user's keys, not root's: cloud-init's
        # disable_root installs a forced-command "Please login as..." key in
        # root's authorized_keys, so a bare non-empty test on root passes
        # while no usable login key exists.
        _ssh_key_user="${SUDO_USER:-root}"
        _ssh_key_home=$(getent passwd "$_ssh_key_user" 2>/dev/null | cut -d: -f6 || true)
        [[ -n "$_ssh_key_home" ]] || _ssh_key_home="/root"
        _have_key="false"
        for _ak in "${_ssh_key_home}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
            [[ -f "$_ak" ]] || continue
            # A real key line, ignoring comments, blanks, and the cloud-init
            # forced-command placeholder.
            if grep -qE '^[^#].*ssh-(rsa|ed25519|dss)|^[^#].*ecdsa-sha2' "$_ak" 2>/dev/null \
               && ! grep -q 'Please login as' "$_ak" 2>/dev/null; then
                _have_key="true"
                break
            fi
        done

        if [[ "$_have_key" != "true" ]]; then
            sre_warning "No usable SSH public key found for '${_ssh_key_user}' or root."
            sre_warning "Disabling password authentication now would lock you out."
            sre_skipped "SSH hardening skipped — add a key (step 9), then re-run."
        else
            # Write a drop-in rather than sed-ing sshd_config. Ubuntu's
            # sshd_config starts with `Include sshd_config.d/*.conf` and sshd
            # keeps the FIRST value it reads, so edits to the main file can be
            # silently overridden by a cloud-init drop-in while this reports
            # success. A 00- prefix sorts ahead of the vendor drop-ins.
            sshd_dropin_dir="/etc/ssh/sshd_config.d"
            sshd_config="/etc/ssh/sshd_config"
            if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$sshd_config" 2>/dev/null \
               && [[ -d "$sshd_dropin_dir" ]]; then
                sshd_target="${sshd_dropin_dir}/00-sre-hardening.conf"
                # Remember whether we created this file, so a revert removes
                # only our own drop-in and never an administrator's.
                sshd_target_was_new="false"
                [[ -f "$sshd_target" ]] || sshd_target_was_new="true"
                backup_config "$sshd_target"
                sshd_backup="${SRE_LAST_BACKUP:-}"
                cat > "$sshd_target" <<'SSHD'
# Managed by sre-helpers (step 1). Remove this file to revert.
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
SSHD
                chmod 644 "$sshd_target"
            else
                # No Include support (older sshd): fall back to editing in place.
                sshd_target="$sshd_config"
                sshd_target_was_new="false"
                backup_config "$sshd_config"
                sshd_backup="${SRE_LAST_BACKUP:-}"
                sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
                sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_config"
            fi

            # Revert safely. Never `rm -f` the target blindly: on the
            # in-place path that is /etc/ssh/sshd_config itself, and deleting
            # it would leave the host with no sshd config at all.
            _sshd_revert() {
                if [[ -n "${sshd_backup:-}" ]]; then
                    restore_config "$sshd_target" "$sshd_backup" || \
                        sre_error "Could not restore $sshd_target - check it by hand."
                elif [[ "${sshd_target_was_new:-false}" == "true" ]]; then
                    # Our own drop-in, which did not exist before this run.
                    rm -f "$sshd_target"
                    sre_info "Removed $sshd_target"
                else
                    sre_error "No backup for $sshd_target and it is not ours - leaving as is."
                fi
            }

            # Validate syntax, then confirm the EFFECTIVE config, since a
            # drop-in elsewhere can still win. `sshd -t` only checks syntax.
            if ! sshd -t 2>/dev/null; then
                sre_error "sshd config test failed — reverting, not restarting."
                sshd -t 2>&1 | sed 's/^/    /' >&2 || true
                _sshd_revert
                sre_skipped "SSH hardening reverted."
            elif ! sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
                sre_error "Another sshd drop-in still enables password auth."
                sre_error "Check: sshd -T | grep -Ei 'passwordauthentication|permitrootlogin'"
                _sshd_revert
                sre_skipped "SSH hardening reverted (would not have taken effect)."
            else
                svc_restart sshd
                sre_success "SSH hardened via ${sshd_target}"
                sre_info "Keep this session open and verify a NEW login before closing it."
            fi
        fi
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
