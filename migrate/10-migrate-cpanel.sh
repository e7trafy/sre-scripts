#!/bin/bash
################################################################################
# SRE Helpers - Step 10: Migrate from cPanel/WHM Server
# Migrates a project from a cPanel/WHM server to a configured vhost.
# Handles: file rsync, database creation, database import, post-migration setup.
# Saves state per domain for re-runs.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=10

MIG_SOURCE_HOST=""
MIG_SOURCE_USER=""
MIG_SOURCE_PORT="22"
MIG_SOURCE_PATH=""
MIG_SOURCE_MOODLEDATA=""   # Moodle only: moodledata path on source server
MIG_DOMAIN=""
MIG_PROJECT_TYPE=""
MIG_DB_NAME=""
MIG_DB_USER=""
MIG_DB_PASS=""
MIG_SOURCE_DB_NAME=""
MIG_SOURCE_DB_USER=""
MIG_SOURCE_DB_PASS=""
MIG_MODE=""  # rsync-only, db-only, full

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 10: Migrate from cPanel/WHM Server
  Migrates a website from a cPanel/WHM server to a local vhost.
  Saves all entered data per domain so re-runs use previous values.

  Migration modes:
    full          - Rsync files + create DB + import DB + post-setup (default)
    rsync-only    - Only sync files, skip database
    db-only       - Only create DB + import, skip rsync

Prerequisites:
  - Virtual host (step 8) must exist for the domain
  - Database engine (step 5) must be installed (for DB migration)
  - SSH access to the source cPanel server

Options:
  --domain <name>        Domain to migrate (or pick from existing vhosts)
  --source-host <host>   Source cPanel server IP or hostname
  --source-user <user>   SSH user on source server (default: root)
  --source-port <port>   SSH port on source server (default: 22)
  --source-path <path>   Project root on source server
  --type <type>          Project type: laravel, moodle, nuxt, vue
  --mode <mode>          Migration mode: full, rsync-only, db-only
  --dry-run              Print planned actions without executing
  --yes                  Accept defaults without prompting
  --config               Override config file path
  --log                  Override log file path
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --domain app.example.com --mode rsync-only
  sudo bash $0 --domain app.example.com --mode db-only
EOF
}

################################################################################
# Migration state persistence (per domain)
################################################################################

MIG_STATE_DIR="/etc/sre-helpers/migrations"

_mig_state_file() {
    echo "${MIG_STATE_DIR}/${1}.conf"
}

mig_save_state() {
    mkdir -p "$MIG_STATE_DIR"
    local sf
    sf=$(_mig_state_file "$MIG_DOMAIN")
    cat > "$sf" <<STATE
# Migration state for ${MIG_DOMAIN}
# Saved on $(date '+%Y-%m-%d %H:%M:%S')
MIG_DOMAIN="${MIG_DOMAIN}"
MIG_PROJECT_TYPE="${MIG_PROJECT_TYPE}"
MIG_SOURCE_HOST="${MIG_SOURCE_HOST}"
MIG_SOURCE_USER="${MIG_SOURCE_USER}"
MIG_SOURCE_PORT="${MIG_SOURCE_PORT}"
MIG_SOURCE_PATH="${MIG_SOURCE_PATH}"
MIG_SOURCE_MOODLEDATA="${MIG_SOURCE_MOODLEDATA}"
MIG_SOURCE_DB_NAME="${MIG_SOURCE_DB_NAME}"
MIG_SOURCE_DB_USER="${MIG_SOURCE_DB_USER}"
MIG_SOURCE_DB_PASS="${MIG_SOURCE_DB_PASS}"
MIG_DB_NAME="${MIG_DB_NAME}"
MIG_DB_USER="${MIG_DB_USER}"
MIG_DB_PASS="${MIG_DB_PASS}"
STATE
    sre_info "Migration state saved to: $sf"
}

mig_load_state() {
    local sf
    sf=$(_mig_state_file "$1")
    if [[ -f "$sf" ]]; then
        # shellcheck source=/dev/null
        source "$sf"
        sre_success "Loaded saved migration state for $1"
        return 0
    fi
    return 1
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "10-migrate-cpanel.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)       ((_i++)); MIG_DOMAIN="${_raw_args[$_i]:-}" ;;
        --source-host)  ((_i++)); MIG_SOURCE_HOST="${_raw_args[$_i]:-}" ;;
        --source-user)  ((_i++)); MIG_SOURCE_USER="${_raw_args[$_i]:-}" ;;
        --source-port)  ((_i++)); MIG_SOURCE_PORT="${_raw_args[$_i]:-22}" ;;
        --source-path)  ((_i++)); MIG_SOURCE_PATH="${_raw_args[$_i]:-}" ;;
        --type)         ((_i++)); MIG_PROJECT_TYPE="${_raw_args[$_i]:-}" ;;
        --mode)         ((_i++)); MIG_MODE="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 10: Migrate from cPanel/WHM Server"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
