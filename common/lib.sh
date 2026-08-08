#!/bin/bash
################################################################################
# SRE Helpers - Common Library
# Sourced by all provisioning scripts
# Provides: logging, OS detection, spec detection, config I/O, prompting,
#           package manager abstraction, prerequisite validation, step registry,
#           argument parsing, and backup utilities.
################################################################################

# Guard against double-sourcing
[[ -n "${_SRE_LIB_LOADED:-}" ]] && return 0
_SRE_LIB_LOADED=1

set -euo pipefail

################################################################################
# T002: Logging Functions
################################################################################

# Colors
readonly _RED='\033[0;31m'
readonly _GREEN='\033[0;32m'
readonly _BLUE='\033[0;34m'
readonly _YELLOW='\033[1;33m'
readonly _NC='\033[0m'

# Defaults (overridable via --config / --log)
SRE_CONFIG_FILE="${SRE_CONFIG_FILE:-/etc/sre-helpers/setup.conf}"
SRE_LOG_FILE="${SRE_LOG_FILE:-/var/log/sre-helpers/provision.log}"
SRE_DRY_RUN="${SRE_DRY_RUN:-false}"
SRE_YES="${SRE_YES:-false}"
SRE_SCRIPT_NAME="${SRE_SCRIPT_NAME:-unknown}"

_log_to_file() {
    local level="$1"
    local msg="$2"
    local log_dir
    log_dir="$(dirname "$SRE_LOG_FILE")"
    [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SRE_SCRIPT_NAME] [$level] $msg" \
        >> "$SRE_LOG_FILE" 2>/dev/null || true
}

sre_info() {
    echo -e "${_BLUE}[INFO]${_NC} $1"
    _log_to_file "INFO" "$1"
}

sre_success() {
    echo -e "${_GREEN}[SUCCESS]${_NC} $1"
    _log_to_file "SUCCESS" "$1"
}

sre_error() {
    echo -e "${_RED}[ERROR]${_NC} $1" >&2
    _log_to_file "ERROR" "$1"
}

sre_warning() {
    echo -e "${_YELLOW}[WARNING]${_NC} $1"
    _log_to_file "WARNING" "$1"
}

sre_skipped() {
    echo -e "${_YELLOW}[SKIPPED]${_NC} $1"
    _log_to_file "SKIPPED" "$1"
}

sre_header() {
    echo ""
    echo -e "${_BLUE}═══════════════════════════════════════════════════════${_NC}"
    echo -e "${_BLUE}  $1${_NC}"
    echo -e "${_BLUE}═══════════════════════════════════════════════════════${_NC}"
    echo ""
    _log_to_file "INFO" "=== $1 ==="
}

################################################################################
# T003: OS Detection
################################################################################

SRE_OS_FAMILY=""
SRE_OS_ID=""
SRE_OS_VERSION=""

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        sre_error "Cannot detect OS: /etc/os-release not found."
        exit 3
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    local id_like="${ID_LIKE:-$ID}"
    case "$id_like" in
        *debian*|*ubuntu*)
            SRE_OS_FAMILY="debian"
            ;;
        *rhel*|*fedora*|*centos*)
            SRE_OS_FAMILY="rhel"
            ;;
        *)
            # Fallback: check ID directly
            case "$ID" in
                ubuntu|debian|linuxmint|pop)
                    SRE_OS_FAMILY="debian" ;;
                rhel|centos|rocky|alma|ol|oraclelinux|fedora)
                    SRE_OS_FAMILY="rhel" ;;
                *)
                    sre_error "Unsupported OS: $ID ($id_like)"
                    sre_error "Supported: Ubuntu, Debian, Oracle Linux, RHEL, CentOS, Rocky, Alma"
                    exit 3
                    ;;
            esac
            ;;
    esac
    SRE_OS_ID="$ID"
    SRE_OS_VERSION="$VERSION_ID"
    sre_info "Detected OS: $SRE_OS_ID $SRE_OS_VERSION (family: $SRE_OS_FAMILY)"
}

################################################################################
# T004: Server Spec Detection
################################################################################

SRE_CPU_CORES=""
SRE_RAM_MB=""
SRE_DISK_TYPE=""
SRE_HOSTNAME=""

