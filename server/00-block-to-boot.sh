#!/bin/bash
################################################################################
# SRE Helpers - Step 00b: Migrate Block Storage Back to Boot Disk
#
# Reverses what 00-block-volume.sh set up. Moves data from block volumes
# back to the boot/root disk so block volumes can be detached or replaced.
#
# Handles:
#   triple mode:
#     - Move MariaDB datadir from /u02/mysql  → /var/lib/mysql
#     - Move app data from /u02/appdata → /var/www
#     - Migrate /var from block volume back to root disk
#     - Unmount all three volumes, remove fstab entries
#   dual_appdata mode:
#     - Move MariaDB datadir from /u02/mysql  → /var/lib/mysql
#     - Move app data   from /u02/appdata → /var/www (moodledata) or original paths
#     - Update MariaDB config, fix AppArmor, verify MariaDB starts
#     - Unmount /u02/mysql and /u02/appdata, remove fstab entries
#   dual_var mode:
#     - Move MariaDB datadir from /u02/mysql → /var/lib/mysql
#     - Migrate /var from block volume back to root disk
#     - Unmount both volumes, remove fstab entries
#   single (/var) mode:
#     - Migrate /var contents back to root disk
#     - Unmount block /var, remove fstab entry
#
# Safety:
#   - Refuses to proceed if not enough space on boot disk
#   - Idempotent: state file tracks phases, safe to re-run after interruption
#   - Never removes data from block volume until boot disk copy is verified
#   - Stops/starts services safely
#   - Validates all services after migration
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=0

################################################################################
# Constants
################################################################################

STATE_FILE="/etc/sre-helpers/block-to-boot.state"
BV_STATE_FILE="/etc/sre-helpers/block-volume.state"
LOG_FILE="/var/log/sre-helpers/block-to-boot.log"
U02_MYSQL="/u02/mysql"
U02_APPDATA="/u02/appdata"
MARIADB_DATADIR_DEFAULT="/var/lib/mysql"

################################################################################
# Logging
################################################################################

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

################################################################################
# State helpers
################################################################################

state_get() {
    local key="$1" file="${2:-$STATE_FILE}"
    [[ -f "$file" ]] || return 0
    grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2- || true
}

state_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] && sed -i "/^${key}=/d" "$STATE_FILE"
    echo "${key}=${val}" >> "$STATE_FILE"
    _log "STATE" "${key}=${val}"
}

phase_done() { [[ "$(state_get "PHASE_${1}")" == "done" ]]; }
mark_done()  { state_set "PHASE_${1}" "done"; }

################################################################################
# Help
################################################################################

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 00b: Migrate Block Storage Back to Boot Disk

  Reverses 00-block-volume.sh. Moves all data from block volumes back to
  the boot disk so volumes can safely be detached or replaced.

  Reads previous setup from: $BV_STATE_FILE

  Modes:
    triple       - Unmount /u02/mysql + /u02/appdata + block /var, restore all to boot disk
    dual_appdata - Unmount /u02/mysql + /u02/appdata, restore MariaDB to /var/lib/mysql
    dual_var     - Unmount /u02/mysql + block /var, restore both to boot disk
    single       - Unmount block /var, restore to root disk /var

Options:
  --mode <triple|dual_appdata|dual_var|single>   Force mode (auto-detected from state file if omitted)
  --dry-run              Show planned actions without making changes
  --yes                  Accept defaults without prompting
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --dry-run
  sudo bash $0 --mode dual_appdata
EOF
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "00-block-to-boot.sh" "${_raw_args[@]}"

FORCE_MODE=""
_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --mode) ((_i++)); FORCE_MODE="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 00b: Migrate Block Storage Back to Boot Disk"
_log "INFO" "Script started. dry_run=${SRE_DRY_RUN}"

################################################################################
# Detect OS + service names
################################################################################

detect_os

MARIADB_SVC="mariadb"
if ! systemctl list-unit-files "${MARIADB_SVC}.service" &>/dev/null; then
    MARIADB_SVC="mysql"
fi

################################################################################
# Detect scenario from previous state file or argument
################################################################################

sre_header "Detecting Previous Configuration"

SCENARIO=""
if [[ -n "$FORCE_MODE" ]]; then
    SCENARIO="$FORCE_MODE"
    sre_info "Mode forced: $SCENARIO"
elif [[ -f "$BV_STATE_FILE" ]]; then
    SCENARIO=$(state_get "SCENARIO" "$BV_STATE_FILE")
    sre_info "Detected previous scenario from state file: $SCENARIO"
fi

if [[ -z "$SCENARIO" ]]; then
    # Auto-detect from what is currently mounted
    _var_on_block=false
    if findmnt -n /var &>/dev/null; then
        var_src=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
        root_disk=$(lsblk -nd --output PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || echo "sda")
        if echo "$var_src" | grep -qv "$root_disk"; then
            _var_on_block=true
        fi
    fi

    _has_db=$(findmnt -n "$U02_MYSQL" &>/dev/null && echo true || echo false)
    _has_app=$(findmnt -n "$U02_APPDATA" &>/dev/null && echo true || echo false)

    if [[ "$_has_db" == "true" && "$_has_app" == "true" && "$_var_on_block" == "true" ]]; then
        SCENARIO="triple"
        sre_info "Auto-detected: triple (/u02/mysql + /u02/appdata + /var on block)"
    elif [[ "$_has_db" == "true" && "$_has_app" == "true" ]]; then
        SCENARIO="dual_appdata"
        sre_info "Auto-detected: dual_appdata (/u02/mysql + /u02/appdata mounted)"
    elif [[ "$_has_db" == "true" && "$_var_on_block" == "true" ]]; then
        SCENARIO="dual_var"
        sre_info "Auto-detected: dual_var (/u02/mysql mounted + /var on block volume)"
    elif [[ "$_var_on_block" == "true" ]]; then
        SCENARIO="single"
        sre_info "Auto-detected: single (/var is on a block volume)"
    fi
