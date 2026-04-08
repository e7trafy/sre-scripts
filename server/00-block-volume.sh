#!/bin/bash
################################################################################
# SRE Helpers - Step 00: Oracle Block Volume Setup
# Optional pre-step. Detects attached block volumes and mounts them.
#
# Scenarios:
#   2 volumes found:
#     - Smaller  → /u02/mysql    (MariaDB datadir)
#     - Larger   → /u02/appdata  (moodledata, Laravel storage)
#   1 volume found:
#     - Migrates existing /var → volume, mounts as /var
#
# Features:
#   - Never touches root/boot disk
#   - GPT + single ext4 partition per volume
#   - UUID-based /etc/fstab entries
#   - Idempotent: state file tracks completed phases, safe to re-run
#   - Stops/starts MariaDB safely when moving datadir
#   - Handles AppArmor on Debian/Ubuntu
#   - Validates mounts and services after each phase
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=0

################################################################################
# Constants
################################################################################

STATE_FILE="/etc/sre-helpers/block-volume.state"
LOG_FILE="/var/log/sre-helpers/block-volume.log"
U02_MYSQL="/u02/mysql"
U02_APPDATA="/u02/appdata"
MOODLEDATA_DIR="${U02_APPDATA}/moodledata"
MARIADB_DATADIR_NEW="${U02_MYSQL}"
MARIADB_DATADIR_DEFAULT="/var/lib/mysql"

################################################################################
# Logging (direct — before lib.sh log path may be on /var)
################################################################################

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

################################################################################
# State file helpers (idempotent phase tracking)
################################################################################

state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || true
}

state_set() {
    local key="$1"
    local val="$2"
    mkdir -p "$(dirname "$STATE_FILE")"
    # Remove existing key then append
    if [[ -f "$STATE_FILE" ]]; then
        sed -i "/^${key}=/d" "$STATE_FILE"
    fi
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

Step 00: Oracle Block Volume Setup (Optional)

  Auto-detects attached block volumes and mounts them.

  2 volumes → /u02/mysql (DB) + /u02/appdata (app data)
  1 volume  → /var (migrates existing data safely)

Options:
  --db-device   <dev>   Force device for DB volume  (e.g. /dev/sdb)
  --app-device  <dev>   Force device for app volume (e.g. /dev/sdc)
  --var-device  <dev>   Force device for /var volume
  --dry-run             Show planned actions without making changes
  --yes                 Accept defaults without prompting
  --help                Show this help

Examples:
  sudo bash $0
  sudo bash $0 --dry-run
  sudo bash $0 --db-device /dev/sdb --app-device /dev/sdc
EOF
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "00-block-volume.sh" "${_raw_args[@]}"

FORCE_DB_DEV=""
FORCE_APP_DEV=""
FORCE_VAR_DEV=""

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --db-device)   ((_i++)); FORCE_DB_DEV="${_raw_args[$_i]:-}"  ;;
        --app-device)  ((_i++)); FORCE_APP_DEV="${_raw_args[$_i]:-}" ;;
        --var-device)  ((_i++)); FORCE_VAR_DEV="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 00: Oracle Block Volume Setup"
_log "INFO" "Script started. dry_run=${SRE_DRY_RUN}"

################################################################################
# Detect OS family for service names and AppArmor
################################################################################

detect_os

MARIADB_SVC="mariadb"
# On some Ubuntu installs the service is still called mysql
if ! systemctl list-unit-files "${MARIADB_SVC}.service" &>/dev/null; then
    MARIADB_SVC="mysql"
fi

################################################################################
# Helper: get block device info
################################################################################

dev_fstype()    { lsblk -nd --output FSTYPE     "$1" 2>/dev/null || true; }
dev_mountpoint(){ lsblk -nd --output MOUNTPOINT "$1" 2>/dev/null || true; }
dev_size_bytes(){ lsblk -nd --output SIZE --bytes "$1" 2>/dev/null | tr -d ' ' || echo 0; }
dev_size_human(){ lsblk -nd --output SIZE "$1" 2>/dev/null | tr -d ' ' || echo "?"; }
dev_uuid()      { blkid -s UUID -o value "$1" 2>/dev/null || true; }