detect_specs() {
    SRE_CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    SRE_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "1024")
    SRE_HOSTNAME=$(hostname 2>/dev/null || echo "localhost")

    # Detect disk type: 0 = SSD, 1 = HDD
    if command -v lsblk &>/dev/null; then
        local rota
        rota=$(lsblk -d -n -o rota 2>/dev/null | head -1 || echo "1")
        if [[ "$rota" == "0" ]]; then
            SRE_DISK_TYPE="ssd"
        else
            SRE_DISK_TYPE="hdd"
        fi
    else
        SRE_DISK_TYPE="hdd"
    fi

    sre_info "Server specs: ${SRE_CPU_CORES} CPU cores, ${SRE_RAM_MB}MB RAM, ${SRE_DISK_TYPE} disk"
}

################################################################################
# T005: Config File I/O
################################################################################

config_init() {
    local config_dir
    config_dir="$(dirname "$SRE_CONFIG_FILE")"
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
    fi
    if [[ ! -f "$SRE_CONFIG_FILE" ]]; then
        cat > "$SRE_CONFIG_FILE" <<EOF
# SRE Helpers Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')
# This file is sourced by all SRE helper scripts.
# Edit values here to change behavior on next run.
EOF
        sre_info "Created config file: $SRE_CONFIG_FILE"
    fi
}

config_load() {
    if [[ -f "$SRE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SRE_CONFIG_FILE"
        return 0
    fi
    return 1
}

config_get() {
    local key="$1"
    local default="${2:-}"
    if [[ -f "$SRE_CONFIG_FILE" ]]; then
        local val
        val=$(grep -m1 "^${key}=" "$SRE_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | sed 's/^"\(.*\)"$/\1/' || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    echo "$default"
}

config_set() {
    local key="$1"
    local value="$2"
    config_init
    # Use a python-safe temp approach: remove key then append, avoids sed delimiter issues with slashes
    if grep -q "^${key}=" "$SRE_CONFIG_FILE" 2>/dev/null; then
        sed -i "/^${key}=/d" "$SRE_CONFIG_FILE"
    fi
    printf '%s="%s"\n' "$key" "$value" >> "$SRE_CONFIG_FILE"
}

################################################################################
# T006: Config Backup
################################################################################

backup_config() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    local backup_dir="/etc/sre-helpers/backups"
    mkdir -p "$backup_dir"
    local basename
    basename=$(basename "$file")
    local backup_path="${backup_dir}/${basename}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$backup_path"
    sre_info "Backed up $file -> $backup_path"
}

################################################################################
# T007: Package Manager Abstraction
################################################################################

pkg_update() {
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would update package cache"
        return 0
    fi
    case "$SRE_OS_FAMILY" in
        debian) apt-get update -qq ;;
        rhel)   dnf makecache -q  ;;
        *)      sre_error "Unknown OS family: $SRE_OS_FAMILY"; return 1 ;;
    esac
}

pkg_install() {
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would install: $*"
        return 0
    fi
    case "$SRE_OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
            ;;
        rhel)
            dnf install -y -q "$@"
            ;;
        *)
            sre_error "Unknown OS family: $SRE_OS_FAMILY"
            return 1
            ;;
    esac
}

################################################################################
# T031: OS-Specific Package Name Mapping
################################################################################

# Get the correct web server package name for this OS
get_webserver_pkg() {
    local server="$1" # nginx or apache
    case "$server" in
        nginx) echo "nginx" ;; # Same on both
        apache)
            case "$SRE_OS_FAMILY" in
                debian) echo "apache2" ;;
                rhel)   echo "httpd" ;;
            esac
            ;;
    esac
}

# Get the correct web server service name
get_webserver_svc() {
    local server="$1"
    case "$server" in
        nginx) echo "nginx" ;;
        apache)
            case "$SRE_OS_FAMILY" in
                debian) echo "apache2" ;;
                rhel)   echo "httpd" ;;
            esac
            ;;
    esac
}

# Get PHP-FPM service name
get_phpfpm_svc() {
    local ver="$1"
    case "$SRE_OS_FAMILY" in
        debian) echo "php${ver}-fpm" ;;
        rhel)   echo "php-fpm" ;;
    esac
}

# Check if a specific database engine is in the installed list (comma-separated SRE_DB_ENGINE)
#
# In remote mode the engine runs on another host, so SRE_DB_ENGINE records what
# the REMOTE server speaks. Callers use this to decide "can I provision a MySQL
# database", which is true regardless of where the server lives.
has_db_engine() {
    local engine="$1"
    local engines
    engines=$(config_get "SRE_DB_ENGINE" "none")
    [[ ",$engines," == *",$engine,"* ]]
}