fi

if [[ -z "$SCENARIO" ]]; then
    sre_error "Cannot determine scenario. No block volume state found and nothing extra is mounted."
    sre_error "Nothing to migrate back."
    exit 1
fi

case "$SCENARIO" in
    triple|dual_appdata|dual_var|single) ;;
    *) sre_error "Invalid scenario: $SCENARIO (must be: triple, dual_appdata, dual_var, or single)"; exit 1 ;;
esac

################################################################################
# Helpers
################################################################################

check_space() {
    local src="$1"
    local dst="$2"
    local label="$3"

    local src_used_kb dst_avail_kb
    src_used_kb=$(du -sk "$src" 2>/dev/null | awk '{print $1}' || echo 0)
    dst_avail_kb=$(df -k "$dst" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)

    local src_gb=$(( src_used_kb / 1024 / 1024 ))
    local dst_gb=$(( dst_avail_kb / 1024 / 1024 ))

    sre_info "  $label: needs ~${src_gb}GB, boot disk has ~${dst_gb}GB available"

    if (( src_used_kb >= dst_avail_kb )); then
        sre_error "Not enough space on boot disk to migrate $label."
        sre_error "  Required:  ~${src_gb}GB"
        sre_error "  Available: ~${dst_gb}GB"
        sre_error "Free up space on the boot disk before continuing."
        return 1
    fi
    return 0
}

remove_fstab_entry() {
    local mountpoint="$1"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would remove fstab entry for $mountpoint"
        return 0
    fi

    local uuid
    uuid=$(findmnt -n -o UUID "$mountpoint" 2>/dev/null || true)

    if [[ -n "$uuid" ]] && grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
        cp /etc/fstab "/etc/fstab.pre-revert.$(date +%Y%m%d%H%M%S)"
        sed -i "/UUID=${uuid}/d" /etc/fstab
        # Remove the comment line above it if it matches our marker
        sed -i '/# sre-helpers step 00/d' /etc/fstab
        sre_success "Removed fstab entry for $mountpoint (UUID=${uuid})"
    else
        sre_info "No fstab entry found for $mountpoint — skipping"
    fi
}

safe_unmount() {
    local mountpoint="$1"
    if ! findmnt -n "$mountpoint" &>/dev/null; then
        sre_skipped "$mountpoint not mounted"
        return 0
    fi
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount $mountpoint"
        return 0
    fi
    umount "$mountpoint" && sre_success "Unmounted: $mountpoint" || {
        sre_error "Failed to unmount $mountpoint"
        sre_error "Check for open files: lsof +D $mountpoint"
        exit 1
    }
}

################################################################################
# SCENARIO: TRIPLE — migrate /u02/mysql + /u02/appdata + block /var back
################################################################################

