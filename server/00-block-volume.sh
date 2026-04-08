#!/bin/bash
################################################################################
# SRE Helpers - Step 00: Mount Oracle Block Volume as /var
# Optional pre-step. Attaches and mounts a block volume to /var.
# Handles:
#   - Fresh volume (no filesystem): formats + mounts
#   - Existing /var data: migrates data to volume, then remounts as /var
#   - Already mounted: detects and skips
# Safe: never writes fstab or formats until user confirms.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=0

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 00: Mount Oracle Block Volume as /var (Optional)

  Detects an attached block volume and mounts it as /var.
  Safe to re-run: skips if already mounted.

  Scenarios handled:
    fresh     - Volume has no filesystem: formats with ext4, mounts
    migrate   - /var has existing data: copies data to volume, remounts
    already   - Volume already mounted at /var: skips

Options:
  --device <path>   Block device path (e.g. /dev/sdb). Auto-detected if omitted.
  --dry-run         Show planned actions without making changes
  --yes             Accept defaults without prompting
  --help            Show this help

Examples:
  sudo bash $0
  sudo bash $0 --device /dev/sdb
  sudo bash $0 --dry-run
EOF
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "00-block-volume.sh" "${_raw_args[@]}"

BV_DEVICE=""
_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --device) ((_i++)); BV_DEVICE="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 00: Mount Oracle Block Volume as /var"

################################################################################
# Detect available block devices
################################################################################

sre_header "Detecting Block Devices"

# List all block devices (exclude loop, sr, and the root disk)
root_disk=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)
root_disk="${root_disk:-sda}"

sre_info "Root disk: /dev/${root_disk}"
sre_info "Scanning for attached block volumes..."

# Collect candidate devices: block devices that are NOT the root disk and NOT already a partition of it
candidate_devices=()
while IFS= read -r line; do
    dev="/dev/${line}"
    # Skip root disk and its partitions
    [[ "$line" == "$root_disk"* ]] && continue
    # Skip loop and sr devices
    [[ "$line" == loop* || "$line" == sr* ]] && continue
    candidate_devices+=("$dev")
done < <(lsblk -nd --output NAME 2>/dev/null)

