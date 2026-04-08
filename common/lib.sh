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
)

_is_step_skipped() {
    local step="$1"
    case "$step" in
        5) local e; e=$(config_get "SRE_DB_ENGINE" "none"); [[ "$e" == "none" ]] && return 0 ;;
        6) local v; v=$(config_get "SRE_NODE_VERSION" ""); [[ -z "$v" ]] && return 0 ;;
        0|9|10) return 0 ;; # block volume, SSH keys and migration are optional
    esac
    return 1
}

_is_step_optional() {
    local step="$1"
    [[ "$step" == "0" || "$step" == "9" || "$step" == "10" ]] && return 0
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