migrate_triple() {
    ############################################################################
    # Pre-flight checks
    ############################################################################

    sre_header "Pre-flight: Space Check"

    local space_ok=true

    if findmnt -n "$U02_MYSQL" &>/dev/null; then
        check_space "$U02_MYSQL" "/" "MariaDB datadir (→ /var/lib/mysql)" || space_ok=false
    fi
    if findmnt -n "$U02_APPDATA" &>/dev/null; then
        check_space "$U02_APPDATA" "/" "App data (→ /var/www)" || space_ok=false
    fi
    check_space /var / "/var (→ root disk)" || space_ok=false

    [[ "$space_ok" == "false" ]] && exit 1

    echo ""
    sre_warning "This will:"
    sre_warning "  1. Stop MariaDB and all services"
    sre_warning "  2. Copy /u02/mysql → /var/lib/mysql"
    sre_warning "  3. Copy /u02/appdata → /var/www"
    sre_warning "  4. Copy /var to temp dir on root disk"
    sre_warning "  5. Unmount all three block volumes"
    sre_warning "  6. Restore /var on root disk, restart services"
    sre_warning "  7. Remove fstab entries"
    echo ""
    sre_warning "Block volumes will NOT be formatted — data remains until you detach."
    echo ""

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! prompt_yesno "Proceed with migration back to boot disk?" "no"; then
            sre_info "Aborted by user."
            exit 0
        fi
    fi

    ############################################################################
    # Phase 1: Restore MariaDB datadir
    ############################################################################

    sre_header "Phase 1: Restore MariaDB Datadir → ${MARIADB_DATADIR_DEFAULT}"

    if phase_done "MARIADB_RESTORED"; then
        sre_skipped "MariaDB already restored to boot disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop MariaDB, rsync ${U02_MYSQL} → ${MARIADB_DATADIR_DEFAULT}, update config"
    else
        if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
            sre_info "Stopping MariaDB..."
            systemctl stop "$MARIADB_SVC"
            sre_success "MariaDB stopped"
        fi

        sre_info "Copying ${U02_MYSQL}/ → ${MARIADB_DATADIR_DEFAULT}/ ..."
        mkdir -p "$MARIADB_DATADIR_DEFAULT"
        rsync -aHAX --numeric-ids --delete --info=progress2 \
            "${U02_MYSQL}/" "${MARIADB_DATADIR_DEFAULT}/"
        sre_success "MariaDB data copied back"

        chown -R mysql:mysql "$MARIADB_DATADIR_DEFAULT"
        chmod 750 "$MARIADB_DATADIR_DEFAULT"

        local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        for conf_path in \
            "/etc/mysql/mariadb.conf.d/50-server.cnf" \
            "/etc/mysql/mysql.conf.d/mysqld.cnf" \
            "/etc/my.cnf.d/mariadb-server.cnf" \
            "/etc/my.cnf"; do
            if [[ -f "$conf_path" ]]; then
                mariadb_conf="$conf_path"
                break
            fi
        done

        cp "$mariadb_conf" "${mariadb_conf}.pre-revert.$(date +%Y%m%d%H%M%S)"
        if grep -q "^datadir" "$mariadb_conf"; then
            sed -i "s|^datadir.*|datadir = ${MARIADB_DATADIR_DEFAULT}|" "$mariadb_conf"
        else
            sed -i "/^\[mysqld\]/a datadir = ${MARIADB_DATADIR_DEFAULT}" "$mariadb_conf"
        fi
        sre_success "MariaDB config restored: datadir = ${MARIADB_DATADIR_DEFAULT}"

        if [[ "$SRE_OS_FAMILY" == "debian" ]] && command -v aa-status &>/dev/null; then
            local apparmor_local="/etc/apparmor.d/local/usr.sbin.mysqld"
            if [[ -f "$apparmor_local" ]]; then
                sed -i '/# sre-helpers step 00/,+2d' "$apparmor_local"
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
                    && sre_success "AppArmor profile reloaded" \
                    || sre_warning "AppArmor reload failed — may need manual fix"
            fi
        fi

        for f in /etc/mysql/mariadb.conf.d/99-sre-datadir.cnf \
                 /etc/mysql/mysql.conf.d/99-sre-datadir.cnf \
                 /etc/my.cnf.d/99-sre-datadir.cnf; do
            [[ -f "$f" ]] && { rm -f "$f"; sre_success "Removed datadir override: $f"; }
        done

        mark_done "MARIADB_RESTORED"
    fi

    ############################################################################
    # Phase 2: Restore app data
    ############################################################################

    sre_header "Phase 2: Restore App Data → /var/www"

    if phase_done "APPDATA_RESTORED"; then
        sre_skipped "App data already restored"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync ${U02_APPDATA}/ → /var/www/"
    else
        if findmnt -n "$U02_APPDATA" &>/dev/null; then
            mkdir -p /var/www
            sre_info "Copying ${U02_APPDATA}/ → /var/www/ ..."
            rsync -aHAX --numeric-ids --info=progress2 \
                "${U02_APPDATA}/" "/var/www/"
            sre_success "App data copied to /var/www"
            chown -R www-data:www-data /var/www
            sre_success "Ownership: www-data:www-data on /var/www"
        else
            sre_info "$U02_APPDATA not mounted — skipping app data copy"
        fi
        mark_done "APPDATA_RESTORED"
    fi

    ############################################################################
    # Phase 3: Stop all services for /var migration
    ############################################################################

    sre_header "Phase 3: Stop Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop all services"
    else
        for svc in "$MARIADB_SVC" php8.3-fpm php8.2-fpm php8.1-fpm nginx apache2 httpd; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc"
                sre_success "Stopped: $svc"
                state_set "WAS_RUNNING_${svc}" "yes"
            fi
        done
    fi

    ############################################################################
    # Phase 4: Unmount /u02/mysql and /u02/appdata
    ############################################################################

    sre_header "Phase 4: Unmount DB + Appdata Volumes"

    if phase_done "U02_UNMOUNTED"; then
        sre_skipped "/u02 volumes already unmounted"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount $U02_MYSQL and $U02_APPDATA"
    else
        remove_fstab_entry "$U02_MYSQL"
        remove_fstab_entry "$U02_APPDATA"
        safe_unmount "$U02_MYSQL"
        safe_unmount "$U02_APPDATA"

        for mp in "$U02_MYSQL" "$U02_APPDATA" "/u02"; do
            if [[ -d "$mp" ]] && [[ -z "$(ls -A "$mp" 2>/dev/null)" ]]; then
                rmdir "$mp"
                sre_success "Removed empty dir: $mp"
            fi
        done

        mark_done "U02_UNMOUNTED"
    fi

    ############################################################################
    # Phase 5: Copy /var to temp on root disk
    ############################################################################

    sre_header "Phase 5: Copy /var to Root Disk"

    local tmp_var="/var.boot.$$"

    if phase_done "VAR_COPIED"; then
        tmp_var=$(state_get "TMP_VAR_PATH")
        sre_info "Using previously copied temp dir: $tmp_var"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync /var → ${tmp_var} on root disk"
    else
        mkdir -p "$tmp_var"
        state_set "TMP_VAR_PATH" "$tmp_var"
        sre_info "Copying /var → $tmp_var ..."
        rsync -aHAXx --numeric-ids --info=progress2 /var/ "$tmp_var/"
        sre_success "Copy complete"
        mark_done "VAR_COPIED"
    fi

    ############################################################################
    # Phase 6: Unmount block /var
    ############################################################################

    sre_header "Phase 6: Unmount Block Volume from /var"

    if phase_done "VAR_UNMOUNTED"; then
        sre_skipped "/var already unmounted"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount block /var"
    else
        remove_fstab_entry /var
        sre_info "Unmounting block volume from /var..."
        umount /var && sre_success "Unmounted block /var" || {
            sre_error "Failed to unmount /var"
            sre_error "Your data copy is safe at: $tmp_var"
            exit 1
        }
        mark_done "VAR_UNMOUNTED"
    fi

    ############################################################################
    # Phase 7: Restore /var on root disk
    ############################################################################

    sre_header "Phase 7: Restore /var on Root Disk"

    if phase_done "VAR_RESTORED"; then
        sre_skipped "/var already restored on root disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync $tmp_var → /var on root disk"
    else
        tmp_var=$(state_get "TMP_VAR_PATH")
        if [[ -z "$tmp_var" || ! -d "$tmp_var" ]]; then
            sre_error "Temp dir not found. Re-run from phase 5."
            exit 1
        fi
        sre_info "Restoring ${tmp_var} → /var ..."
        rsync -aHAXx --numeric-ids --delete --info=progress2 "$tmp_var/" /var/
        sre_success "/var restored on root disk"
        rm -rf "$tmp_var"
        sre_success "Temp dir removed: $tmp_var"
        mark_done "VAR_RESTORED"
    fi

    ############################################################################
    # Phase 8: Restart services
    ############################################################################

    sre_header "Phase 8: Restart Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would start MariaDB and restart services"
    else
        sre_info "Starting MariaDB..."
        systemctl start "$MARIADB_SVC"
        sleep 3
        if systemctl is-active --quiet "$MARIADB_SVC"; then
            sre_success "MariaDB started successfully"
            actual_datadir=$(mysql -NBe "SELECT @@datadir;" 2>/dev/null || true)
            [[ -n "$actual_datadir" ]] && sre_info "Confirmed datadir: $actual_datadir"
        else
            sre_error "MariaDB failed to start. Check: journalctl -u ${MARIADB_SVC} -n 50"
            exit 1
        fi

        for svc in nginx apache2 httpd php8.3-fpm php8.2-fpm php8.1-fpm; do
            if [[ "$(state_get "WAS_RUNNING_${svc}")" == "yes" ]]; then
                systemctl start "$svc" 2>/dev/null \
                    && sre_success "Started: $svc" \
                    || sre_warning "Failed to start $svc — check: journalctl -u $svc -n 30"
            fi
        done
    fi
}