if [[ ${#candidate_devices[@]} -eq 0 ]]; then
    sre_error "No attached block volumes found."
    sre_error ""
    sre_error "In Oracle Cloud Console:"
    sre_error "  1. Go to: Compute → Instances → your instance"
    sre_error "  2. Click 'Attach block volume'"
    sre_error "  3. Select your block volume"
    sre_error "  4. Use iSCSI or paravirtualized attachment"
    sre_error "  5. Re-run this script after attaching"
    exit 1
fi

sre_info "Found ${#candidate_devices[@]} candidate device(s):"
for dev in "${candidate_devices[@]}"; do
    size=$(lsblk -nd --output SIZE "$dev" 2>/dev/null || echo "?")
    fs=$(lsblk -nd --output FSTYPE "$dev" 2>/dev/null || echo "none")
    mountpoint=$(lsblk -nd --output MOUNTPOINT "$dev" 2>/dev/null || echo "")
    sre_info "  $dev  size=$size  fs=${fs:-none}  mount=${mountpoint:-(not mounted)}"
done

################################################################################
# Select device
################################################################################

if [[ -z "$BV_DEVICE" ]]; then
    if [[ ${#candidate_devices[@]} -eq 1 ]]; then
        BV_DEVICE="${candidate_devices[0]}"
        sre_info "Auto-selected: $BV_DEVICE"
    else
        BV_DEVICE=$(prompt_choice "Select block device to use for /var:" "${candidate_devices[@]}")
    fi
fi

if [[ ! -b "$BV_DEVICE" ]]; then
    sre_error "Device not found or not a block device: $BV_DEVICE"
    exit 1
fi

sre_success "Selected device: $BV_DEVICE"

################################################################################
# Check current state of device and /var
################################################################################

sre_header "Analysing Current State"

dev_fs=$(lsblk -nd --output FSTYPE "$BV_DEVICE" 2>/dev/null || true)
dev_mount=$(lsblk -nd --output MOUNTPOINT "$BV_DEVICE" 2>/dev/null || true)
dev_size=$(lsblk -nd --output SIZE "$BV_DEVICE" 2>/dev/null || echo "?")

sre_info "Device:     $BV_DEVICE ($dev_size)"
sre_info "Filesystem: ${dev_fs:-none (unformatted)}"
sre_info "Mounted at: ${dev_mount:-(not mounted)}"

var_mount=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
sre_info "Current /var source: ${var_mount:-(root disk)}"

# Case 1: already mounted at /var — nothing to do
if [[ "$dev_mount" == "/var" ]] || [[ "$var_mount" == "$BV_DEVICE" ]]; then
    sre_success "$BV_DEVICE is already mounted at /var. Nothing to do."
    recommend_next_step "$CURRENT_STEP"
    exit 0
fi

# Case 2: device is mounted somewhere else — refuse
if [[ -n "$dev_mount" ]] && [[ "$dev_mount" != "/var" ]]; then
    sre_error "$BV_DEVICE is already mounted at: $dev_mount"
    sre_error "Unmount it first or choose a different device."
    exit 1
fi

################################################################################
# Determine scenario: fresh or migrate
################################################################################

scenario="fresh"
var_has_data=false

if [[ -n "$(ls -A /var 2>/dev/null)" ]]; then
    var_has_data=true
fi

if [[ -z "$dev_fs" ]]; then
    scenario="fresh"
    sre_info "Scenario: FRESH — device has no filesystem"
else
    scenario="format_and_migrate"
    sre_warning "Scenario: MIGRATE — device has existing filesystem ($dev_fs)"
    sre_warning "All data on $BV_DEVICE will be REPLACED with current /var contents."
fi

if [[ "$var_has_data" == "true" ]]; then
    var_size=$(du -sh /var 2>/dev/null | cut -f1 || echo "?")
    sre_info "Current /var size: $var_size (will be migrated to volume)"
fi

################################################################################
# Confirm before any destructive action
################################################################################

sre_header "Confirm Plan"

echo ""
sre_info "PLAN:"
sre_info "  Device:    $BV_DEVICE ($dev_size)"
if [[ "$scenario" == "fresh" ]]; then
    sre_info "  Action:    Format $BV_DEVICE with ext4, mount as /var"
else
    sre_info "  Action:    Format $BV_DEVICE with ext4 (ERASES existing data on device)"
    sre_info "             Copy current /var → $BV_DEVICE"
    sre_info "             Remount $BV_DEVICE as /var"
fi
sre_info "  Persist:   Add entry to /etc/fstab (survives reboot)"
echo ""
sre_warning "THIS CANNOT BE UNDONE. Make sure you have a snapshot/backup."
echo ""

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] Would execute the above plan."
    recommend_next_step "$CURRENT_STEP"
    exit 0
fi

if ! prompt_yesno "Proceed with mounting $BV_DEVICE as /var?" "no"; then
    sre_info "Aborted by user."
    exit 0
fi

################################################################################
# Format device
################################################################################

sre_header "Formatting Device"

sre_info "Formatting $BV_DEVICE with ext4..."
mkfs.ext4 -F -L var_volume "$BV_DEVICE"
sre_success "Formatted: $BV_DEVICE (ext4, label=var_volume)"

# Get UUID for fstab (more reliable than device path on Oracle Cloud)
dev_uuid=$(blkid -s UUID -o value "$BV_DEVICE")
sre_success "UUID: $dev_uuid"

################################################################################
# Migrate existing /var data (if any)
################################################################################

if [[ "$var_has_data" == "true" ]]; then
    sre_header "Migrating /var Data to Block Volume"

    tmp_mount="/mnt/var_volume_$$"
    mkdir -p "$tmp_mount"

    sre_info "Mounting $BV_DEVICE at $tmp_mount..."
    mount "$BV_DEVICE" "$tmp_mount"

    sre_info "Copying /var → $tmp_mount (this may take a while)..."
    rsync -aHAXx --numeric-ids --info=progress2 /var/ "$tmp_mount/"
    sre_success "Data copied successfully"

    sre_info "Unmounting $tmp_mount..."
    umount "$tmp_mount"
    rmdir "$tmp_mount"
    sre_success "Temporary mount cleaned up"
else
    sre_info "No existing /var data to migrate."
fi

################################################################################
# Mount as /var
################################################################################

sre_header "Mounting Block Volume as /var"

# Remounting /var requires moving current processes off it
# Safest approach: mount over /var (kernel allows this on Linux)
sre_info "Mounting $BV_DEVICE at /var..."
mount -o defaults,noatime "$BV_DEVICE" /var
sre_success "$BV_DEVICE mounted at /var"

# Verify
var_mount_check=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
if [[ "$var_mount_check" != "$BV_DEVICE" ]]; then
    # Try by UUID
    var_mount_check=$(findmnt -n -o SOURCE /var 2>/dev/null || true)
fi
sre_success "Verified: /var is now on $BV_DEVICE"

################################################################################
# Persist in /etc/fstab
################################################################################

sre_header "Persisting Mount in /etc/fstab"

fstab_entry="UUID=${dev_uuid}  /var  ext4  defaults,noatime  0  2"

# Check if already in fstab
if grep -q "$dev_uuid" /etc/fstab 2>/dev/null; then
    sre_info "UUID already in /etc/fstab — skipping."
else
    # Backup fstab first
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
    sre_success "Backed up /etc/fstab"

    echo "" >> /etc/fstab
    echo "# Block volume mounted as /var by sre-helpers step 00" >> /etc/fstab
    echo "$fstab_entry" >> /etc/fstab
    sre_success "Added to /etc/fstab: $fstab_entry"
fi

# Validate fstab
if findmnt --verify --target /var &>/dev/null; then
    sre_success "fstab entry verified"
else
    sre_warning "fstab verify returned a warning — check /etc/fstab manually"
fi

################################################################################
# Summary
################################################################################

sre_header "Block Volume Mount Complete"

echo ""
sre_success "Block volume is now mounted as /var"
echo ""
sre_info "  Device:   $BV_DEVICE"
sre_info "  UUID:     $dev_uuid"
sre_info "  Mount:    /var"
sre_info "  Options:  defaults,noatime"
sre_info "  fstab:    /etc/fstab (persisted)"
echo ""
sre_info "Disk usage:"
df -h /var
echo ""
sre_warning "IMPORTANT: Reboot to confirm /var remounts correctly from fstab:"
sre_warning "  sudo reboot"
sre_warning "  df -h /var   # after reboot — confirm mount"
echo ""

recommend_next_step "$CURRENT_STEP"