# Get DB service name
get_db_svc() {
    local engine="$1"
    case "$engine" in
        mariadb) echo "mariadb" ;;
        mysql)
            case "$SRE_OS_FAMILY" in
                debian) echo "mysql" ;;
                rhel)   echo "mysqld" ;;
            esac
            ;;
        postgresql) echo "postgresql" ;;
    esac
}

################################################################################
# T032: OS-Specific Config Path Mapping
################################################################################

# Get PHP-FPM pool directory
get_phpfpm_pool_dir() {
    local ver="$1"
    case "$SRE_OS_FAMILY" in
        debian) echo "/etc/php/${ver}/fpm/pool.d" ;;
        rhel)   echo "/etc/php-fpm.d" ;;
    esac
}

# Get php.ini path for FPM
get_php_ini() {
    local ver="$1"
    case "$SRE_OS_FAMILY" in
        debian) echo "/etc/php/${ver}/fpm/php.ini" ;;
        rhel)   echo "/etc/php.ini" ;;
    esac
}

# Get web server vhost directory
get_vhost_dir() {
    local server="$1"
    case "$server" in
        nginx)
            case "$SRE_OS_FAMILY" in
                debian) echo "/etc/nginx/sites-available" ;;
                rhel)   echo "/etc/nginx/conf.d" ;;
            esac
            ;;
        apache)
            case "$SRE_OS_FAMILY" in
                debian) echo "/etc/apache2/sites-available" ;;
                rhel)   echo "/etc/httpd/conf.d" ;;
            esac
            ;;
    esac
}

# Get web server enabled-sites directory (Debian only; RHEL uses conf.d)
get_vhost_enabled_dir() {
    local server="$1"
    case "$SRE_OS_FAMILY" in
        debian)
            case "$server" in
                nginx)  echo "/etc/nginx/sites-enabled" ;;
                apache) echo "/etc/apache2/sites-enabled" ;;
            esac
            ;;
        rhel) echo "" ;; # RHEL uses conf.d directly
    esac
}

# Get main web server config file
get_webserver_conf() {
    local server="$1"
    case "$server" in
        nginx) echo "/etc/nginx/nginx.conf" ;;
        apache)
            case "$SRE_OS_FAMILY" in
                debian) echo "/etc/apache2/apache2.conf" ;;
                rhel)   echo "/etc/httpd/conf/httpd.conf" ;;
            esac
            ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    case "$SRE_OS_FAMILY" in
        debian) dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" ;;
        rhel)   rpm -q "$pkg" &>/dev/null ;;
        *)      return 1 ;;
    esac
}

svc_enable_start() {
    local svc="$1"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would enable and start: $svc"
        return 0
    fi
    systemctl enable --now "$svc"
}

svc_restart() {
    local svc="$1"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would restart: $svc"
        return 0
    fi
    systemctl restart "$svc"
}

svc_reload() {
    local svc="$1"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would reload: $svc"
        return 0
    fi
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
}

################################################################################
# T008: User Prompting
################################################################################