################################################################################
# SCENARIO: DUAL_APPDATA — migrate /u02/mysql + /u02/appdata back
################################################################################

migrate_dual_appdata() {
    ############################################################################
    # Pre-flight checks
    ############################################################################

    sre_header "Pre-flight: Space Check"

    local space_ok=true

    if findmnt -n "$U02_MYSQL" &>/dev/null; then
        check_space "$U02_MYSQL" "/" "MariaDB datadir (→ /var/lib/mysql)" || space_ok=false
    fi
    if findmnt -n "$U02_APPDATA" &>/dev/null; then
        check_space "$U02_APPDATA" "/" "App data (→ /var/www)" || space_ok=false
    fi

    [[ "$space_ok" == "false" ]] && exit 1

    echo ""
    sre_warning "This will:"
    sre_warning "  1. Stop MariaDB"
    sre_warning "  2. Copy /u02/mysql → /var/lib/mysql"
    sre_warning "  3. Copy /u02/appdata → /var/www (moodledata + laravel-storage)"
    sre_warning "  4. Update MariaDB config back to default datadir"
    sre_warning "  5. Restart MariaDB and verify"
    sre_warning "  6. Unmount /u02/mysql and /u02/appdata"
    sre_warning "  7. Remove fstab entries"
    echo ""
    sre_warning "Block volumes will NOT be formatted — data remains on them until you detach."
    echo ""

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! prompt_yesno "Proceed with migration back to boot disk?" "no"; then
            sre_info "Aborted by user."
            exit 0
        fi
    fi

    ############################################################################
    # Phase 1: Restore MariaDB datadir
    ############################################################################

    sre_header "Phase 1: Restore MariaDB Datadir → ${MARIADB_DATADIR_DEFAULT}"

    if phase_done "MARIADB_RESTORED"; then
        sre_skipped "MariaDB already restored to boot disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop MariaDB, rsync ${U02_MYSQL} → ${MARIADB_DATADIR_DEFAULT}, update config, restart"
    else
        # Stop MariaDB
        if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
            sre_info "Stopping MariaDB..."
            systemctl stop "$MARIADB_SVC"
            sre_success "MariaDB stopped"
        fi

        # Copy data back
        sre_info "Copying ${U02_MYSQL}/ → ${MARIADB_DATADIR_DEFAULT}/ ..."
        mkdir -p "$MARIADB_DATADIR_DEFAULT"
        rsync -aHAX --numeric-ids --delete --info=progress2 \
            "${U02_MYSQL}/" "${MARIADB_DATADIR_DEFAULT}/"
        sre_success "MariaDB data copied back"
        _log "INFO" "mariadb data copied to ${MARIADB_DATADIR_DEFAULT}"

        # Fix ownership
        chown -R mysql:mysql "$MARIADB_DATADIR_DEFAULT"
        chmod 750 "$MARIADB_DATADIR_DEFAULT"
        sre_success "Ownership: mysql:mysql on ${MARIADB_DATADIR_DEFAULT}"

        # Restore MariaDB config
        local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        for conf_path in \
            "/etc/mysql/mariadb.conf.d/50-server.cnf" \
            "/etc/mysql/mysql.conf.d/mysqld.cnf" \
            "/etc/my.cnf.d/mariadb-server.cnf" \
            "/etc/my.cnf"; do
            if [[ -f "$conf_path" ]]; then
                mariadb_conf="$conf_path"
                break
            fi
        done

        sre_info "Restoring datadir in: $mariadb_conf"
        cp "$mariadb_conf" "${mariadb_conf}.pre-revert.$(date +%Y%m%d%H%M%S)"

        if grep -q "^datadir" "$mariadb_conf"; then
            sed -i "s|^datadir.*|datadir = ${MARIADB_DATADIR_DEFAULT}|" "$mariadb_conf"
        else
            sed -i "/^\[mysqld\]/a datadir = ${MARIADB_DATADIR_DEFAULT}" "$mariadb_conf"
        fi
        sre_success "MariaDB config restored: datadir = ${MARIADB_DATADIR_DEFAULT}"

        # Restore AppArmor profile
        if [[ "$SRE_OS_FAMILY" == "debian" ]] && command -v aa-status &>/dev/null; then
            local apparmor_local="/etc/apparmor.d/local/usr.sbin.mysqld"
            if [[ -f "$apparmor_local" ]]; then
                sre_info "Removing custom AppArmor rules for block volume datadir..."
                sed -i '/# sre-helpers step 00/,+2d' "$apparmor_local"
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
                    && sre_success "AppArmor profile reloaded" \
                    || sre_warning "AppArmor reload failed — may need manual fix"
            fi
        fi

        # Start MariaDB and verify
        sre_info "Starting MariaDB..."
        systemctl start "$MARIADB_SVC"
        sleep 3

        if systemctl is-active --quiet "$MARIADB_SVC"; then
            sre_success "MariaDB started successfully"
            actual_datadir=$(mysql -NBe "SELECT @@datadir;" 2>/dev/null || true)
            [[ -n "$actual_datadir" ]] && sre_info "Confirmed datadir: $actual_datadir"
        else
            sre_error "MariaDB failed to start after restore."
            sre_error "Check: journalctl -u ${MARIADB_SVC} -n 50"
            sre_error "The original data on ${U02_MYSQL} is still intact."
            exit 1
        fi

        mark_done "MARIADB_RESTORED"
    fi

    ############################################################################
    # Phase 2: Restore app data
    ############################################################################

    sre_header "Phase 2: Restore App Data → /var/www"

    if phase_done "APPDATA_RESTORED"; then
        sre_skipped "App data already restored"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync ${U02_APPDATA}/ → /var/www/"
    else
        if findmnt -n "$U02_APPDATA" &>/dev/null; then
            mkdir -p /var/www
            sre_info "Copying ${U02_APPDATA}/ → /var/www/ ..."
            rsync -aHAX --numeric-ids --info=progress2 \
                "${U02_APPDATA}/" "/var/www/"
            sre_success "App data copied to /var/www"
            _log "INFO" "appdata copied to /var/www"

            chown -R www-data:www-data /var/www
            sre_success "Ownership: www-data:www-data on /var/www"
        else
            sre_info "$U02_APPDATA not mounted — skipping app data copy"
        fi
        mark_done "APPDATA_RESTORED"
    fi

    ############################################################################
    # Phase 3: Unmount volumes + clean fstab
    ############################################################################

    sre_header "Phase 3: Unmount Block Volumes"

    if phase_done "VOLUMES_UNMOUNTED"; then
        sre_skipped "Volumes already unmounted"
    else
        if [[ "$SRE_DRY_RUN" == "true" ]]; then
            sre_info "[DRY-RUN] Would unmount $U02_MYSQL and $U02_APPDATA and remove fstab entries"
        else
            remove_fstab_entry "$U02_MYSQL"
            remove_fstab_entry "$U02_APPDATA"
            safe_unmount "$U02_MYSQL"
            safe_unmount "$U02_APPDATA"

            # Remove mount dirs (only if empty)
            for mp in "$U02_MYSQL" "$U02_APPDATA" "/u02"; do
                if [[ -d "$mp" ]] && [[ -z "$(ls -A "$mp" 2>/dev/null)" ]]; then
                    rmdir "$mp"
                    sre_success "Removed empty dir: $mp"
                fi
            done

            mark_done "VOLUMES_UNMOUNTED"
        fi
    fi
}

