#!/bin/bash
################################################################################
# SRE Helpers - Step 15: Bulk Migrate from cPanel/WHM Server
#
# Connects to a cPanel/WHM server, lists all hosted websites with details
# (account user, doc_root, project type, DB info), lets the user multi-select,
# then runs in TWO phases:
#
#   Phase 1 (transfer): for each selected site
#       - create vhost  (step 8)
#       - full migrate  (step 10 with MIG_SKIP_POST_SETUP=true)
#         → rsync files + create local DB + import DB
#         → post-migration tasks DEFERRED
#
#   Phase 2 (post-migration, after all transfers complete):
#       - per site: composer/npm/wp-config/permissions  (step 10 --mode post-only)
#       - per site: SSL via Let's Encrypt              (step 11)
#
# This split is intentional: long-running rsyncs and dumps run back-to-back
# without prompting, then the user reviews each site for finishing touches.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=15

BULK_SOURCE_HOST=""
BULK_SOURCE_USER="root"
BULK_SOURCE_PORT="22"
BULK_EMAIL=""
BULK_STATE_DIR="/etc/sre-helpers/bulk-migrations"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 15: Bulk Migrate from cPanel/WHM Server

  Lists all websites hosted on a cPanel/WHM server, lets you pick several,
  and migrates them in two phases (transfer first, post-setup + SSL after).

Prerequisites:
  - Web server  (step 3) installed
  - Database    (step 5) installed (only for sites that need a DB)
  - Source server reachable over SSH with key auth as root (or a user with
    read access to /etc/trueuserdomains and account home dirs)

Options:
  --source-host <host>   cPanel/WHM server IP or hostname
  --source-user <user>   SSH user on source (default: root)
  --source-port <port>   SSH port on source (default: 22)
  --email <addr>         Email for Let's Encrypt (asked once, used in phase 2)
  --dry-run              Print planned actions, don't execute
  --yes                  Accept defaults without prompting
  --config               Override config file path
  --log                  Override log file path
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --source-host whm.example.com --source-user root
EOF
}

_raw_args=("$@")
sre_parse_args "15-migrate-cpanel-bulk.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --source-host) _i=$((_i + 1)); BULK_SOURCE_HOST="${_raw_args[$_i]:-}" ;;
        --source-user) _i=$((_i + 1)); BULK_SOURCE_USER="${_raw_args[$_i]:-root}" ;;
        --source-port) _i=$((_i + 1)); BULK_SOURCE_PORT="${_raw_args[$_i]:-22}" ;;
        --email)       _i=$((_i + 1)); BULK_EMAIL="${_raw_args[$_i]:-}" ;;
    esac
    _i=$((_i + 1))
done

require_root

sre_header "Step 15: Bulk Migrate from cPanel/WHM Server"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
ws_installed=$(config_get "SRE_WEB_SERVER_INSTALLED" "")
db_engines_config=$(config_get "SRE_DB_ENGINE" "none")

if [[ "$ws_installed" != "true" && -z "$web_server" ]]; then
    sre_error "Web server not installed. Run step 3 first."
    exit 2
fi

mkdir -p "$BULK_STATE_DIR"

################################################################################
# Source server connection
################################################################################

sre_header "Source Server (cPanel/WHM)"