prompt_choice() {
    local prompt_text="$1"
    shift
    local options=("$@")

    if [[ "$SRE_YES" == "true" ]]; then
        echo "${options[0]}"
        return 0
    fi

    local i
    echo "" >&2
    echo -e "${_BLUE}${prompt_text}${_NC}" >&2
    for i in "${!options[@]}"; do
        echo "  $((i + 1))) ${options[$i]}" >&2
    done

    while true; do
        read -r -p "Choose [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        echo "Invalid choice. Please enter a number between 1 and ${#options[@]}." >&2
    done
}

prompt_yesno() {
    local prompt_text="$1"
    local default="${2:-yes}"

    if [[ "$SRE_YES" == "true" ]]; then
        [[ "$default" == "yes" ]] && return 0 || return 1
    fi

    local hint
    if [[ "$default" == "yes" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    read -r -p "$prompt_text $hint: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

prompt_input() {
    local prompt_text="$1"
    local default="${2:-}"

    if [[ "$SRE_YES" == "true" && -n "$default" ]]; then
        echo "$default"
        return 0
    fi

    local hint=""
    [[ -n "$default" ]] && hint=" [default: $default]"

    read -r -p "${prompt_text}${hint}: " answer
    echo "${answer:-$default}"
}

################################################################################
# T009: Prerequisite Validation
################################################################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        sre_error "This script must be run as root (or with sudo)."
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    local step="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        sre_error "Required command '$cmd' not found."
        [[ -n "$step" ]] && sre_error "Run step $step first."
        exit 2
    fi
}

require_config_key() {
    local key="$1"
    local step="${2:-}"
    local val
    val=$(config_get "$key")
    if [[ -z "$val" ]]; then
        sre_error "Config key '$key' is not set in $SRE_CONFIG_FILE."
        [[ -n "$step" ]] && sre_error "Run step $step first."
        exit 2
    fi
    echo "$val"
}

require_step() {
    local step_num="$1"
    local desc="$2"
    local check_key="$3"
    local val
    val=$(config_get "$check_key")
    if [[ -z "$val" ]]; then
        sre_error "Prerequisite not met: $desc"
        sre_error "Run step $step_num first: ${STEP_REGISTRY[$step_num]:-unknown}"
        exit 2
    fi
}

################################################################################
# T010: Step Registry & Next-Step Recommendation
################################################################################

# Determine scripts base directory relative to this lib.sh
SRE_SCRIPTS_DIR="${SRE_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

declare -A STEP_REGISTRY=(
    [0]="server/00-block-volume.sh"
    [1]="server/01-base-setup.sh"
    [2]="server/02-firewall.sh"
    [3]="stack/03-web-server.sh"
    [4]="stack/04-php.sh"
    [5]="stack/05-database.sh"
    [6]="stack/06-node.sh"
    [7]="tuning/07-tune.sh"
    [8]="vhost/08-vhost.sh"
    [9]="server/09-ssh-keys.sh"
    [10]="migrate/10-migrate-cpanel.sh"
    [11]="ssl/11-ssl.sh"
    [12]="fixes/12-fixes.sh"
    [13]="deploy/13-new-project.sh"
    [14]="migrate/14-backup-only.sh"
    [15]="migrate/15-migrate-cpanel-bulk.sh"
    [16]="clone/16-clone-project.sh"
    [17]="stack/17-phpmyadmin.sh"
    [18]="ssl/18-custom-ssl.sh"
    [19]="vhost/19-mount-subpath.sh"
    [21]="setup/21-claude-code.sh"
)

declare -A STEP_NAMES=(
    [0]="Block Volume Mount (Oracle)"
    [1]="Base Setup"
    [2]="Firewall"
    [3]="Web Server"
    [4]="PHP"
    [5]="Database"
    [6]="Node.js"
    [7]="Performance Tuning"
    [8]="Virtual Host"
    [9]="SSH Key Setup"
    [10]="Migrate from cPanel"
    [11]="SSL Certificate"
    [12]="Quick Fixes"
    [13]="Deploy New Project (Git)"
    [14]="Backup-Only Capture (no restore)"
    [15]="Bulk Migrate from cPanel/WHM"
    [16]="Clone Project (Stage or Live Copy)"
    [17]="phpMyAdmin (Optional)"
    [18]="Install Custom SSL (Wildcard / Single)"
    [19]="Mount Project as Subpath"
    [21]="Claude Code (agents, skills, MCPs)"
)

_is_step_skipped() {
    local step="$1"
    case "$step" in
        5) # In remote mode step 5 still installs client packages and validates
           # connectivity, so it is never "skipped" even with no local engine.
           [[ "$(config_get "SRE_DB_MODE" "local")" == "remote" ]] && return 1
           local e; e=$(config_get "SRE_DB_ENGINE" "none"); [[ "$e" == "none" || -z "$e" ]] && return 0 ;;
        6) local v; v=$(config_get "SRE_NODE_VERSION" ""); [[ -z "$v" ]] && return 0 ;;
        0|9|10|13|14|15|16|17|18|19|21) return 0 ;; # all optional / on-demand steps
    esac
    return 1
}

_is_step_optional() {
    local step="$1"
    [[ "$step" == "0" || "$step" == "9" || "$step" == "10" || "$step" == "12" || "$step" == "13" || "$step" == "14" || "$step" == "15" || "$step" == "16" || "$step" == "17" || "$step" == "18" || "$step" == "19" || "$step" == "21" ]] && return 0
    return 1
}