################################################################################
# SCENARIO: DUAL_VAR — migrate /u02/mysql back + restore block /var
################################################################################

migrate_dual_var() {
    ############################################################################
    # Pre-flight checks
    ############################################################################

    sre_header "Pre-flight: Space Check"

    local space_ok=true

    if findmnt -n "$U02_MYSQL" &>/dev/null; then
        check_space "$U02_MYSQL" "/" "MariaDB datadir (→ /var/lib/mysql)" || space_ok=false
    fi
    check_space /var / "/var (→ root disk)" || space_ok=false

    [[ "$space_ok" == "false" ]] && exit 1

    echo ""
    sre_warning "This will:"
    sre_warning "  1. Stop MariaDB and other services"
    sre_warning "  2. Copy /u02/mysql → /var/lib/mysql"
    sre_warning "  3. Update MariaDB config back to default datadir"
    sre_warning "  4. Copy /var to temp dir on root disk"
    sre_warning "  5. Unmount block /var and /u02/mysql"
    sre_warning "  6. Restore /var and restart services"
    sre_warning "  7. Remove fstab entries"
    echo ""
    sre_warning "Block volumes will NOT be formatted — data remains until you detach."
    echo ""

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! prompt_yesno "Proceed with migration back to boot disk?" "no"; then
            sre_info "Aborted by user."
            exit 0
        fi
    fi

    ############################################################################
    # Phase 1: Restore MariaDB datadir (same as dual_appdata)
    ############################################################################

    sre_header "Phase 1: Restore MariaDB Datadir → ${MARIADB_DATADIR_DEFAULT}"

    if phase_done "MARIADB_RESTORED"; then
        sre_skipped "MariaDB already restored to boot disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop MariaDB, rsync ${U02_MYSQL} → ${MARIADB_DATADIR_DEFAULT}, update config, restart"
    else
        if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
            sre_info "Stopping MariaDB..."
            systemctl stop "$MARIADB_SVC"
            sre_success "MariaDB stopped"
        fi

        sre_info "Copying ${U02_MYSQL}/ → ${MARIADB_DATADIR_DEFAULT}/ ..."
        mkdir -p "$MARIADB_DATADIR_DEFAULT"
        rsync -aHAX --numeric-ids --delete --info=progress2 \
            "${U02_MYSQL}/" "${MARIADB_DATADIR_DEFAULT}/"
        sre_success "MariaDB data copied back"

        chown -R mysql:mysql "$MARIADB_DATADIR_DEFAULT"
        chmod 750 "$MARIADB_DATADIR_DEFAULT"
        sre_success "Ownership: mysql:mysql on ${MARIADB_DATADIR_DEFAULT}"

        local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        for conf_path in \
            "/etc/mysql/mariadb.conf.d/50-server.cnf" \
            "/etc/mysql/mysql.conf.d/mysqld.cnf" \
            "/etc/my.cnf.d/mariadb-server.cnf" \
            "/etc/my.cnf"; do
            if [[ -f "$conf_path" ]]; then
                mariadb_conf="$conf_path"
                break
            fi
        done

        cp "$mariadb_conf" "${mariadb_conf}.pre-revert.$(date +%Y%m%d%H%M%S)"
        if grep -q "^datadir" "$mariadb_conf"; then
            sed -i "s|^datadir.*|datadir = ${MARIADB_DATADIR_DEFAULT}|" "$mariadb_conf"
        else
            sed -i "/^\[mysqld\]/a datadir = ${MARIADB_DATADIR_DEFAULT}" "$mariadb_conf"
        fi
        sre_success "MariaDB config restored: datadir = ${MARIADB_DATADIR_DEFAULT}"

        if [[ "$SRE_OS_FAMILY" == "debian" ]] && command -v aa-status &>/dev/null; then
            local apparmor_local="/etc/apparmor.d/local/usr.sbin.mysqld"
            if [[ -f "$apparmor_local" ]]; then
                sed -i '/# sre-helpers step 00/,+2d' "$apparmor_local"
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
                    && sre_success "AppArmor profile reloaded" \
                    || sre_warning "AppArmor reload failed — may need manual fix"
            fi
        fi

        # Remove sre-datadir override
        local override_conf=""
        for f in /etc/mysql/mariadb.conf.d/99-sre-datadir.cnf \
                 /etc/mysql/mysql.conf.d/99-sre-datadir.cnf \
                 /etc/my.cnf.d/99-sre-datadir.cnf; do
            [[ -f "$f" ]] && { rm -f "$f"; sre_success "Removed datadir override: $f"; }
        done

        mark_done "MARIADB_RESTORED"
    fi

    ############################################################################
    # Phase 2: Unmount /u02/mysql
    ############################################################################

    sre_header "Phase 2: Unmount /u02/mysql"

    if phase_done "DB_VOL_UNMOUNTED"; then
        sre_skipped "/u02/mysql already unmounted"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount $U02_MYSQL and remove fstab entry"
    else
        remove_fstab_entry "$U02_MYSQL"
        safe_unmount "$U02_MYSQL"
        for mp in "$U02_MYSQL" "/u02"; do
            if [[ -d "$mp" ]] && [[ -z "$(ls -A "$mp" 2>/dev/null)" ]]; then
                rmdir "$mp"
                sre_success "Removed empty dir: $mp"
            fi
        done
        mark_done "DB_VOL_UNMOUNTED"
    fi

    ############################################################################
    # Phase 3: Stop services for /var migration
    ############################################################################

    sre_header "Phase 3: Stop Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop MariaDB, PHP-FPM, Nginx/Apache"
    else
        for svc in "$MARIADB_SVC" php8.3-fpm php8.2-fpm php8.1-fpm nginx apache2 httpd; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc"
                sre_success "Stopped: $svc"
                state_set "WAS_RUNNING_${svc}" "yes"
            fi
        done
    fi

    ############################################################################
    # Phase 4: Copy /var to temp location on root disk
    ############################################################################

    sre_header "Phase 4: Copy /var to Root Disk"

    local tmp_var="/var.boot.$$"

    if phase_done "VAR_COPIED"; then
        tmp_var=$(state_get "TMP_VAR_PATH")
        sre_info "Using previously copied temp dir: $tmp_var"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync /var → ${tmp_var} on root disk"
    else
        mkdir -p "$tmp_var"
        state_set "TMP_VAR_PATH" "$tmp_var"
        sre_info "Copying /var → $tmp_var ..."
        rsync -aHAXx --numeric-ids --info=progress2 /var/ "$tmp_var/"
        sre_success "Copy complete"
        mark_done "VAR_COPIED"
    fi

    ############################################################################
    # Phase 5: Unmount block /var
    ############################################################################

    sre_header "Phase 5: Unmount Block Volume from /var"

    if phase_done "VAR_UNMOUNTED"; then
        sre_skipped "/var already unmounted"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount block /var"
    else
        remove_fstab_entry /var
        sre_info "Unmounting block volume from /var..."
        umount /var && sre_success "Unmounted block /var" || {
            sre_error "Failed to unmount /var"
            sre_error "Your data copy is safe at: $tmp_var"
            exit 1
        }
        mark_done "VAR_UNMOUNTED"
    fi

    ############################################################################
    # Phase 6: Restore /var on root disk
    ############################################################################

    sre_header "Phase 6: Restore /var on Root Disk"

    if phase_done "VAR_RESTORED"; then
        sre_skipped "/var already restored on root disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync $tmp_var → /var on root disk"
    else
        tmp_var=$(state_get "TMP_VAR_PATH")
        if [[ -z "$tmp_var" || ! -d "$tmp_var" ]]; then
            sre_error "Temp dir not found. Re-run from phase 4."
            exit 1
        fi
        sre_info "Restoring ${tmp_var} → /var ..."
        rsync -aHAXx --numeric-ids --delete --info=progress2 "$tmp_var/" /var/
        sre_success "/var restored on root disk"
        rm -rf "$tmp_var"
        sre_success "Temp dir removed: $tmp_var"
        mark_done "VAR_RESTORED"
    fi

    ############################################################################
    # Phase 7: Start MariaDB with restored datadir + restart services
    ############################################################################

    sre_header "Phase 7: Restart Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would start MariaDB and restart previously running services"
    else
        # Start MariaDB first (now using /var/lib/mysql on boot disk)
        sre_info "Starting MariaDB..."
        systemctl start "$MARIADB_SVC"
        sleep 3
        if systemctl is-active --quiet "$MARIADB_SVC"; then
            sre_success "MariaDB started successfully"
            actual_datadir=$(mysql -NBe "SELECT @@datadir;" 2>/dev/null || true)
            [[ -n "$actual_datadir" ]] && sre_info "Confirmed datadir: $actual_datadir"
        else
            sre_error "MariaDB failed to start. Check: journalctl -u ${MARIADB_SVC} -n 50"
            exit 1
        fi

        for svc in nginx apache2 httpd php8.3-fpm php8.2-fpm php8.1-fpm; do
            if [[ "$(state_get "WAS_RUNNING_${svc}")" == "yes" ]]; then
                systemctl start "$svc" 2>/dev/null \
                    && sre_success "Started: $svc" \
                    || sre_warning "Failed to start $svc — check: journalctl -u $svc -n 30"
            fi
        done
    fi
}