################################################################################
# Safety: identify root disk and all its partitions
################################################################################

ROOT_DISK=$(lsblk -nd --output PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)
# Fallback: derive from / mount source
if [[ -z "$ROOT_DISK" ]]; then
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    ROOT_DISK=$(lsblk -nd --output NAME "$root_src" 2>/dev/null | head -1 || true)
fi
ROOT_DISK="${ROOT_DISK:-sda}"
sre_info "Root disk identified as: /dev/${ROOT_DISK}"
_log "INFO" "root_disk=/dev/${ROOT_DISK}"

is_root_disk() {
    local dev="$1"
    local name
    name=$(basename "$dev")
    # Matches root disk itself and any partition of it (sda, sda1, sda2...)
    [[ "$name" == "$ROOT_DISK" || "$name" == "${ROOT_DISK}p"* || "$name" == "${ROOT_DISK}[0-9]"* ]]
}

################################################################################
# Discover candidate volumes
################################################################################

sre_header "Detecting Attached Block Volumes"

candidate_devices=()
while IFS= read -r name; do
    dev="/dev/${name}"
    is_root_disk "$dev" && continue
    [[ "$name" == loop* || "$name" == sr* || "$name" == dm-* ]] && continue
    # Must be a whole disk, not a partition (no parent)
    parent=$(lsblk -nd --output PKNAME "$dev" 2>/dev/null | tr -d ' ' || true)
    [[ -n "$parent" ]] && continue
    candidate_devices+=("$dev")
done < <(lsblk -nd --output NAME 2>/dev/null)