recommend_next_step() {
    local current_step="$1"

    # Find next non-skipped step
    local next_step=$((current_step + 1))
    while [[ -n "${STEP_REGISTRY[$next_step]:-}" ]]; do
        _is_step_skipped "$next_step" && next_step=$((next_step + 1)) && continue
        break
    done

    echo ""
    echo -e "${_BLUE}═══════════════════════════════════════════════════════${_NC}"
    echo -e "${_BLUE}  PROVISIONING STEPS${_NC}"
    echo -e "${_BLUE}═══════════════════════════════════════════════════════${_NC}"

    local s
    for s in $(echo "${!STEP_REGISTRY[@]}" | tr ' ' '\n' | sort -n); do
        local marker="  "
        local color="${_NC}"
        local suffix=""

        if (( s < current_step )); then
            marker="✓ "
            color="${_GREEN}"
        elif (( s == current_step )); then
            marker="● "
            color="${_GREEN}"
            suffix=" (done)"
        elif (( s == next_step )); then
            marker="→ "
            color="${_YELLOW}"
            suffix=" ← NEXT"
        else
            marker="  "
            color="${_NC}"
        fi

        if _is_step_optional "$s"; then
            marker="○ "
            color="${_NC}"
            suffix=" (optional)"
        elif _is_step_skipped "$s"; then
            marker="- "
            color="${_NC}"
            suffix=" (skipped)"
        fi

        echo -e "${color}  ${marker}Step ${s}: ${STEP_NAMES[$s]:-Step $s}${suffix}${_NC}"
        echo -e "${color}         sudo bash ${SRE_SCRIPTS_DIR}/${STEP_REGISTRY[$s]}${_NC}"
    done

    echo -e "${_BLUE}═══════════════════════════════════════════════════════${_NC}"

    if [[ -n "${STEP_REGISTRY[$next_step]:-}" ]]; then
        echo ""
        echo -e "${_YELLOW}  Run next: sudo bash ${SRE_SCRIPTS_DIR}/${STEP_REGISTRY[$next_step]}${_NC}"
    else
        echo ""
        echo -e "${_GREEN}  ALL STEPS COMPLETE${_NC}"
    fi
    echo ""
}

################################################################################
# T011: Common Argument Parsing
################################################################################

sre_parse_args() {
    local script_name="$1"
    shift
    SRE_SCRIPT_NAME="$script_name"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                SRE_DRY_RUN="true"
                sre_info "Dry-run mode enabled. No changes will be made."
                ;;
            --yes|-y)
                SRE_YES="true"
                ;;
            --config)
                shift
                SRE_CONFIG_FILE="${1:?'--config requires a path argument'}"
                ;;
            --log)
                shift
                SRE_LOG_FILE="${1:?'--log requires a path argument'}"
                ;;
            --help|-h)
                if declare -F sre_show_help &>/dev/null; then
                    sre_show_help
                else
                    echo "Usage: sudo bash $script_name [OPTIONS]"
                    echo "  --dry-run   Print planned actions without executing"
                    echo "  --yes       Accept defaults without prompting"
                    echo "  --config    Override config file path"
                    echo "  --log       Override log file path"
                    echo "  --help      Show this help message"
                fi
                exit 0
                ;;
            *)
                # Pass unrecognized args to caller via SRE_EXTRA_ARGS
                SRE_EXTRA_ARGS+=("$1")
                ;;
        esac
        shift
    done
}

# Array for script-specific args not consumed by common parsing
SRE_EXTRA_ARGS=()

# Helper: clamp a value between min and max
clamp() {
    local val="$1" min="$2" max="$3"
    (( val < min )) && val=$min
    (( val > max )) && val=$max
    echo "$val"
}

# Helper: ensure setfacl is available, install acl if missing
require_acl() {
    if ! command -v setfacl &>/dev/null; then
        sre_warning "setfacl not found — installing acl package..."
        pkg_install acl
        if ! command -v setfacl &>/dev/null; then
            sre_error "Failed to install acl package. Cannot set filesystem ACLs."
            return 1
        fi
        sre_success "acl package installed"
    fi
    return 0
}

################################################################################
# PECL imagick installation
#
# `pecl install imagick` alone is unreliable: the maintainers have not marked a
# release "stable" on pecl.php.net for years, and PECL refuses to install an
# unstable release implicitly. On such a host the command fails with:
#
#   No releases available for package "pecl.php.net/imagick"
#
# even though the package exists. The fix is to name a version explicitly (or
# request the beta channel), so we try progressively more specific forms.
#
# Prints the built extension path on success. Returns non-zero on failure, with
# the real PECL output shown — callers must NOT assume success.
################################################################################

# Locate a source-built ImageMagick 7 (step 4 installs it to /usr/local).
# Prints its prefix and returns 0 when found; returns 1 otherwise.
sre_im7_prefix() {
    local p
    for p in /usr/local /opt/imagemagick7; do
        # A source install is identified by its MagickWand pkg-config file
        # reporting major version 7.
        if [[ -f "${p}/lib/pkgconfig/MagickWand.pc" ]]; then
            if grep -qE '^Version:[[:space:]]*7\.' "${p}/lib/pkgconfig/MagickWand.pc"; then
                printf '%s' "$p"
                return 0
            fi
        fi
    done
    return 1
}