################################################################################
# SCENARIO: SINGLE — migrate block /var back to root disk
################################################################################

migrate_single() {
    ############################################################################
    # Detect block /var
    ############################################################################

    local var_src
    var_src=$(findmnt -n -o SOURCE /var 2>/dev/null || true)

    if [[ -z "$var_src" ]]; then
        sre_error "/var is not separately mounted — nothing to migrate back."
        exit 1
    fi

    local root_disk
    root_disk=$(lsblk -nd --output PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || echo "sda")

    if echo "$var_src" | grep -q "$root_disk"; then
        sre_success "/var is already on the root disk ($var_src). Nothing to do."
        exit 0
    fi

    sre_info "/var is currently on: $var_src"
    local var_size
    var_size=$(du -sh /var 2>/dev/null | cut -f1 || echo "?")
    sre_info "/var current size: $var_size"

    ############################################################################
    # Space check
    ############################################################################

    sre_header "Pre-flight: Space Check"
    check_space /var / "/var (→ root disk)" || exit 1

    echo ""
    sre_warning "This will:"
    sre_warning "  1. Stop all services writing to /var (MariaDB, web server)"
    sre_warning "  2. Copy /var contents to a temp dir on the root disk"
    sre_warning "  3. Unmount the block volume from /var"
    sre_warning "  4. Move temp dir contents to /var on root disk"
    sre_warning "  5. Restart services"
    sre_warning "  6. Remove fstab entry for the block volume"
    echo ""
    sre_warning "Block volume will NOT be formatted — data remains until you detach."
    echo ""

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! prompt_yesno "Proceed?" "no"; then
            sre_info "Aborted by user."
            exit 0
        fi
    fi

    ############################################################################
    # Phase 1: Stop services
    ############################################################################

    sre_header "Phase 1: Stop Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would stop MariaDB, PHP-FPM, Nginx/Apache"
    else
        for svc in "$MARIADB_SVC" php8.3-fpm php8.2-fpm php8.1-fpm nginx apache2 httpd; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc"
                sre_success "Stopped: $svc"
                state_set "WAS_RUNNING_${svc}" "yes"
            fi
        done
    fi

    ############################################################################
    # Phase 2: Copy /var to temp location on root disk
    ############################################################################

    sre_header "Phase 2: Copy /var to Root Disk"

    local tmp_var="/var.boot.$$"

    if phase_done "VAR_COPIED"; then
        tmp_var=$(state_get "TMP_VAR_PATH")
        sre_info "Using previously copied temp dir: $tmp_var"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync /var → ${tmp_var} on root disk"
    else
        mkdir -p "$tmp_var"
        state_set "TMP_VAR_PATH" "$tmp_var"

        sre_info "Copying /var → $tmp_var ..."
        rsync -aHAXx --numeric-ids --info=progress2 /var/ "$tmp_var/"
        sre_success "Copy complete"
        _log "INFO" "var copied to tmp_var=${tmp_var}"
        mark_done "VAR_COPIED"
    fi

    ############################################################################
    # Phase 3: Unmount block /var
    ############################################################################

    sre_header "Phase 3: Unmount Block Volume from /var"

    if phase_done "VAR_UNMOUNTED"; then
        sre_skipped "/var already unmounted"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would unmount block /var"
    else
        remove_fstab_entry /var

        sre_info "Unmounting block volume from /var..."
        umount /var && sre_success "Unmounted block /var" || {
            sre_error "Failed to unmount /var"
            sre_error "Check open files: lsof +D /var"
            sre_error "Your data copy is safe at: $tmp_var"
            exit 1
        }
        mark_done "VAR_UNMOUNTED"
    fi

    ############################################################################
    # Phase 4: Move temp copy into /var on root disk
    ############################################################################

    sre_header "Phase 4: Restore /var on Root Disk"

    if phase_done "VAR_RESTORED"; then
        sre_skipped "/var already restored on root disk"
    elif [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would rsync $tmp_var → /var on root disk"
    else
        tmp_var=$(state_get "TMP_VAR_PATH")
        if [[ -z "$tmp_var" || ! -d "$tmp_var" ]]; then
            sre_error "Temp dir not found. Re-run from phase 2 by deleting state file: $STATE_FILE"
            exit 1
        fi

        sre_info "Restoring ${tmp_var} → /var ..."
        rsync -aHAXx --numeric-ids --delete --info=progress2 "$tmp_var/" /var/
        sre_success "/var restored on root disk"
        _log "INFO" "var restored from tmp=${tmp_var}"

        # Clean up temp dir
        rm -rf "$tmp_var"
        sre_success "Temp dir removed: $tmp_var"

        mark_done "VAR_RESTORED"
    fi

    ############################################################################
    # Phase 5: Restart services
    ############################################################################

    sre_header "Phase 5: Restart Services"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would restart previously running services"
    else
        for svc in "$MARIADB_SVC" nginx apache2 httpd php8.3-fpm php8.2-fpm php8.1-fpm; do
            if [[ "$(state_get "WAS_RUNNING_${svc}")" == "yes" ]]; then
                systemctl start "$svc" 2>/dev/null \
                    && sre_success "Started: $svc" \
                    || sre_warning "Failed to start $svc — check: journalctl -u $svc -n 30"
            fi
        done
    fi
}

################################################################################
# Run scenario
################################################################################

case "$SCENARIO" in
    triple)       migrate_triple       ;;
    dual_appdata) migrate_dual_appdata ;;
    dual_var)     migrate_dual_var     ;;
    single)       migrate_single       ;;