# Reuse hosts seen in earlier migrations as a convenience
prev_hosts=()
if [[ -d /etc/sre-helpers/migrations ]]; then
    while IFS= read -r _h; do
        [[ -n "$_h" ]] && prev_hosts+=("$_h")
    done < <(grep -h '^MIG_SOURCE_HOST=' /etc/sre-helpers/migrations/*.conf 2>/dev/null \
        | sed 's/^MIG_SOURCE_HOST="//' | sed 's/"$//' | sort -u)
fi
if [[ -d "$BULK_STATE_DIR" ]]; then
    while IFS= read -r _h; do
        [[ -n "$_h" ]] && prev_hosts+=("$_h")
    done < <(grep -h '^BULK_SOURCE_HOST=' "${BULK_STATE_DIR}"/*.conf 2>/dev/null \
        | sed 's/^BULK_SOURCE_HOST="//' | sed 's/"$//' | sort -u)
fi
# Dedupe
if [[ ${#prev_hosts[@]} -gt 0 ]]; then
    mapfile -t prev_hosts < <(printf '%s\n' "${prev_hosts[@]}" | sort -u)
fi

if [[ -z "$BULK_SOURCE_HOST" ]]; then
    if [[ ${#prev_hosts[@]} -gt 0 ]]; then
        sre_info "Previously used source hosts:"
        for _h in "${prev_hosts[@]}"; do
            sre_info "  - $_h"
        done
        echo ""
        host_choice=$(prompt_choice "Source server:" "use-previous" "enter-new")
        if [[ "$host_choice" == "use-previous" ]]; then
            if [[ ${#prev_hosts[@]} -eq 1 ]]; then
                BULK_SOURCE_HOST="${prev_hosts[0]}"
            else
                BULK_SOURCE_HOST=$(prompt_choice "Select host:" "${prev_hosts[@]}")
            fi
        else
            BULK_SOURCE_HOST=$(prompt_input "Source server IP or hostname" "")
        fi
    else
        BULK_SOURCE_HOST=$(prompt_input "Source server IP or hostname" "")
    fi
fi
[[ -z "$BULK_SOURCE_HOST" ]] && { sre_error "Source host is required."; exit 1; }

BULK_SOURCE_USER=$(prompt_input "SSH user on source (must read /etc/trueuserdomains and account homes)" "$BULK_SOURCE_USER")
BULK_SOURCE_PORT=$(prompt_input "SSH port on source" "$BULK_SOURCE_PORT")

sre_info "Source: ${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}:${BULK_SOURCE_PORT}"

# Test SSH
sre_info "Testing SSH connection..."
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         -p "$BULK_SOURCE_PORT" "${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}" "echo OK" &>/dev/null; then
        sre_error "Cannot connect to ${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}:${BULK_SOURCE_PORT}"
        sre_error "Try: ssh-copy-id -p ${BULK_SOURCE_PORT} ${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}"
        exit 1
    fi
    sre_success "SSH OK"
fi

# Convenience wrapper for SSH calls to the source
src_ssh() {
    ssh -p "$BULK_SOURCE_PORT" -o ConnectTimeout=15 \
        "${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}" "$@"
}

################################################################################
# List all websites on source
################################################################################

sre_header "Discovering Websites on Source Server"

# Each row: domain|user|home|doc_root|type|db_name|db_user|db_pass
# Build remote shell that emits this format. Handles WHM (listaccts) and falls
# back to /etc/trueuserdomains for addon/parked domains.
#
# Detection precedence (highest first):
#   1. wp-config.php   → wordpress  (parse DB_NAME/DB_USER/DB_PASSWORD)
#   2. config.php with $CFG->dbtype → moodle (parse dbname/dbuser/dbpass)
#   3. .env with DB_DATABASE → laravel (parse DB_DATABASE/DB_USERNAME/DB_PASSWORD)
#   4. nuxt.config.{js,ts,mjs} OR .output/server/index.* → nuxt
#   5. dist/index.html OR vue.config.* → vue
#   6. else → static

remote_lister=$(cat <<'REMOTE'
set -e

# Build list of "domain user home" rows
rows=""

# Try WHM first (gives main domains cleanly)
if [ -x /scripts/listaccts ] || command -v whmapi1 >/dev/null 2>&1; then
    if command -v whmapi1 >/dev/null 2>&1; then
        # whmapi1 listaccts | python parse — but stay POSIX: use awk on listaccts text
        accounts=$(/scripts/listaccts 2>/dev/null || true)
    else
        accounts=$(/scripts/listaccts 2>/dev/null || true)
    fi
    # /scripts/listaccts text output: lines like "user (uid)  user@email  domain.com  ..."
    # Best universal source is /etc/trueuserdomains (covers main + addon + parked)
fi

# /etc/trueuserdomains: "domain.tld: cpaneluser"
if [ -r /etc/trueuserdomains ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Format "domain: user"
        domain=$(echo "$line" | awk -F': *' '{print $1}')
        user=$(echo "$line" | awk -F': *' '{print $2}')
        [ -z "$domain" ] || [ -z "$user" ] && continue
        # Resolve home
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        [ -z "$home" ] && home="/home/$user"
        rows="${rows}${domain}|${user}|${home}"$'\n'
    done < /etc/trueuserdomains
elif [ -r /etc/userdomains ]; then
    # Older cPanel: same format
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        domain=$(echo "$line" | awk -F': *' '{print $1}')
        user=$(echo "$line" | awk -F': *' '{print $2}')
        [ -z "$domain" ] || [ -z "$user" ] && continue
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        [ -z "$home" ] && home="/home/$user"
        rows="${rows}${domain}|${user}|${home}"$'\n'
    done < /etc/userdomains
else
    echo "ERROR: Cannot read /etc/trueuserdomains or /etc/userdomains" >&2
    exit 2
fi

# For each row, find doc_root + detect type + extract DB creds
echo "$rows" | while IFS='|' read -r domain user home; do
    [ -z "$domain" ] && continue

    # cPanel userdata may give exact docroot; otherwise probe common locations
    doc_root=""
    if [ -r "/var/cpanel/userdata/${user}/${domain}" ]; then
        doc_root=$(awk -F': *' '$1=="documentroot"{print $2; exit}' \
            "/var/cpanel/userdata/${user}/${domain}" 2>/dev/null \
            | tr -d '"' | tr -d "'")
    fi
    if [ -z "$doc_root" ]; then
        # Try common cPanel layouts
        for cand in \
            "${home}/public_html" \
            "${home}/public_html/${domain}" \
            "${home}/${domain}" \
            "${home}/www/${domain}" \
            "${home}/public_html/$(echo "$domain" | sed 's/^www\.//')" ; do
            if [ -d "$cand" ]; then
                doc_root="$cand"
                break
            fi
        done
    fi
    [ -z "$doc_root" ] && doc_root="${home}/public_html"

    # Project root for migration (one level up from public/, or doc_root for moodle/wp/static)
    # We default project root = doc_root; downstream migrate adjusts (Laravel uses doc_root/.. semantics).
    proj_root="$doc_root"

    type="static"
    db_name=""; db_user=""; db_pass=""

    # WordPress
    if [ -f "${doc_root}/wp-config.php" ]; then
        type="wordpress"
        db_name=$(grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]?\K[^'\")]+" "${doc_root}/wp-config.php" | head -1 || true)
        db_user=$(grep -oP "define\(\s*['\"]DB_USER['\"]\s*,\s*['\"]?\K[^'\")]+" "${doc_root}/wp-config.php" | head -1 || true)
        db_pass=$(grep -oP "define\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]?\K[^'\")]+" "${doc_root}/wp-config.php" | head -1 || true)
    # Moodle
    elif [ -f "${doc_root}/config.php" ] && grep -q '\$CFG->dbtype' "${doc_root}/config.php" 2>/dev/null; then
        type="moodle"
        db_name=$(grep -oP "\\\$CFG->dbname\s*=\s*['\"]?\K[^'\";\s]+" "${doc_root}/config.php" | head -1 || true)
        db_user=$(grep -oP "\\\$CFG->dbuser\s*=\s*['\"]?\K[^'\";\s]+" "${doc_root}/config.php" | head -1 || true)
        db_pass=$(grep -oP "\\\$CFG->dbpass\s*=\s*['\"]?\K[^'\";\s]+" "${doc_root}/config.php" | head -1 || true)
    # Laravel: doc_root may be the public/ subdir; project root one level up
    elif [ -f "${doc_root}/../artisan" ] && [ -f "${doc_root}/../.env" ]; then
        type="laravel"
        proj_root="$(cd "${doc_root}/.." 2>/dev/null && pwd)"
        envf="${proj_root}/.env"
        db_name=$(grep -m1 '^DB_DATABASE=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
        db_user=$(grep -m1 '^DB_USERNAME=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
        db_pass=$(grep -m1 '^DB_PASSWORD=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
    elif [ -f "${doc_root}/artisan" ] && [ -f "${doc_root}/.env" ]; then
        type="laravel"
        proj_root="$doc_root"
        envf="${proj_root}/.env"
        db_name=$(grep -m1 '^DB_DATABASE=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
        db_user=$(grep -m1 '^DB_USERNAME=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
        db_pass=$(grep -m1 '^DB_PASSWORD=' "$envf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
    # Nuxt
    elif ls "${doc_root}"/nuxt.config.* 2>/dev/null | head -1 | grep -q .; then
        type="nuxt"
    elif [ -f "${doc_root}/.output/server/index.mjs" ] || [ -f "${doc_root}/.output/server/index.js" ]; then
        type="nuxt"
    # Vue (built SPA)
    elif [ -f "${doc_root}/dist/index.html" ] || ls "${doc_root}"/vue.config.* 2>/dev/null | head -1 | grep -q .; then
        type="vue"
    else
        # Last check: index.html only?
        if [ -f "${doc_root}/index.html" ] || [ -f "${doc_root}/index.htm" ]; then
            type="static"
        else
            type="static"
        fi
    fi

    # Pipe-encode values that might contain pipes (defensive)
    domain_e=$(printf '%s' "$domain" | tr '|' '_')
    user_e=$(printf '%s' "$user" | tr '|' '_')
    home_e=$(printf '%s' "$home" | tr '|' '_')
    doc_e=$(printf '%s' "$proj_root" | tr '|' '_')
    db_n_e=$(printf '%s' "$db_name" | tr '|' '_')
    db_u_e=$(printf '%s' "$db_user" | tr '|' '_')
    db_p_e=$(printf '%s' "$db_pass" | tr '|' '_')

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$domain_e" "$user_e" "$home_e" "$doc_e" "$type" "$db_n_e" "$db_u_e" "$db_p_e"
done
REMOTE
)

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] Would query source for account list and emit table."
    exit 0
fi

sre_info "Querying source server for accounts (this may take a moment)..."
discovery_out=$(src_ssh "bash -s" <<<"$remote_lister" 2>&1) || {
    sre_error "Discovery failed on source server:"
    echo "$discovery_out" >&2
    exit 1
}

# Parse rows
declare -a SITES_ROWS=()
while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    [[ "$row" == ERROR:* ]] && { sre_error "$row"; exit 2; }
    # Validate basic shape — must have 7 pipes
    pipe_count=$(awk -F'|' '{print NF-1}' <<<"$row")
    [[ "$pipe_count" -lt 7 ]] && continue
    SITES_ROWS+=("$row")
done <<<"$discovery_out"

if [[ ${#SITES_ROWS[@]} -eq 0 ]]; then
    sre_error "No websites discovered on source server."
    sre_error "Ensure ${BULK_SOURCE_USER} can read /etc/trueuserdomains."
    exit 1
fi

# Sort by domain
mapfile -t SITES_ROWS < <(printf '%s\n' "${SITES_ROWS[@]}" | sort -t'|' -k1,1)

################################################################################
# Render table + multi-select
################################################################################

sre_header "Discovered Websites (${#SITES_ROWS[@]})"

printf '  %-4s %-32s %-14s %-10s %-22s\n' "#" "DOMAIN" "USER" "TYPE" "DB"
printf '  %-4s %-32s %-14s %-10s %-22s\n' "----" "------------------------------" "-------------" "---------" "----------------------"
for i in "${!SITES_ROWS[@]}"; do
    IFS='|' read -r d u h r t dn du dp <<<"${SITES_ROWS[$i]}"
    db_summary="-"
    [[ -n "$dn" ]] && db_summary="$dn"
    [[ -n "$dn" && -n "$du" ]] && db_summary="${dn} (${du})"
    printf '  %-4s %-32s %-14s %-10s %-22s\n' "$((i+1))" "$d" "$u" "$t" "$db_summary"
done
echo ""

if [[ "$SRE_YES" == "true" ]]; then
    sre_error "Refusing to auto-select all sites in --yes mode. Re-run interactively."
    exit 1
fi

echo "Selection examples: 1,3,5-7   |   all   |   q to quit" >&2
SELECTED=()
while true; do
    read -r -p "Select sites to migrate: " sel
    sel="${sel// /}"
    [[ "$sel" == "q" || "$sel" == "Q" ]] && { sre_info "Cancelled."; exit 0; }
    [[ -z "$sel" ]] && { echo "Empty selection. Try again." >&2; continue; }

    if [[ "$sel" == "all" ]]; then
        for i in "${!SITES_ROWS[@]}"; do SELECTED+=("$i"); done
    else
        invalid=false
        IFS=',' read -ra parts <<<"$sel"
        for p in "${parts[@]}"; do
            if [[ "$p" =~ ^[0-9]+$ ]]; then
                idx=$((p-1))
                if (( idx < 0 || idx >= ${#SITES_ROWS[@]} )); then
                    echo "Out of range: $p" >&2; invalid=true; break
                fi
                SELECTED+=("$idx")
            elif [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                from=$((BASH_REMATCH[1]-1))
                to=$((BASH_REMATCH[2]-1))
                if (( from < 0 || to < 0 || from >= ${#SITES_ROWS[@]} || to >= ${#SITES_ROWS[@]} || from > to )); then
                    echo "Invalid range: $p" >&2; invalid=true; break
                fi
                for ((k=from; k<=to; k++)); do SELECTED+=("$k"); done
            else
                echo "Invalid token: $p" >&2; invalid=true; break
            fi
        done
        [[ "$invalid" == "true" ]] && { SELECTED=(); continue; }
    fi

    # Dedupe + sort
    mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | sort -un)
    [[ ${#SELECTED[@]} -gt 0 ]] && break
    echo "No valid selections. Try again." >&2
done

sre_success "Selected ${#SELECTED[@]} site(s)"
echo ""
sre_info "About to migrate:"
for idx in "${SELECTED[@]}"; do
    IFS='|' read -r d u h r t dn du dp <<<"${SITES_ROWS[$idx]}"
    sre_info "  • $d  ($t)  user=$u  src=$r"
done
echo ""

if ! prompt_yesno "Proceed with bulk migration?" "yes"; then
    sre_info "Cancelled."
    exit 0
fi

################################################################################
# Pre-flight: verify local DB engine compatibility
################################################################################

# Determine first available local engine and a usable mysql/mariadb engine
local_engines=()
IFS=',' read -ra _eng <<<"$db_engines_config"
for e in "${_eng[@]}"; do
    e=$(echo "$e" | tr -d ' ')
    [[ -n "$e" && "$e" != "none" ]] && local_engines+=("$e")
done

has_mysql_like=false
for e in "${local_engines[@]}"; do
    [[ "$e" == "mysql" || "$e" == "mariadb" ]] && has_mysql_like=true
done

needs_mysql_like=false
needs_any_db=false
for idx in "${SELECTED[@]}"; do
    IFS='|' read -r d u h r t dn du dp <<<"${SITES_ROWS[$idx]}"
    case "$t" in
        wordpress)         needs_mysql_like=true; needs_any_db=true ;;
        laravel|moodle)    needs_any_db=true ;;
    esac
done

if [[ "$needs_any_db" == "true" ]] && [[ ${#local_engines[@]} -eq 0 ]]; then
    sre_error "Selected sites need a database but no DB engine is installed locally (run step 5 first)."
    exit 2
fi
if [[ "$needs_mysql_like" == "true" ]] && [[ "$has_mysql_like" != "true" ]]; then
    sre_error "WordPress sites are selected but no MySQL/MariaDB is installed locally."
    sre_error "Either deselect WordPress sites or install MySQL/MariaDB (step 5)."
    exit 2
fi

################################################################################
# Bulk state file (for tracking)
################################################################################

bulk_run_id="$(date +%Y%m%d-%H%M%S)"
bulk_state_file="${BULK_STATE_DIR}/${bulk_run_id}.conf"
{
    echo "# Bulk migration run ${bulk_run_id}"
    echo "BULK_SOURCE_HOST=\"${BULK_SOURCE_HOST}\""
    echo "BULK_SOURCE_USER=\"${BULK_SOURCE_USER}\""
    echo "BULK_SOURCE_PORT=\"${BULK_SOURCE_PORT}\""
    echo "BULK_DOMAINS=\"$(for idx in "${SELECTED[@]}"; do IFS='|' read -r d _ _ _ _ _ _ _ <<<"${SITES_ROWS[$idx]}"; echo -n "$d "; done)\""
} > "$bulk_state_file"
sre_info "Bulk run state: $bulk_state_file"

################################################################################
# PHASE 1 — vhost + transfer (rsync + DB) for each selected site
# Post-setup is DEFERRED (MIG_SKIP_POST_SETUP=true).
################################################################################

sre_header "PHASE 1 — Transfer (vhost + rsync + DB)"

declare -a PHASE1_OK=()
declare -a PHASE1_FAIL=()

# Helper: pick local DB engine for a given site type, honoring availability
choose_db_engine_for_type() {
    local stype="$1"
    case "$stype" in
        wordpress)
            for e in "${local_engines[@]}"; do
                [[ "$e" == "mariadb" || "$e" == "mysql" ]] && { echo "$e"; return; }
            done
            ;;
        laravel|moodle)
            # Prefer mariadb > mysql > postgresql for migrate compatibility with sources
            for pref in mariadb mysql postgresql; do
                for e in "${local_engines[@]}"; do
                    [[ "$e" == "$pref" ]] && { echo "$e"; return; }
                done
            done
            ;;
    esac
    echo ""
}

# Pre-write per-domain migration state files so step 10 runs unattended via --yes.
# This replaces the interactive prompts with saved values.
prewrite_mig_state() {
    local domain="$1" type="$2" src_path="$3"
    local src_db_n="$4" src_db_u="$5" src_db_p="$6"
    local db_n="$7" db_u="$8" db_p="$9"
    local moodledata_src="${10:-}"
    local sf="/etc/sre-helpers/migrations/${domain}.conf"
    mkdir -p /etc/sre-helpers/migrations
    # Use printf %q so passwords with $ ` " etc. round-trip safely on source.
    {
        printf '# Pre-written by step 15 bulk migrate on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'MIG_DOMAIN=%q\n'              "${domain:-}"
        printf 'MIG_PROJECT_TYPE=%q\n'        "${type:-}"
        printf 'MIG_SOURCE_HOST=%q\n'         "${BULK_SOURCE_HOST:-}"
        printf 'MIG_SOURCE_USER=%q\n'         "${BULK_SOURCE_USER:-}"
        printf 'MIG_SOURCE_PORT=%q\n'         "${BULK_SOURCE_PORT:-22}"
        printf 'MIG_SOURCE_PATH=%q\n'         "${src_path:-}"
        printf 'MIG_SOURCE_MOODLEDATA=%q\n'   "${moodledata_src:-}"
        printf 'MIG_MOODLEDATA_DIR=%q\n'      ""
        printf 'MIG_SOURCE_DB_NAME=%q\n'      "${src_db_n:-}"
        printf 'MIG_SOURCE_DB_USER=%q\n'      "${src_db_u:-}"
        printf 'MIG_SOURCE_DB_PASS=%q\n'      "${src_db_p:-}"
        printf 'MIG_DB_NAME=%q\n'             "${db_n:-}"
        printf 'MIG_DB_USER=%q\n'             "${db_u:-}"
        printf 'MIG_DB_PASS=%q\n'             "${db_p:-}"
    } > "$sf"
    chmod 600 "$sf"
}

for idx in "${SELECTED[@]}"; do
    IFS='|' read -r domain user home src_path stype src_db_n src_db_u src_db_p <<<"${SITES_ROWS[$idx]}"

    sre_header "[Phase 1] ${domain} (${stype})"
    sre_info "  Source path:  $src_path"
    sre_info "  Source user:  $user"

    # ── (a) vhost (step 8) — idempotent, --yes overwrites if exists
    sre_info "Creating vhost..."
    vhost_args=(--domain "$domain" --type "$stype" --yes)
    if ! bash "${SRE_SCRIPTS_DIR}/vhost/08-vhost.sh" "${vhost_args[@]}"; then
        sre_error "vhost creation failed for $domain"
        PHASE1_FAIL+=("$domain")
        continue
    fi

    # ── (b) Resolve source DB credentials & decide local DB plan
    db_name_local=""; db_user_local=""; db_pass_local=""
    moodledata_src=""

    if [[ "$stype" == "moodle" ]]; then
        # Try to detect moodledata path via SSH probe of source config.php
        moodledata_src=$(src_ssh "grep -oP \"\\\\\\\$CFG->dataroot\\s*=\\s*['\\\"]?\\K[^'\\\";\\s]+\" '${src_path}/config.php' 2>/dev/null" 2>/dev/null || true)
        [[ -n "$moodledata_src" ]] && sre_info "  Detected moodledata: $moodledata_src"
    fi

    case "$stype" in
        laravel|moodle|wordpress)
            db_name_local="${src_db_n:-}"
            db_user_local="${src_db_u:-}"
            db_pass_local="${src_db_p:-}"
            if [[ -z "$db_name_local" ]]; then
                sre_warning "  No source DB credentials detected for $domain — prompting"
                src_db_n=$(prompt_input "  [$domain] source DB name" "")
                src_db_u=$(prompt_input "  [$domain] source DB user" "")
                src_db_p=$(prompt_input "  [$domain] source DB password" "")
                db_name_local="$src_db_n"
                db_user_local="$src_db_u"
                db_pass_local="$src_db_p"
            fi
            # Generate a safe local password (don't reuse source password by default)
            db_pass_local=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
            sre_info "  Local DB: ${db_name_local} (user: ${db_user_local}, generated password)"
            ;;
    esac

    # ── (c) Pre-write migration state so step 10 runs unattended
    prewrite_mig_state \
        "$domain" "$stype" "$src_path" \
        "$src_db_n" "$src_db_u" "$src_db_p" \
        "$db_name_local" "$db_user_local" "$db_pass_local" \
        "$moodledata_src"

    # ── (d) Invoke step 10 in full mode with post-setup deferred
    sre_info "Running step 10 (full migrate, post-setup deferred)..."
    mig_args=(
        --domain "$domain"
        --type   "$stype"
        --mode   full
        --source-host "$BULK_SOURCE_HOST"
        --source-user "$BULK_SOURCE_USER"
        --source-port "$BULK_SOURCE_PORT"
        --source-path "$src_path"
        --yes
    )

    if MIG_SKIP_POST_SETUP=true bash "${SRE_SCRIPTS_DIR}/migrate/10-migrate-cpanel.sh" "${mig_args[@]}"; then
        PHASE1_OK+=("$domain")
        sre_success "[Phase 1 ✓] $domain"
    else
        PHASE1_FAIL+=("$domain")
        sre_error "[Phase 1 ✗] $domain — see log; will skip in phase 2"
    fi
done

echo ""
sre_header "PHASE 1 Summary"
sre_info "  Transferred: ${#PHASE1_OK[@]} / ${#SELECTED[@]}"
[[ ${#PHASE1_OK[@]}   -gt 0 ]] && sre_success "  OK:   $(printf '%s ' "${PHASE1_OK[@]}")"
[[ ${#PHASE1_FAIL[@]} -gt 0 ]] && sre_error   "  FAIL: $(printf '%s ' "${PHASE1_FAIL[@]}")"

if [[ ${#PHASE1_OK[@]} -eq 0 ]]; then
    sre_error "Nothing to do in phase 2 — all transfers failed."
    exit 1
fi

################################################################################
# PHASE 2 — per-site post-migration tasks + SSL
################################################################################

sre_header "PHASE 2 — Post-Migration & SSL"

# Email for SSL — ask once, used for any site the user opts in for SSL
if [[ -z "$BULK_EMAIL" ]]; then
    BULK_EMAIL=$(prompt_input "Email for Let's Encrypt (used for any SSL setups in this phase)" "")
fi

declare -a PHASE2_DONE=()
declare -a PHASE2_SKIP=()

for domain in "${PHASE1_OK[@]}"; do
    sre_header "[Phase 2] ${domain}"

    # Show captured domain context briefly
    if [[ -f "/etc/sre-helpers/migrations/${domain}.conf" ]]; then
        # shellcheck source=/dev/null
        ( source "/etc/sre-helpers/migrations/${domain}.conf"
          sre_info "  Type: ${MIG_PROJECT_TYPE}"
          [[ -n "${MIG_DB_NAME:-}" ]] && sre_info "  DB:   ${MIG_DB_NAME} (user: ${MIG_DB_USER})"
        )
    fi

    # ── Post-migration setup (composer/npm/wp-config/perms) via step 10 post-only
    if prompt_yesno "Run post-migration setup for ${domain}?" "yes"; then
        if bash "${SRE_SCRIPTS_DIR}/migrate/10-migrate-cpanel.sh" \
                --domain "$domain" --mode post-only --yes; then
            sre_success "Post-migration done: $domain"
        else
            sre_error "Post-migration failed: $domain (continuing)"
        fi
    else
        sre_skipped "Post-migration: $domain"
    fi

    # ── SSL via step 11
    if prompt_yesno "Setup Let's Encrypt SSL for ${domain}?" "yes"; then
        if [[ -z "$BULK_EMAIL" ]]; then
            BULK_EMAIL=$(prompt_input "Email for Let's Encrypt" "")
        fi
        if [[ -z "$BULK_EMAIL" ]]; then
            sre_warning "No email provided — skipping SSL for $domain"
            PHASE2_SKIP+=("$domain (no SSL email)")
            continue
        fi
        if bash "${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh" \
                --domain "$domain" --email "$BULK_EMAIL" --yes; then
            sre_success "SSL issued: $domain"
            PHASE2_DONE+=("$domain (SSL)")
        else
            sre_warning "SSL failed for $domain (DNS may not point here yet)"
            PHASE2_SKIP+=("$domain (SSL failed)")
        fi
    else
        sre_skipped "SSL: $domain"
        PHASE2_DONE+=("$domain (no SSL)")
    fi
done

################################################################################
# Final summary
################################################################################

sre_header "Bulk Migration Complete"

sre_info "Run ID:        $bulk_run_id"
sre_info "State:         $bulk_state_file"
sre_info "Source server: ${BULK_SOURCE_USER}@${BULK_SOURCE_HOST}:${BULK_SOURCE_PORT}"
echo ""
sre_success "Phase 1 OK:    ${#PHASE1_OK[@]}"
[[ ${#PHASE1_FAIL[@]} -gt 0 ]] && sre_error "Phase 1 FAIL:  ${#PHASE1_FAIL[@]}  (${PHASE1_FAIL[*]})"
sre_success "Phase 2 done:  ${#PHASE2_DONE[@]}"
[[ ${#PHASE2_SKIP[@]} -gt 0 ]] && sre_warning "Phase 2 skip:  ${#PHASE2_SKIP[@]}"
echo ""
for s in "${PHASE2_DONE[@]}"; do sre_info "  ✓ $s"; done
for s in "${PHASE2_SKIP[@]}"; do sre_warning "  ! $s"; done
echo ""

sre_info "Per-site state: /etc/sre-helpers/migrations/{domain}.conf"
sre_info "Re-run a single site: sudo bash ${SRE_SCRIPTS_DIR}/migrate/10-migrate-cpanel.sh --domain <d> --mode <full|post-only>"

recommend_next_step "$CURRENT_STEP"