# Remove an imagick.ini that points at a .so which does not exist.
#
# This matters because `pecl` is itself a PHP script: a dangling
# "extension=imagick.so" makes EVERY pecl invocation start with
#   PHP Warning: Unable to load dynamic library 'imagick.so'
# which pollutes the output and, on some setups, is enough to break the
# install. Earlier versions of these scripts wrote imagick.ini
# unconditionally even when the build had failed, so such leftovers exist
# in the wild.
sre_clear_broken_imagick_ini() {
    local php_ver="$1"
    local ext_dir so_path removed=0

    local php_bin="php"
    [[ -x "/usr/bin/php${php_ver}" ]] && php_bin="/usr/bin/php${php_ver}"
    ext_dir=$("$php_bin" -r 'echo ini_get("extension_dir");' 2>/dev/null)
    so_path="${ext_dir%/}/imagick.so"

    # If the .so genuinely exists there is nothing to clean up.
    [[ -n "$ext_dir" && -f "$so_path" ]] && return 0

    local f
    for f in "/etc/php/${php_ver}/mods-available/imagick.ini" \
             "/etc/php/${php_ver}/cli/conf.d/"*imagick.ini \
             "/etc/php/${php_ver}/fpm/conf.d/"*imagick.ini \
             /etc/php.d/*imagick.ini; do
        [[ -e "$f" ]] || continue
        rm -f "$f" && removed=1
    done

    if (( removed )); then
        sre_warning "  Removed a stale imagick.ini (pointed at a missing imagick.so)."
        sre_warning "  It was making every PHP/pecl invocation emit a startup warning."
    fi
    return 0
}

sre_pecl_install_imagick() {
    local php_ver="$1"
    local pecl_bin="pecl"

    # Do this first: a dangling extension=imagick.so breaks pecl's own startup.
    sre_clear_broken_imagick_ini "$php_ver"

    # Pin the build to a source-installed ImageMagick 7 when one exists.
    #
    # Without this, pkg-config searches its default path first and a distro
    # IM6 (/usr/lib/.../MagickWand.pc, pulled in by libmagickwand-dev) wins
    # over the IM7 in /usr/local. The extension then compiles and loads fine
    # but is linked against ImageMagick 6 — silently losing the
    # raqm/harfbuzz/fribidi text shaping that Arabic rendering depends on.
    local im7
    if im7="$(sre_im7_prefix)"; then
        export PKG_CONFIG_PATH="${im7}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
        export LD_LIBRARY_PATH="${im7}/lib:${LD_LIBRARY_PATH:-}"
        # Make the IM7 binaries (magick, MagickWand-config) win on PATH too.
        export PATH="${im7}/bin:${PATH}"
        sre_info "  Pinning build to ImageMagick 7 at ${im7}"
    fi
    # Debian's php<ver>-dev ships a version-specific pecl; prefer it so the
    # extension is built against the intended PHP, not just the default one.
    [[ -x "/usr/bin/pecl${php_ver}" ]] && pecl_bin="/usr/bin/pecl${php_ver}"

    local out rc
    # Order matters:
    #  - plain `imagick` first: succeeds on hosts that do have a stable release
    #    and avoids pinning them to a specific version unnecessarily.
    #  - then 3.8.0, which is the release with proper ImageMagick 7 support.
    #  - 3.7.0 last, as a desperation fallback: it predates full IM7 support and
    #    often fails to compile against IM7 headers, so trying it before 3.8.0
    #    just wastes a compile and produces a confusing error.
    local -a candidates=("imagick" "imagick-beta" "imagick-3.8.0" "imagick-3.7.0")

    local spec
    for spec in "${candidates[@]}"; do
        sre_info "  Trying: ${pecl_bin} install ${spec}"
        # `printf "\n"` accepts the "use default" answer for imagick's single
        # configure prompt. 2>&1 so failures are diagnosable, not hidden.
        out=$(printf "\n" | "$pecl_bin" install "$spec" 2>&1)
        rc=$?

        if [[ $rc -eq 0 ]]; then
            sre_success "  imagick built via '${spec}'"
            return 0
        fi

        # Already installed is a success for our purposes; PECL exits non-zero.
        if grep -qi "already installed" <<<"$out"; then
            sre_info "  imagick already installed; forcing a rebuild"
            out=$(printf "\n" | "$pecl_bin" install --force "$spec" 2>&1)
            rc=$?
            if [[ $rc -eq 0 ]]; then
                sre_success "  imagick rebuilt via '${spec}'"
                return 0
            fi
        fi

        # Only keep trying if this looks like the "no stable release" problem.
        # Any other failure (missing headers, compile error) will not be fixed
        # by naming a different version, so stop and report it.
        if ! grep -qiE "No releases available|requires PEAR|is not valid" <<<"$out"; then
            sre_error "  PECL build failed for '${spec}':"
            sed 's/^/    /' <<<"$out" | tail -25 >&2
            return 1
        fi
    done

    sre_warning "  PECL could not resolve a release. Last output:"
    sed 's/^/    /' <<<"$out" | tail -15 >&2

    # Last resort: build from the upstream source tarball, bypassing PECL's
    # release registry entirely. This is the reliable path when pecl.php.net
    # reports "No releases available" — the code is fine, only the registry
    # metadata is the problem.
    sre_info "  Falling back to building imagick from source..."
    sre_build_imagick_from_source "$php_ver"
}

# Build the imagick extension from the upstream GitHub tarball.
# Used when PECL's registry cannot resolve a release.
sre_build_imagick_from_source() {
    local php_ver="$1"
    local version="${2:-3.8.0}"
    local build_dir ext_dir phpize_bin php_config_bin rc

    phpize_bin="phpize"
    php_config_bin="php-config"
    [[ -x "/usr/bin/phpize${php_ver}"     ]] && phpize_bin="/usr/bin/phpize${php_ver}"
    [[ -x "/usr/bin/php-config${php_ver}" ]] && php_config_bin="/usr/bin/php-config${php_ver}"

    if ! command -v "$phpize_bin" &>/dev/null; then
        sre_error "  phpize not found — install php${php_ver}-dev (or php-devel)."
        return 1
    fi

    build_dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand build_dir now, not at trap time
    trap "rm -rf '$build_dir'" RETURN

    local url="https://github.com/Imagick/imagick/archive/refs/tags/${version}.tar.gz"
    sre_info "  Downloading imagick ${version} source..."
    if ! curl -fsSL "$url" -o "${build_dir}/imagick.tar.gz" 2>/dev/null; then
        sre_error "  Could not download ${url}"
        return 1
    fi

    tar xzf "${build_dir}/imagick.tar.gz" -C "$build_dir" || {
        sre_error "  Could not extract the imagick source tarball."
        return 1
    }

    local src
    src=$(find "$build_dir" -maxdepth 1 -type d -name 'imagick-*' | head -1)
    if [[ -z "$src" ]]; then
        sre_error "  imagick source directory not found after extraction."
        return 1
    fi

    sre_info "  Compiling imagick ${version} for PHP ${php_ver}..."
    (
        cd "$src" || exit 1
        "$phpize_bin" >/dev/null 2>&1 || exit 1
        # PKG_CONFIG_PATH was already pinned to the source IM7 by the caller.
        ./configure --with-php-config="$php_config_bin" >/dev/null 2>&1 || exit 1
        make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 || exit 1
        make install >/dev/null 2>&1 || exit 1
    )
    rc=$?

    if [[ $rc -ne 0 ]]; then
        sre_error "  Source build failed. Re-run manually to see the full output:"
        sre_error "    curl -fsSL ${url} -o /tmp/imagick.tar.gz"
        sre_error "    cd /tmp && tar xzf imagick.tar.gz && cd imagick-${version}"
        sre_error "    ${phpize_bin} && ./configure --with-php-config=${php_config_bin}"
        sre_error "    make && sudo make install"
        return 1
    fi

    ext_dir=$("$php_config_bin" --extension-dir 2>/dev/null)
    if [[ -n "$ext_dir" && -f "${ext_dir}/imagick.so" ]]; then
        sre_success "  imagick ${version} built from source → ${ext_dir}/imagick.so"
        return 0
    fi

    sre_error "  Build reported success but imagick.so is not in ${ext_dir:-<unknown>}"
    return 1
}

# Verify the imagick extension loads for a given PHP version and report which
# ImageMagick it linked against. Returns non-zero if not loaded.
#
# Also warns when the extension loaded but linked against ImageMagick 6 while a
# source-built IM7 is present — that combination means Arabic text shaping is
# broken even though everything "works", which is otherwise very hard to spot.
sre_verify_imagick() {
    local php_ver="$1"
    local php_bin="php"
    [[ -x "/usr/bin/php${php_ver}" ]] && php_bin="/usr/bin/php${php_ver}"

    if ! "$php_bin" -m 2>/dev/null | grep -qi '^imagick$'; then
        return 1
    fi

    local im_ver
    im_ver=$("$php_bin" -r 'if (class_exists("Imagick")) { $v = Imagick::getVersion(); echo $v["versionString"] ?? ""; }' 2>/dev/null)
    if [[ -n "$im_ver" ]]; then
        sre_info "  Linked against: $im_ver"
        if [[ "$im_ver" == *"ImageMagick 6"* ]] && sre_im7_prefix >/dev/null; then
            sre_warning "  imagick is linked against ImageMagick 6, but ImageMagick 7"
            sre_warning "  is installed at $(sre_im7_prefix). Arabic text shaping"
            sre_warning "  (raqm/harfbuzz/fribidi) will NOT work through PHP."
            sre_warning "  Rebuild with the IM7 headers first on PKG_CONFIG_PATH."
        fi
    fi
    return 0
}

# Report whether ImageMagick 7 was built with the Arabic text-shaping stack.
# Informational: prints a warning when the delegates are missing.
sre_check_imagick_arabic() {
    local magick_bin="magick"
    local im7
    im7="$(sre_im7_prefix 2>/dev/null || true)"
    [[ -n "$im7" && -x "${im7}/bin/magick" ]] && magick_bin="${im7}/bin/magick"
    command -v "$magick_bin" &>/dev/null || return 1

    local features
    features=$("$magick_bin" -version 2>/dev/null | grep -i '^Delegates' || true)
    [[ -z "$features" ]] && return 1

    # raqm is THE signal. ImageMagick lists it in Delegates; harfbuzz and
    # fribidi are raqm's own hard dependencies, linked in transitively and
    # deliberately NOT listed there. Requiring all three by name reports a
    # perfectly good Arabic-capable build as broken — libraqm literally
    # cannot be built without harfbuzz and fribidi.
    if ! grep -qi 'raqm' <<<"$features"; then
        sre_warning "ImageMagick has no 'raqm' delegate — Arabic text will render"
        sre_warning "unshaped and in reverse order."
        sre_warning "  $features"
        sre_warning "Recompile ImageMagick 7 with:"
        sre_warning "  --with-raqm=yes --with-harfbuzz=yes --with-fribidi=yes"
        return 1
    fi

    # Confirm harfbuzz/fribidi really are linked in, rather than trusting that
    # raqm implies them. Checked against the binary, not the Delegates string.
    local libs="" lib_warn=""
    if command -v ldd &>/dev/null; then
        local raqm_lib
        raqm_lib=$(ldd "$(command -v "$magick_bin")" 2>/dev/null | awk '/libraqm/{print $3; exit}')
        [[ -n "$raqm_lib" && -e "$raqm_lib" ]] && libs=$(ldd "$raqm_lib" 2>/dev/null || true)
        if [[ -n "$libs" ]]; then
            grep -qi 'libharfbuzz' <<<"$libs" || lib_warn+=" harfbuzz"
            grep -qi 'libfribidi'  <<<"$libs" || lib_warn+=" fribidi"
        fi
    fi

    if [[ -n "$lib_warn" ]]; then
        sre_warning "raqm is present but not linked against:${lib_warn}"
        sre_warning "Arabic shaping may still be incomplete."
        return 1
    fi

    sre_success "ImageMagick has Arabic text shaping (raqm delegate present)"
    [[ -n "$libs" ]] && sre_info "  raqm links harfbuzz and fribidi as expected"
    return 0
}

# Helper: check if a port is in use
port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        return 1
    fi
}

# Helper: write content to a file with dry-run support
sre_write_file() {
    local dest="$1"
    local content="$2"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would write to $dest"
        return 0
    fi
    # Backup if exists
    [[ -f "$dest" ]] && backup_config "$dest"
    echo "$content" > "$dest"
    sre_success "Written: $dest"
}

################################################################################
# Per-project isolation library (users, FPM pools, permissions)
################################################################################
# shellcheck source=isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/isolation.sh"

################################################################################
# Database connection library (local socket vs remote SQL server)
################################################################################
# shellcheck source=dbconn.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dbconn.sh"

# Shred the temporary DB credentials file when the script exits.
#
# Registered HERE, in the top-level shell that sources lib.sh, because a trap
# set inside a command substitution would fire in that subshell and delete the
# file while the parent still needs it.
trap db_cnf_cleanup EXIT