esac

################################################################################
# Validation
################################################################################

sre_header "Validation"

_validate_mariadb_restored() {
    if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
        sre_success "MariaDB is running"
        actual=$(mysql -NBe "SELECT @@datadir;" 2>/dev/null || true)
        if [[ -n "$actual" ]]; then
            sre_info "  datadir: $actual"
            if [[ "$actual" == "${MARIADB_DATADIR_DEFAULT}"* ]]; then
                sre_success "  MariaDB is using the boot disk datadir"
            else
                sre_warning "  datadir is not ${MARIADB_DATADIR_DEFAULT} — check config"
            fi
        fi
    else
        sre_warning "MariaDB is not running — check: journalctl -u ${MARIADB_SVC} -n 50"
    fi
}

_validate_unmounted() {
    local mp="$1"
    if findmnt -n "$mp" &>/dev/null; then
        sre_warning "$mp is still mounted"
    else
        sre_success "$mp is unmounted (OK)"
    fi
}

_validate_var_on_rootdisk() {
    var_src=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
    if [[ -z "$var_src" ]]; then
        sre_success "/var is on root disk (not separately mounted)"
    else
        sre_info "/var source: $var_src"
    fi
    df -h /var
}

case "$SCENARIO" in
    triple)
        _validate_mariadb_restored
        _validate_unmounted "$U02_MYSQL"
        _validate_unmounted "$U02_APPDATA"
        _validate_var_on_rootdisk
        ;;

    dual_appdata)
        _validate_mariadb_restored
        _validate_unmounted "$U02_MYSQL"
        _validate_unmounted "$U02_APPDATA"
        ;;

    dual_var)
        _validate_mariadb_restored
        _validate_unmounted "$U02_MYSQL"
        _validate_var_on_rootdisk
        ;;

    single)
        _validate_var_on_rootdisk
        ;;