db_engine=$(config_get "SRE_DB_ENGINE" "none")

################################################################################
# Select domain
################################################################################

sre_header "Select Domain to Migrate"

if [[ -z "$MIG_DOMAIN" ]]; then
    vhost_dir=$(get_vhost_dir "$web_server")
    if [[ ! -d "$vhost_dir" ]]; then
        sre_error "Vhost directory not found: $vhost_dir"
        sre_error "Run step 8 (vhost) first."
        exit 2
    fi

    vhost_domains=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        domain_name=$(basename "$f" .conf)
        [[ "$domain_name" == "default" || "$domain_name" == "000-default" || "$domain_name" == "security" ]] && continue
        vhost_domains+=("$domain_name")
    done < <(ls -1 "$vhost_dir"/*.conf 2>/dev/null)

    if [[ ${#vhost_domains[@]} -eq 0 ]]; then
        sre_error "No virtual hosts found. Run step 8 first."
        exit 2
    fi

    MIG_DOMAIN=$(prompt_choice "Select domain to migrate:" "${vhost_domains[@]}")
fi

sre_info "Domain: $MIG_DOMAIN"

# Verify vhost exists
vhost_conf_path="$(get_vhost_dir "$web_server")/${MIG_DOMAIN}.conf"
if [[ ! -f "$vhost_conf_path" ]]; then
    sre_error "Vhost config not found: $vhost_conf_path"
    exit 2
fi

################################################################################
# Load saved state (use as defaults if re-running)
################################################################################

saved_state_exists=false
if mig_load_state "$MIG_DOMAIN" 2>/dev/null; then
    saved_state_exists=true
    sre_info "Previous migration data found. Values will be used as defaults."
fi

################################################################################
# Migration mode
################################################################################

if [[ -z "$MIG_MODE" ]]; then
    MIG_MODE=$(prompt_choice "Migration mode:" "full" "rsync-only" "db-only")
fi

case "$MIG_MODE" in
    full|rsync-only|db-only) ;;
    *) sre_error "Invalid mode: $MIG_MODE (use: full, rsync-only, db-only)"; exit 1 ;;
esac

sre_info "Mode: $MIG_MODE"

do_rsync=false
do_db=false
case "$MIG_MODE" in
    full)       do_rsync=true; do_db=true ;;
    rsync-only) do_rsync=true ;;
    db-only)    do_db=true ;;
esac

################################################################################
# Project type
################################################################################

if [[ -z "$MIG_PROJECT_TYPE" ]]; then
    MIG_PROJECT_TYPE=$(prompt_choice "Project type:" "laravel" "moodle" "nuxt" "vue")
fi

case "$MIG_PROJECT_TYPE" in
    laravel|moodle|nuxt|vue) ;;
    *) sre_error "Invalid project type: $MIG_PROJECT_TYPE"; exit 1 ;;
esac

sre_info "Project type: $MIG_PROJECT_TYPE"

################################################################################
# Source server details (prompt with saved defaults)
################################################################################

sre_header "Source Server (cPanel/WHM)"

if [[ -z "$MIG_SOURCE_HOST" ]] || [[ "$saved_state_exists" == "true" && -z "${_raw_args[*]}" ]]; then
    MIG_SOURCE_HOST=$(prompt_input "Source server IP or hostname" "$MIG_SOURCE_HOST")
    [[ -z "$MIG_SOURCE_HOST" ]] && { sre_error "Source host is required."; exit 1; }
fi

if [[ -z "$MIG_SOURCE_USER" ]]; then
    MIG_SOURCE_USER=$(prompt_input "SSH user on source server" "${MIG_SOURCE_USER:-root}")
fi

MIG_SOURCE_PORT=$(prompt_input "SSH port on source server" "$MIG_SOURCE_PORT")

if [[ -z "$MIG_SOURCE_PATH" ]] || [[ "$saved_state_exists" == "true" && -z "${_raw_args[*]}" ]]; then
    MIG_SOURCE_PATH=$(prompt_input "Project root on source server (Moodle: web root e.g. /home/user/public_html/moodle)" "$MIG_SOURCE_PATH")
    [[ -z "$MIG_SOURCE_PATH" ]] && { sre_error "Source path is required."; exit 1; }
fi

# Moodle: ask for moodledata path on source (often outside web root)
if [[ "$MIG_PROJECT_TYPE" == "moodle" ]] && [[ "$do_rsync" == "true" ]]; then
    if [[ -z "$MIG_SOURCE_MOODLEDATA" ]]; then
        # Try to auto-detect from source config.php
        sre_info "Detecting moodledata path from source config.php..."
        detected_moodledata=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
            "grep -oP \"\\\\\\\$CFG->dataroot\s*=\s*['\\\"]?\K[^'\\\";\s]+\" ${MIG_SOURCE_PATH}/config.php 2>/dev/null" || true)
        [[ -n "$detected_moodledata" ]] && sre_success "Detected moodledata: $detected_moodledata"
        MIG_SOURCE_MOODLEDATA=$(prompt_input "Moodledata path on SOURCE server" "${detected_moodledata:-/home/$(echo "$MIG_SOURCE_USER")/moodledata}")
    fi
    sre_info "Source moodledata: $MIG_SOURCE_MOODLEDATA"
fi

sre_info "Source: ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PORT}"
sre_info "Source path: $MIG_SOURCE_PATH"

# Test SSH connection
sre_info "Testing SSH connection..."
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" "echo OK" &>/dev/null; then
        sre_error "Cannot connect to ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PORT}"
        sre_error "Ensure SSH key-based access is configured."
        sre_error "Try: ssh-copy-id -p ${MIG_SOURCE_PORT} ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}"
        exit 1
    fi
    sre_success "SSH connection OK"
fi

################################################################################
# Local paths
################################################################################

case "$MIG_PROJECT_TYPE" in
    laravel) local_root="/var/www/${MIG_DOMAIN}/current" ;;
    moodle)  local_root="/var/www/${MIG_DOMAIN}/public_html" ;;
    nuxt)    local_root="/var/www/${MIG_DOMAIN}/current" ;;
    vue)     local_root="/var/www/${MIG_DOMAIN}/current/dist" ;;
esac

# Moodle: moodledata must live OUTSIDE the web root
moodledata_dir="/var/www/${MIG_DOMAIN}/moodledata"

sre_info "Local root: $local_root"
[[ "$MIG_PROJECT_TYPE" == "moodle" ]] && sre_info "Moodledata: $moodledata_dir"

################################################################################
# Database credentials (only if doing DB migration)
################################################################################

needs_db=false
case "$MIG_PROJECT_TYPE" in
    laravel|moodle) [[ "$do_db" == "true" ]] && needs_db=true ;;
esac

if [[ "$needs_db" == "true" ]]; then
    if [[ "$db_engine" == "none" ]]; then
        sre_error "Project type $MIG_PROJECT_TYPE requires a database but no DB engine is installed."
        sre_error "Run step 5 first."
        exit 2
    fi

    sre_header "Database Credentials"

    # Auto-detect from source if not saved
    if [[ -z "$MIG_SOURCE_DB_NAME" ]] && [[ "$SRE_DRY_RUN" != "true" ]]; then
        sre_info "Detecting database credentials from source server..."
        case "$MIG_PROJECT_TYPE" in
            laravel)
                source_env=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "cat ${MIG_SOURCE_PATH}/.env 2>/dev/null" || true)
                if [[ -n "$source_env" ]]; then
                    MIG_SOURCE_DB_NAME=$(echo "$source_env" | grep -m1 "^DB_DATABASE=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    MIG_SOURCE_DB_USER=$(echo "$source_env" | grep -m1 "^DB_USERNAME=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    MIG_SOURCE_DB_PASS=$(echo "$source_env" | grep -m1 "^DB_PASSWORD=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    sre_success "Detected source DB: $MIG_SOURCE_DB_NAME (user: $MIG_SOURCE_DB_USER)"
                else
                    sre_warning "Could not read .env from source."
                fi
                ;;
            moodle)
                source_config=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "cat ${MIG_SOURCE_PATH}/config.php 2>/dev/null" || true)
                if [[ -n "$source_config" ]]; then
                    MIG_SOURCE_DB_NAME=$(echo "$source_config" | grep -oP "\\\$CFG->dbname\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    MIG_SOURCE_DB_USER=$(echo "$source_config" | grep -oP "\\\$CFG->dbuser\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    MIG_SOURCE_DB_PASS=$(echo "$source_config" | grep -oP "\\\$CFG->dbpass\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    sre_success "Detected source DB: $MIG_SOURCE_DB_NAME (user: $MIG_SOURCE_DB_USER)"
                else
                    sre_warning "Could not read config.php from source."
                fi
                ;;
        esac
    fi

    # Prompt with saved/detected values as defaults
    MIG_SOURCE_DB_NAME=$(prompt_input "Source database name" "$MIG_SOURCE_DB_NAME")
    [[ -z "$MIG_SOURCE_DB_NAME" ]] && { sre_error "Source database name is required."; exit 1; }
    MIG_SOURCE_DB_USER=$(prompt_input "Source database user" "$MIG_SOURCE_DB_USER")
    MIG_SOURCE_DB_PASS=$(prompt_input "Source database password" "$MIG_SOURCE_DB_PASS")

    sre_info ""
    sre_info "Local database credentials:"
    MIG_DB_NAME=$(prompt_input "Local database name" "${MIG_DB_NAME:-$MIG_SOURCE_DB_NAME}")
    MIG_DB_USER=$(prompt_input "Local database user" "${MIG_DB_USER:-$MIG_SOURCE_DB_USER}")
    MIG_DB_PASS=$(prompt_input "Local database password (empty to generate)" "${MIG_DB_PASS:-}")

    if [[ -z "$MIG_DB_PASS" ]]; then
        MIG_DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        sre_info "Generated DB password: $MIG_DB_PASS"
    fi
fi

# Save state now (before long operations)
mig_save_state

################################################################################
# RSYNC FILES
################################################################################

if [[ "$do_rsync" == "true" ]]; then
    sre_header "Syncing Files from Source"

    sre_info "From: ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}/"
    sre_info "To:   ${local_root}/"

    # Ask about exclusions
    rsync_excludes=()
    transfer_mode=$(prompt_choice "File transfer mode:" "smart-exclude" "transfer-all" "custom-exclude")

    case "$transfer_mode" in
        smart-exclude)
            rsync_excludes=(
                --exclude='.git'
                --exclude='node_modules'
                --exclude='vendor'
                --exclude='.env'
                --exclude='storage/logs/*'
                --exclude='storage/framework/cache/*'
                --exclude='storage/framework/sessions/*'
                --exclude='storage/framework/views/*'
                --exclude='.DS_Store'
                --exclude='Thumbs.db'
                --exclude='*.log'
            )
            sre_info "Excluding: .git, node_modules, vendor, .env, cache/logs"
            ;;
        transfer-all)
            sre_info "Transferring ALL files (no exclusions)"
            ;;
        custom-exclude)
            sre_info "Enter files/dirs to exclude (one per line, empty to finish):" >&2
            while true; do
                read -r -p "  Exclude: " exc_entry
                [[ -z "$exc_entry" ]] && break
                rsync_excludes+=("--exclude=${exc_entry}")
            done
            ;;
    esac

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        mkdir -p "$local_root"

        rsync -avz --progress \
            "${rsync_excludes[@]}" \
            -e "ssh -p ${MIG_SOURCE_PORT}" \
            "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}/" \
            "${local_root}/"

        sre_success "Files synced to: $local_root"

        # Moodle: also sync moodledata (separate from web root)
        if [[ "$MIG_PROJECT_TYPE" == "moodle" ]] && [[ -n "$MIG_SOURCE_MOODLEDATA" ]]; then
            sre_header "Syncing Moodledata from Source"
            sre_info "From: ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_MOODLEDATA}/"
            sre_info "To:   ${moodledata_dir}/"
            mkdir -p "$moodledata_dir"
            rsync -avz --progress \
                -e "ssh -p ${MIG_SOURCE_PORT}" \
                "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_MOODLEDATA}/" \
                "${moodledata_dir}/"
            sre_success "Moodledata synced to: $moodledata_dir"
        fi

        # Always fix ownership immediately after rsync — source UIDs won't exist on this server
        sre_info "Fixing file ownership (source UIDs replaced with www-data)..."
        chown -R www-data:www-data "/var/www/${MIG_DOMAIN}"
        sre_success "Ownership set: www-data:www-data on /var/www/${MIG_DOMAIN}"
    else
        sre_info "[DRY-RUN] Would rsync files to $local_root"
        [[ "$MIG_PROJECT_TYPE" == "moodle" ]] && sre_info "[DRY-RUN] Would rsync moodledata to $moodledata_dir"
    fi
else
    sre_skipped "File sync (mode: $MIG_MODE)"
fi

################################################################################
# CREATE DATABASE + USER
################################################################################

if [[ "$needs_db" == "true" ]]; then
    sre_header "Creating Local Database"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$db_engine" in
            mariadb|mysql)
                db_root_pass=""
                [[ -f /root/.db_root_password ]] && db_root_pass=$(cat /root/.db_root_password)

                mysql_cmd="mysql"
                [[ -n "$db_root_pass" ]] && mysql_cmd="mysql -u root -p${db_root_pass}"

                $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${MIG_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                sre_success "Database created: $MIG_DB_NAME"

                $mysql_cmd -e "CREATE USER IF NOT EXISTS '${MIG_DB_USER}'@'localhost' IDENTIFIED BY '${MIG_DB_PASS}';" 2>/dev/null
                $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${MIG_DB_NAME}\`.* TO '${MIG_DB_USER}'@'localhost';" 2>/dev/null
                $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null
                sre_success "Database user created: $MIG_DB_USER"
                ;;

            postgresql)
                sudo -u postgres psql -c "DO \$\$ BEGIN
                    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MIG_DB_USER}') THEN
                        CREATE ROLE ${MIG_DB_USER} WITH LOGIN PASSWORD '${MIG_DB_PASS}';
                    END IF;
                END \$\$;" 2>/dev/null
                sre_success "PostgreSQL user created: $MIG_DB_USER"

                if ! sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$MIG_DB_NAME"; then
                    sudo -u postgres createdb -O "$MIG_DB_USER" "$MIG_DB_NAME"
                fi
                sre_success "PostgreSQL database created: $MIG_DB_NAME"
                ;;
        esac
    else
        sre_info "[DRY-RUN] Would create database: $MIG_DB_NAME"
        sre_info "[DRY-RUN] Would create user: $MIG_DB_USER"
    fi

    ############################################################################
    # DUMP + IMPORT DATABASE
    ############################################################################

    sre_header "Importing Database from Source"

    dump_file="/tmp/migration_${MIG_SOURCE_DB_NAME}_$(date +%Y%m%d%H%M%S).sql"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        sre_info "Dumping database from source server..."
        sre_info "This may take a while for large databases..."

        case "$db_engine" in
            mariadb|mysql)
                sre_info "Testing SSH connection to source server..."
                ssh_test_out=$(ssh -p "$MIG_SOURCE_PORT" -o ConnectTimeout=10 \
                    "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" "echo SSH_OK" 2>&1)
                ssh_test_rc=$?
                if [[ $ssh_test_rc -ne 0 ]] || [[ "$ssh_test_out" != *"SSH_OK"* ]]; then
                    sre_error "Cannot connect to source server via SSH (exit: $ssh_test_rc)"
                    sre_error "SSH output: $ssh_test_out"
                    sre_error "Fix: ssh-copy-id -p ${MIG_SOURCE_PORT} ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}"
                    exit 1
                fi
                sre_success "SSH connection OK"

                sre_info "Verifying mysqldump on source server..."
                mysqldump_path=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "command -v mysqldump 2>/dev/null || which mysqldump 2>/dev/null || echo NOT_FOUND")
                if [[ "$mysqldump_path" == "NOT_FOUND" ]] || [[ -z "$mysqldump_path" ]]; then
                    sre_error "mysqldump not found on source server."
                    sre_error "Install it: apt install mysql-client  OR  yum install mysql"
                    exit 1
                fi
                sre_success "mysqldump found at: $mysqldump_path"

                sre_info "Dumping database from source (errors shown live)..."
                # Stream a self-contained shell script into bash via SSH stdin.
                # Credentials are passed only through the SSH-encrypted channel —
                # nothing is written to the remote filesystem.
                dump_err_file="/tmp/mysqldump_err_$$.txt"

                set +e
                ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "bash -s" <<REMOTE_DUMP > "$dump_file" 2>"$dump_err_file"
#!/bin/bash
# Write a per-process my.cnf into a private tmpdir only readable by this user
_tmpdir=\$(mktemp -d)
_cnf="\${_tmpdir}/.my.cnf"
chmod 700 "\${_tmpdir}"
cat > "\${_cnf}" <<CNF
[client]
user=${MIG_SOURCE_DB_USER}
password=${MIG_SOURCE_DB_PASS}
CNF
chmod 600 "\${_cnf}"
mysqldump --defaults-extra-file="\${_cnf}" \
    '${MIG_SOURCE_DB_NAME}' --single-transaction --quick
rc=\$?
rm -rf "\${_tmpdir}"
exit \$rc
REMOTE_DUMP
                dump_rc=$?
                set -e

                # Always show stderr if non-empty
                if [[ -s "$dump_err_file" ]]; then
                    sre_warning "Remote mysqldump messages:"
                    cat "$dump_err_file" >&2
                fi
                rm -f "$dump_err_file"

                if [[ $dump_rc -ne 0 ]] || [[ ! -s "$dump_file" ]]; then
                    dump_bytes=$(wc -c < "$dump_file" 2>/dev/null || echo 0)
                    sre_error "Database dump failed (exit: $dump_rc, bytes: $dump_bytes)"
                    sre_error ""
                    sre_error "Verify credentials on SOURCE server:"
                    sre_error "  mysql -u ${MIG_SOURCE_DB_USER} -p'<pass>' ${MIG_SOURCE_DB_NAME} -e 'SELECT 1;'"
                    sre_error ""
                    sre_error "Manual fallback:"
                    sre_error "  # On source:  mysqldump -u ${MIG_SOURCE_DB_USER} -p ${MIG_SOURCE_DB_NAME} > /tmp/dump.sql"
                    sre_error "  # Copy here:  scp -P ${MIG_SOURCE_PORT} ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:/tmp/dump.sql ${dump_file}"
                    sre_error "  # Import:     ${mysql_cmd} ${MIG_DB_NAME} < ${dump_file}"
                    rm -f "$dump_file"
                    exit 1
                fi

                dump_size=$(du -h "$dump_file" | cut -f1)
                sre_success "Database dump downloaded: $dump_file ($dump_size)"

                sre_info "Importing into local database..."
                $mysql_cmd "$MIG_DB_NAME" < "$dump_file"
                sre_success "Database imported: $MIG_DB_NAME"
                ;;

            postgresql)
                sre_info "Testing SSH connection to source server..."
                if ! ssh -p "$MIG_SOURCE_PORT" -o ConnectTimeout=10 -o BatchMode=yes \
                        "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" "echo SSH_OK" 2>&1 | grep -q "SSH_OK"; then
                    sre_error "Cannot connect to source server via SSH."
                    exit 1
                fi
                sre_success "SSH connection OK"

                sre_info "Dumping PostgreSQL database from source..."
                { ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "PGPASSWORD='${MIG_SOURCE_DB_PASS}' pg_dump -U '${MIG_SOURCE_DB_USER}' '${MIG_SOURCE_DB_NAME}'" \
                    > "$dump_file"; } 2>&1
                dump_rc=${PIPESTATUS[0]:-$?}

                if [[ $dump_rc -ne 0 ]] || [[ ! -s "$dump_file" ]]; then
                    sre_error "PostgreSQL dump failed (exit: $dump_rc)"
                    rm -f "$dump_file"
                    exit 1
                fi

                dump_size=$(du -h "$dump_file" | cut -f1)
                sre_success "Database dump downloaded: $dump_file ($dump_size)"

                sre_info "Importing into local database..."
                sudo -u postgres psql "$MIG_DB_NAME" < "$dump_file" >/dev/null
                sre_success "Database imported: $MIG_DB_NAME"
                ;;
        esac

        if prompt_yesno "Remove dump file ($dump_file)?" "yes"; then
            rm -f "$dump_file"
            sre_info "Dump file removed"
        else
            sre_info "Dump file kept at: $dump_file"
        fi
    else
        sre_info "[DRY-RUN] Would dump source DB and import into $MIG_DB_NAME"
    fi
else
    if [[ "$do_db" == "true" ]] && [[ "$MIG_PROJECT_TYPE" == "nuxt" || "$MIG_PROJECT_TYPE" == "vue" ]]; then
        sre_skipped "No database needed for $MIG_PROJECT_TYPE projects"
    elif [[ "$do_db" == "false" ]]; then
        sre_skipped "Database migration (mode: $MIG_MODE)"
    fi
fi

################################################################################
# POST-MIGRATION SETUP
################################################################################

sre_header "Post-Migration Setup"

if prompt_yesno "Run post-migration setup? (composer install, config, permissions)" "yes"; then
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    case "$MIG_PROJECT_TYPE" in
        laravel)
            sre_info "Configuring Laravel..."

            if [[ ! -f "${local_root}/.env" ]]; then
                if [[ -f "${local_root}/.env.example" ]]; then
                    cp "${local_root}/.env.example" "${local_root}/.env"
                    sre_info "Created .env from .env.example"
                else
                    touch "${local_root}/.env"
                    sre_info "Created empty .env"
                fi
            fi

            if [[ "$needs_db" == "true" ]]; then
                sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${MIG_DB_NAME}|" "${local_root}/.env"
                sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${MIG_DB_USER}|" "${local_root}/.env"
                sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${MIG_DB_PASS}|" "${local_root}/.env"
                sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "${local_root}/.env"
                sre_success "Updated .env with local database credentials"
            fi

            sed -i "s|^APP_URL=.*|APP_URL=http://${MIG_DOMAIN}|" "${local_root}/.env"

            mkdir -p "${local_root}/storage"/{app/public,framework/{cache,sessions,views},logs}

            if command -v composer &>/dev/null; then
                sre_info "Installing Composer dependencies..."
                cd "$local_root" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -3
                sre_success "Composer dependencies installed"
            fi

            if ! grep -q "^APP_KEY=base64:" "${local_root}/.env" 2>/dev/null; then
                cd "$local_root" && php artisan key:generate --no-interaction
                sre_success "Application key generated"
            fi

            cd "$local_root"
            php artisan config:cache --no-interaction 2>/dev/null || true
            php artisan route:cache --no-interaction 2>/dev/null || true
            php artisan view:cache --no-interaction 2>/dev/null || true
            sre_success "Laravel caches rebuilt"
            ;;

        moodle)
            sre_info "Configuring Moodle..."

            mkdir -p "$moodledata_dir"

            # Detect table prefix from source config if available
            source_prefix=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                "grep -oP \"\\\\\$CFG->prefix\s*=\s*['\\\"]?\K[^'\\\";\s]+\" ${MIG_SOURCE_PATH}/config.php 2>/dev/null" || true)
            moodle_prefix="${source_prefix:-mdl_}"

            [[ -f "${local_root}/config.php" ]] && cp "${local_root}/config.php" "${local_root}/config.php.bak"

            # Determine dbtype for config.php (mariadb -> mysqli, postgresql -> pgsql)
            case "$db_engine" in
                mariadb|mysql) moodle_dbtype="mysqli" ;;
                postgresql)    moodle_dbtype="pgsql" ;;
                *)             moodle_dbtype="mysqli" ;;
            esac

            cat > "${local_root}/config.php" <<MOODLE_CONFIG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = '${moodle_dbtype}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${MIG_DB_NAME}';
\$CFG->dbuser    = '${MIG_DB_USER}';
\$CFG->dbpass    = '${MIG_DB_PASS}';
\$CFG->prefix    = '${moodle_prefix}';

\$CFG->wwwroot   = 'http://${MIG_DOMAIN}';
\$CFG->dataroot  = '${moodledata_dir}';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0770;

require_once(__DIR__ . '/lib/setup.php');
MOODLE_CONFIG
            sre_success "Moodle config.php written (dbtype: $moodle_dbtype, prefix: $moodle_prefix)"
            sre_info "  wwwroot:  http://${MIG_DOMAIN}"
            sre_info "  dataroot: ${moodledata_dir}"

            # Update wwwroot in database to match new domain
            if [[ "$needs_db" == "true" ]]; then
                sre_info "Updating wwwroot in Moodle database..."
                $mysql_cmd "$MIG_DB_NAME" -e \
                    "UPDATE \`${moodle_prefix}config\` SET value='http://${MIG_DOMAIN}' WHERE name='wwwroot';" 2>/dev/null \
                    && sre_success "DB wwwroot updated to http://${MIG_DOMAIN}" \
                    || sre_warning "Could not update wwwroot in DB (may need manual update)"
            fi
            ;;

        nuxt)
            sre_info "Configuring Nuxt..."
            if [[ -f "${local_root}/package.json" ]]; then
                cd "$local_root"
                sre_info "Installing Node dependencies..."
                npm install --production 2>&1 | tail -3
                npm run build 2>&1 | tail -5
                sre_success "Nuxt built"

                if command -v pm2 &>/dev/null; then
                    pm2 delete "${MIG_DOMAIN}" 2>/dev/null || true
                    pm2 start npm --name "${MIG_DOMAIN}" -- start
                    pm2 save
                    sre_success "PM2 process started: ${MIG_DOMAIN}"
                fi
            fi
            ;;

        vue)
            sre_info "Configuring Vue..."
            if [[ -f "${local_root}/../package.json" ]]; then
                cd "${local_root}/.."
                npm install 2>&1 | tail -3
                npm run build 2>&1 | tail -5
                sre_success "Vue built to dist/"
            fi
            ;;
    esac

    # Fix permissions using POSIX ACLs
    sre_header "Fixing Permissions (POSIX ACL)"

    if ! command -v setfacl &>/dev/null; then
        sre_info "Installing ACL utilities..."
        pkg_install acl
    fi

    project_dir="/var/www/${MIG_DOMAIN}"

    # Base ownership
    chown -R www-data:www-data "$project_dir"
    sre_success "Ownership: www-data:www-data"

    # Base permissions
    find "$project_dir" -type d -exec chmod 755 {} \;
    find "$project_dir" -type f -exec chmod 644 {} \;
    sre_success "Base: dirs=755, files=644"

    # Default ACLs for inheritance
    setfacl -R -m d:u:www-data:rwX "$project_dir"
    setfacl -R -m u:www-data:rwX "$project_dir"
    setfacl -R -m d:u:root:rwX "$project_dir"
    setfacl -R -m u:root:rwX "$project_dir"
    sre_success "Default ACL: www-data + root have rwX"

    # Project-type-specific
    case "$MIG_PROJECT_TYPE" in
        laravel)
            for wd in "${local_root}/storage" "${local_root}/bootstrap/cache"; do
                if [[ -d "$wd" ]]; then
                    chmod -R 775 "$wd"
                    setfacl -R -m u:www-data:rwX "$wd"
                    setfacl -R -m d:u:www-data:rwX "$wd"
                    setfacl -R -m g:www-data:rwX "$wd"
                    setfacl -R -m d:g:www-data:rwX "$wd"
                fi
            done
            sre_success "Laravel: storage + bootstrap/cache ACL rwX"

            if [[ -f "${local_root}/.env" ]]; then
                chmod 640 "${local_root}/.env"
                setfacl -m u:www-data:r-- "${local_root}/.env"
                sre_success ".env: 640, www-data read-only"
            fi
            ;;

        moodle)
            if [[ -d "$moodledata_dir" ]]; then
                chmod -R 775 "$moodledata_dir"
                setfacl -R -m u:www-data:rwX "$moodledata_dir"
                setfacl -R -m d:u:www-data:rwX "$moodledata_dir"
                setfacl -R -m g:www-data:rwX "$moodledata_dir"
                setfacl -R -m d:g:www-data:rwX "$moodledata_dir"
                sre_success "Moodledata: ACL rwX"
            fi
            if [[ -f "${local_root}/config.php" ]]; then
                chmod 640 "${local_root}/config.php"
                setfacl -m u:www-data:r-- "${local_root}/config.php"
                sre_success "config.php: 640, www-data read-only"
            fi
            ;;

        nuxt)
            for wd in "${local_root}/.nuxt" "${local_root}/.output" "${local_root}/node_modules"; do
                [[ -d "$wd" ]] && setfacl -R -m u:www-data:rwX "$wd" && setfacl -R -m d:u:www-data:rwX "$wd"
            done
            sre_success "Nuxt build dirs: ACL rwX"
            ;;

        vue)
            sre_success "Vue: static files, read-only OK"
            ;;
    esac

    sre_info "ACL summary:"
    getfacl "$project_dir" 2>/dev/null | grep -E "^(user|group|default)" | head -10

    # Reload web server
    case "$web_server" in
        nginx) svc_reload nginx ;;
        apache)
            case "$os_family" in
                debian) svc_reload apache2 ;;
                rhel)   svc_reload httpd ;;
            esac
            ;;
    esac
    sre_success "Web server reloaded"
else
    sre_info "[DRY-RUN] Would configure $MIG_PROJECT_TYPE and fix permissions"
fi
else
    sre_skipped "Post-migration setup (user skipped)"
    sre_info "You can re-run with post-setup later:"
    sre_info "  sudo bash $0 --domain $MIG_DOMAIN --mode full"
fi

# Save final state
mig_save_state

################################################################################
# Summary
################################################################################

sre_header "Migration Summary"

sre_success "Migration complete for $MIG_DOMAIN"
echo ""
sre_info "  Domain:       $MIG_DOMAIN"
sre_info "  Project type: $MIG_PROJECT_TYPE"
sre_info "  Mode:         $MIG_MODE"
sre_info "  Local root:   $local_root"
if [[ "$needs_db" == "true" ]]; then
    sre_info "  Database:     $MIG_DB_NAME"
    sre_info "  DB User:      $MIG_DB_USER"
    sre_info "  DB Password:  $MIG_DB_PASS"
fi
sre_info "  Source:       ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}"
sre_info "  State saved:  $(_mig_state_file "$MIG_DOMAIN")"
echo ""
if [[ "$needs_db" == "true" ]]; then
    sre_warning "Save these database credentials!"
    echo ""
fi
sre_info "To re-run specific parts:"
sre_info "  Files only: sudo bash $0 --domain $MIG_DOMAIN --mode rsync-only"
sre_info "  DB only:    sudo bash $0 --domain $MIG_DOMAIN --mode db-only"
echo ""

recommend_next_step "$CURRENT_STEP"