if [[ ${#candidate_devices[@]} -eq 0 ]]; then
    sre_error "No attached block volumes found (excluding root disk /dev/${ROOT_DISK})."
    sre_error ""
    sre_error "In Oracle Cloud Console:"
    sre_error "  Compute → Instances → <your instance> → Attached block volumes → Attach"
    sre_error "  Use paravirtualized attachment for best performance."
    sre_error "  Re-run this script after attaching."
    exit 1
fi

sre_info "Found ${#candidate_devices[@]} candidate volume(s):"
for dev in "${candidate_devices[@]}"; do
    sz=$(dev_size_human "$dev")
    fs=$(dev_fstype "$dev")
    mp=$(dev_mountpoint "$dev")
    sre_info "  $dev  size=$sz  fs=${fs:-none}  mount=${mp:-(not mounted)}"
done

################################################################################
# Decide scenario
################################################################################

SCENARIO=""
DB_DEV=""
APP_DEV=""
VAR_DEV=""

if [[ ${#candidate_devices[@]} -ge 2 ]]; then
    SCENARIO="dual"

    if [[ -n "$FORCE_DB_DEV" && -n "$FORCE_APP_DEV" ]]; then
        DB_DEV="$FORCE_DB_DEV"
        APP_DEV="$FORCE_APP_DEV"
    else
        # Sort by size ascending: smaller = DB, larger = app
        sorted=()
        while IFS= read -r dev; do
            sorted+=("$dev")
        done < <(
            for d in "${candidate_devices[@]}"; do
                echo "$(dev_size_bytes "$d") $d"
            done | sort -n | awk '{print $2}'
        )

        DB_DEV="${sorted[0]}"
        APP_DEV="${sorted[${#sorted[@]}-1]}"

        sre_info ""
        sre_info "Auto-assigned:"
        sre_info "  DB  volume (smaller): $DB_DEV  ($(dev_size_human "$DB_DEV"))"
        sre_info "  App volume (larger):  $APP_DEV ($(dev_size_human "$APP_DEV"))"

        if ! prompt_yesno "Use this assignment?" "yes"; then
            DB_DEV=$(prompt_choice  "Select device for MariaDB (/u02/mysql):"   "${candidate_devices[@]}")
            APP_DEV=$(prompt_choice "Select device for app data (/u02/appdata):" "${candidate_devices[@]}")
        fi
    fi

    # Safety: refuse if either device is the root disk
    for dev in "$DB_DEV" "$APP_DEV"; do
        if is_root_disk "$dev"; then
            sre_error "SAFETY: $dev appears to be the root disk. Refusing to proceed."
            exit 1
        fi
        if [[ ! -b "$dev" ]]; then
            sre_error "Device not found: $dev"
            exit 1
        fi
    done

    if [[ "$DB_DEV" == "$APP_DEV" ]]; then
        sre_error "DB device and app device cannot be the same."
        exit 1
    fi

elif [[ ${#candidate_devices[@]} -eq 1 ]]; then
    SCENARIO="single"
    VAR_DEV="${FORCE_VAR_DEV:-${candidate_devices[0]}}"

    if is_root_disk "$VAR_DEV"; then
        sre_error "SAFETY: $VAR_DEV appears to be the root disk. Refusing to proceed."
        exit 1
    fi
    if [[ ! -b "$VAR_DEV" ]]; then
        sre_error "Device not found: $VAR_DEV"
        exit 1
    fi

    sre_info "Single volume scenario: $VAR_DEV → /var"
fi

sre_info "Scenario: $SCENARIO"
state_set "SCENARIO" "$SCENARIO"

################################################################################
# Helpers: format, mount, fstab
################################################################################

format_volume() {
    local dev="$1"
    local label="$2"

    if phase_done "FORMAT_${label}"; then
        sre_skipped "Format ${dev} (already done)"
        return 0
    fi

    local current_fs
    current_fs=$(dev_fstype "$dev")
    if [[ -n "$current_fs" ]]; then
        sre_warning "$dev already has filesystem: $current_fs"
        if ! prompt_yesno "Reformat $dev with ext4? ALL DATA WILL BE LOST." "no"; then
            sre_error "Aborted by user."
            exit 1
        fi
    fi

    sre_info "Partitioning $dev with GPT..."
    [[ "$SRE_DRY_RUN" == "true" ]] && { sre_info "[DRY-RUN] Would partition and format $dev"; return 0; }

    # Wipe existing signatures
    wipefs -a "$dev" >/dev/null
    # Create GPT and single partition spanning entire disk
    parted -s "$dev" mklabel gpt
    parted -s "$dev" mkpart primary ext4 0% 100%
    partprobe "$dev"
    sleep 2

    # Identify the new partition (e.g. /dev/sdb1 or /dev/sdb1 with nvme naming)
    local part
    part=$(lsblk -lnp --output NAME "$dev" 2>/dev/null | grep -v "^${dev}$" | head -1)
    if [[ -z "$part" ]]; then
        sre_error "Could not find partition on $dev after partitioning."
        exit 1
    fi

    sre_info "Formatting partition $part as ext4 (label: $label)..."
    mkfs.ext4 -F -L "$label" "$part"
    sre_success "Formatted: $part (ext4, label=$label)"
    _log "INFO" "formatted part=$part label=$label"

    mark_done "FORMAT_${label}"
    # Return partition path via state
    state_set "PART_${label}" "$part"
}

get_part() {
    local label="$1"
    local dev="$2"
    local stored
    stored=$(state_get "PART_${label}")
    if [[ -n "$stored" && -b "$stored" ]]; then
        echo "$stored"
        return
    fi
    # Re-detect
    lsblk -lnp --output NAME "$dev" 2>/dev/null | grep -v "^${dev}$" | head -1
}

add_fstab() {
    local uuid="$1"
    local mountpoint="$2"
    local opts="${3:-defaults,noatime}"

    if grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
        sre_skipped "fstab entry for UUID=${uuid} already exists"
        return 0
    fi

    [[ "$SRE_DRY_RUN" == "true" ]] && { sre_info "[DRY-RUN] Would add fstab: UUID=${uuid} ${mountpoint}"; return 0; }

    # Backup fstab on first modification
    if [[ ! -f /etc/fstab.sre-bak ]]; then
        cp /etc/fstab /etc/fstab.sre-bak
        sre_success "Backed up /etc/fstab → /etc/fstab.sre-bak"
    fi

    echo "" >> /etc/fstab
    echo "# sre-helpers step 00: $(date '+%Y-%m-%d')" >> /etc/fstab
    printf "UUID=%s\t%s\text4\t%s\t0\t2\n" "$uuid" "$mountpoint" "$opts" >> /etc/fstab
    sre_success "Added fstab: UUID=${uuid} → ${mountpoint}"
    _log "INFO" "fstab uuid=${uuid} mountpoint=${mountpoint}"
}

mount_volume() {
    local part="$1"
    local mountpoint="$2"
    local label="$3"

    if phase_done "MOUNT_${label}"; then
        sre_skipped "Mount ${mountpoint} (already done)"
        return 0
    fi

    local current_mp
    current_mp=$(dev_mountpoint "$part")
    if [[ "$current_mp" == "$mountpoint" ]]; then
        sre_skipped "$part already mounted at $mountpoint"
        mark_done "MOUNT_${label}"
        return 0
    fi

    if [[ -n "$current_mp" ]]; then
        sre_error "$part is already mounted at $current_mp — not $mountpoint"
        exit 1
    fi

    [[ "$SRE_DRY_RUN" == "true" ]] && { sre_info "[DRY-RUN] Would mount $part → $mountpoint"; return 0; }

    mkdir -p "$mountpoint"
    mount -o defaults,noatime "$part" "$mountpoint"
    sre_success "Mounted: $part → $mountpoint"
    _log "INFO" "mounted part=$part mountpoint=$mountpoint"

    # Verify
    findmnt -n "$mountpoint" >/dev/null || { sre_error "Mount verification failed for $mountpoint"; exit 1; }

    local uuid
    uuid=$(dev_uuid "$part")
    add_fstab "$uuid" "$mountpoint"
    mark_done "MOUNT_${label}"
}

################################################################################
# SCENARIO: DUAL — two volumes
################################################################################

setup_dual() {
    ############################################################################
    # Phase 1: Format volumes
    ############################################################################

    sre_header "Phase 1: Format Volumes"

    sre_info "DB  volume: $DB_DEV → $U02_MYSQL"
    sre_info "App volume: $APP_DEV → $U02_APPDATA"
    sre_info ""
    sre_warning "This will format both devices. All data on them will be erased."
    sre_warning "  DB  device: $DB_DEV ($(dev_size_human "$DB_DEV"))"
    sre_warning "  App device: $APP_DEV ($(dev_size_human "$APP_DEV"))"
    echo ""

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! prompt_yesno "Proceed?" "no"; then
            sre_info "Aborted by user."
            exit 0
        fi
    fi

    format_volume "$DB_DEV"  "u02_mysql"
    format_volume "$APP_DEV" "u02_appdata"

    ############################################################################
    # Phase 2: Mount volumes
    ############################################################################

    sre_header "Phase 2: Mount Volumes"

    db_part=$(get_part "u02_mysql" "$DB_DEV")
    app_part=$(get_part "u02_appdata" "$APP_DEV")

    [[ -z "$db_part" ]]  && { sre_error "Cannot find partition on $DB_DEV";  exit 1; }
    [[ -z "$app_part" ]] && { sre_error "Cannot find partition on $APP_DEV"; exit 1; }

    mount_volume "$db_part"  "$U02_MYSQL"   "u02_mysql"
    mount_volume "$app_part" "$U02_APPDATA" "u02_appdata"

    ############################################################################
    # Phase 3: Move MariaDB datadir
    ############################################################################

    sre_header "Phase 3: Move MariaDB Datadir → ${U02_MYSQL}"

    if phase_done "MARIADB_MOVED"; then
        sre_skipped "MariaDB datadir already moved"
    else
        if [[ "$SRE_DRY_RUN" == "true" ]]; then
            sre_info "[DRY-RUN] Would move MariaDB datadir to ${U02_MYSQL}"
        else
            mariadb_is_running=false
            if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
                mariadb_is_running=true
            fi

            # Stop MariaDB before touching datadir
            if [[ "$mariadb_is_running" == "true" ]]; then
                sre_info "Stopping MariaDB..."
                systemctl stop "$MARIADB_SVC"
                sre_success "MariaDB stopped"
            else
                sre_info "MariaDB is not running — skipping stop"
            fi

            # Copy existing datadir to new location
            if [[ -d "$MARIADB_DATADIR_DEFAULT" ]]; then
                sre_info "Copying ${MARIADB_DATADIR_DEFAULT} → ${U02_MYSQL} ..."
                rsync -aHAX --numeric-ids --info=progress2 \
                    "${MARIADB_DATADIR_DEFAULT}/" "${U02_MYSQL}/"
                sre_success "MariaDB data copied"
                _log "INFO" "mariadb data copied to ${U02_MYSQL}"
            else
                sre_info "No existing MariaDB datadir at ${MARIADB_DATADIR_DEFAULT} — initializing empty"
                mkdir -p "${U02_MYSQL}"
            fi

            # Fix ownership
            chown -R mysql:mysql "${U02_MYSQL}"
            chmod 750 "${U02_MYSQL}"
            sre_success "Ownership set: mysql:mysql on ${U02_MYSQL}"

            # Update MariaDB config
            sre_info "Updating MariaDB datadir config..."
            local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
            # Fallback paths
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

            sre_info "Updating: $mariadb_conf"
            cp "$mariadb_conf" "${mariadb_conf}.bak.$(date +%Y%m%d%H%M%S)"

            if grep -q "^datadir" "$mariadb_conf"; then
                sed -i "s|^datadir.*|datadir = ${U02_MYSQL}|" "$mariadb_conf"
            else
                # Insert after [mysqld] section header
                sed -i "/^\[mysqld\]/a datadir = ${U02_MYSQL}" "$mariadb_conf"
            fi
            sre_success "MariaDB config updated: datadir = ${U02_MYSQL}"
            _log "INFO" "mariadb config updated conf=${mariadb_conf}"

            # Handle AppArmor (Debian/Ubuntu)
            if [[ "$SRE_OS_FAMILY" == "debian" ]] && command -v aa-status &>/dev/null; then
                apparmor_local="/etc/apparmor.d/local/usr.sbin.mysqld"
                if [[ -f "$apparmor_local" ]] || [[ -d /etc/apparmor.d/local ]]; then
                    sre_info "Configuring AppArmor for new datadir..."
                    mkdir -p /etc/apparmor.d/local
                    # Remove old sre entry if present
                    sed -i '/# sre-helpers/d' "$apparmor_local" 2>/dev/null || true
                    cat >> "$apparmor_local" <<AAEOF
# sre-helpers step 00
${U02_MYSQL}/ r,
${U02_MYSQL}/** rwk,
AAEOF
                    apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
                        && sre_success "AppArmor profile reloaded" \
                        || sre_warning "AppArmor reload failed — may need manual fix"
                else
                    sre_info "AppArmor local override not found — skipping"
                fi
            fi

            # Start MariaDB and verify
            sre_info "Starting MariaDB..."
            systemctl start "$MARIADB_SVC"
            sleep 3

            if systemctl is-active --quiet "$MARIADB_SVC"; then
                sre_success "MariaDB started successfully with new datadir"
                _log "INFO" "mariadb started ok"
            else
                sre_error "MariaDB failed to start. Check: journalctl -u ${MARIADB_SVC} -n 50"
                sre_error "Manual rollback: restore $mariadb_conf.bak.* and restart"
                exit 1
            fi

            mark_done "MARIADB_MOVED"
        fi
    fi

    ############################################################################
    # Phase 4: Setup app data directory
    ############################################################################

    sre_header "Phase 4: Setup App Data Directory"

    if phase_done "APPDATA_SETUP"; then
        sre_skipped "App data directories already set up"
    else
        if [[ "$SRE_DRY_RUN" == "true" ]]; then
            sre_info "[DRY-RUN] Would create ${MOODLEDATA_DIR} and set www-data permissions"
        else
            # Create moodledata
            mkdir -p "$MOODLEDATA_DIR"
            chown -R www-data:www-data "$MOODLEDATA_DIR"
            chmod 770 "$MOODLEDATA_DIR"
            sre_success "Created: ${MOODLEDATA_DIR} (www-data:www-data, 770)"
            _log "INFO" "moodledata dir created at ${MOODLEDATA_DIR}"

            # Create Laravel storage placeholder (optional, for future use)
            local laravel_storage="${U02_APPDATA}/laravel-storage"
            mkdir -p "$laravel_storage"
            chown -R www-data:www-data "$laravel_storage"
            chmod 775 "$laravel_storage"
            sre_success "Created: ${laravel_storage} (www-data:www-data, 775)"

            # Set default ACLs so new files inherit correct ownership
            if command -v setfacl &>/dev/null; then
                setfacl -R -m d:u:www-data:rwX "$U02_APPDATA"
                setfacl -R -m u:www-data:rwX   "$U02_APPDATA"
                sre_success "POSIX ACL defaults set on ${U02_APPDATA}"
            fi

            mark_done "APPDATA_SETUP"
        fi
    fi
}

################################################################################
# SCENARIO: SINGLE — one volume → /var
################################################################################

setup_single() {
    sre_header "Single Volume: Mount as /var"

    local var_mp
    var_mp=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
    local var_part
    var_part=$(get_part "var_vol" "$VAR_DEV" 2>/dev/null) || var_part=""

    # Already mounted correctly?
    if [[ -n "$var_part" ]] && [[ "$(dev_mountpoint "$var_part")" == "/var" ]]; then
        sre_skipped "$VAR_DEV already mounted at /var"
        return 0
    fi
    if echo "$var_mp" | grep -q "^${VAR_DEV}"; then
        sre_skipped "$VAR_DEV already mounted at /var"
        return 0
    fi

    sre_info "Volume: $VAR_DEV ($(dev_size_human "$VAR_DEV")) → /var"
    var_has_data=false
    [[ -n "$(ls -A /var 2>/dev/null)" ]] && var_has_data=true

    if [[ "$var_has_data" == "true" ]]; then
        local var_size
        var_size=$(du -sh /var 2>/dev/null | cut -f1 || echo "?")
        sre_info "Current /var size: ${var_size} (will be migrated to volume)"
    fi

    sre_warning "This will format $VAR_DEV. All data on the device will be erased."
    echo ""

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would format $VAR_DEV, migrate /var, remount."
        return 0
    fi

    if ! prompt_yesno "Proceed?" "no"; then
        sre_info "Aborted by user."
        exit 0
    fi

    ############################################################################
    # Format
    ############################################################################

    format_volume "$VAR_DEV" "var_vol"
    var_part=$(get_part "var_vol" "$VAR_DEV")
    [[ -z "$var_part" ]] && { sre_error "Cannot find partition on $VAR_DEV"; exit 1; }

    ############################################################################
    # Migrate existing /var to volume
    ############################################################################

    if [[ "$var_has_data" == "true" ]] && ! phase_done "VAR_MIGRATED"; then
        sre_header "Migrating /var Data to Block Volume"

        local tmp_mount="/mnt/sre_var_$$"
        mkdir -p "$tmp_mount"
        mount -o defaults,noatime "$var_part" "$tmp_mount"

        sre_info "Copying /var → $tmp_mount ..."
        rsync -aHAXx --numeric-ids --info=progress2 /var/ "$tmp_mount/"
        sre_success "Migration complete"
        _log "INFO" "var data migrated to ${var_part}"

        umount "$tmp_mount"
        rmdir "$tmp_mount"
        mark_done "VAR_MIGRATED"
    fi

    ############################################################################
    # Mount over /var
    ############################################################################

    if ! phase_done "VAR_MOUNTED"; then
        sre_info "Mounting $var_part at /var ..."
        mount -o defaults,noatime "$var_part" /var
        findmnt -n /var >/dev/null || { sre_error "Mount verification failed for /var"; exit 1; }
        sre_success "Mounted: $var_part → /var"
        _log "INFO" "mounted var_part=${var_part}"
        mark_done "VAR_MOUNTED"
    fi

    ############################################################################
    # fstab
    ############################################################################

    local uuid
    uuid=$(dev_uuid "$var_part")
    add_fstab "$uuid" "/var"
}

################################################################################
# Run scenario
################################################################################

case "$SCENARIO" in
    dual)   setup_dual   ;;
    single) setup_single ;;
esac

################################################################################
# Validation
################################################################################

sre_header "Validation"

case "$SCENARIO" in
    dual)
        for mp in "$U02_MYSQL" "$U02_APPDATA"; do
            if findmnt -n "$mp" &>/dev/null; then
                sre_success "Mounted: $mp"
                df -h "$mp" | tail -1
            else
                sre_error "NOT mounted: $mp"
            fi
        done

        if systemctl is-active --quiet "$MARIADB_SVC" 2>/dev/null; then
            sre_success "MariaDB is running"
            actual_datadir=$(mysql -NBe "SELECT @@datadir;" 2>/dev/null || true)
            if [[ -n "$actual_datadir" ]]; then
                sre_info "MariaDB datadir: $actual_datadir"
                if [[ "$actual_datadir" == "${U02_MYSQL}/"* || "$actual_datadir" == "${U02_MYSQL}" ]]; then
                    sre_success "MariaDB is using the new datadir"
                else
                    sre_warning "MariaDB datadir is: $actual_datadir (expected: ${U02_MYSQL})"
                fi
            fi
        else
            sre_warning "MariaDB is not running — check: journalctl -u ${MARIADB_SVC} -n 50"
        fi

        [[ -d "$MOODLEDATA_DIR" ]] \
            && sre_success "Moodledata dir exists: $MOODLEDATA_DIR" \
            || sre_warning "Moodledata dir missing: $MOODLEDATA_DIR"
        ;;

    single)
        if findmnt -n /var &>/dev/null; then
            sre_success "Mounted: /var"
            df -h /var | tail -1
        else
            sre_error "NOT mounted: /var"
        fi
        ;;
esac

################################################################################
# Summary
################################################################################

sre_header "Complete"

echo ""
case "$SCENARIO" in
    dual)
        sre_success "Two block volumes configured:"
        sre_info "  ${U02_MYSQL}    → MariaDB datadir"
        sre_info "  ${U02_APPDATA}  → App data (moodledata, Laravel storage)"
        sre_info "  ${MOODLEDATA_DIR} → ready for Moodle"
        echo ""
        sre_info "Migration script (step 10) will use:"
        sre_info "  moodledata: ${MOODLEDATA_DIR}"
        ;;
    single)
        sre_success "Block volume mounted as /var"
        echo ""
        sre_warning "Reboot to confirm /var mounts correctly from fstab:"
        sre_warning "  sudo reboot && df -h /var"
        ;;
esac

echo ""
sre_info "State file: $STATE_FILE"
sre_info "Log file:   $LOG_FILE"
echo ""

recommend_next_step "$CURRENT_STEP"