esac

################################################################################
# Summary
################################################################################

sre_header "Migration to Boot Disk Complete"

echo ""
case "$SCENARIO" in
    triple)
        sre_success "All block volumes unmounted. Data is now on the boot disk."
        sre_info "  MariaDB datadir: ${MARIADB_DATADIR_DEFAULT}"
        sre_info "  App data:        /var/www"
        sre_info "  /var:            on root disk"
        echo ""
        sre_info "Block volumes can now be safely detached from Oracle Cloud Console:"
        sre_info "  Compute → Instances → your instance → Attached block volumes → Detach"
        ;;
    dual_appdata)
        sre_success "Block volumes unmounted. Data is now on the boot disk."
        sre_info "  MariaDB datadir: ${MARIADB_DATADIR_DEFAULT}"
        sre_info "  App data:        /var/www"
        echo ""
        sre_info "Block volumes can now be safely detached from Oracle Cloud Console:"
        sre_info "  Compute → Instances → your instance → Attached block volumes → Detach"
        ;;
    dual_var)
        sre_success "Block volumes unmounted. Data is now on the boot disk."
        sre_info "  MariaDB datadir: ${MARIADB_DATADIR_DEFAULT}"
        sre_info "  /var:            on root disk"
        echo ""
        sre_info "Block volumes can now be safely detached from Oracle Cloud Console:"
        sre_info "  Compute → Instances → your instance → Attached block volumes → Detach"
        ;;
    single)
        sre_success "Block volume unmounted. /var is now on the boot disk."
        echo ""
        sre_info "Block volume can now be safely detached from Oracle Cloud Console:"
        sre_info "  Compute → Instances → your instance → Attached block volumes → Detach"
        ;;
esac

echo ""
sre_info "State file: $STATE_FILE"
sre_info "Log file:   $LOG_FILE"
echo ""

recommend_next_step "$CURRENT_STEP"
