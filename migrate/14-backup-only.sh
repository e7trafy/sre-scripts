#!/bin/bash
################################################################################
# SRE Helpers - Step 14: Backup-Only Capture (No Restore)
# Captures a remote site's files + database into compressed archives.
# Does NOT restore anything, does NOT need a local vhost or database engine.
# Output goes to /var/backups/sre-helpers/{domain}/{timestamp}/
#
# Use this when you need a portable snapshot of a site for archival, transfer,
# or later restore — without committing to migrating it onto this server.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=14

BK_DOMAIN=""
BK_SOURCE_HOST=""
BK_SOURCE_USER="root"
BK_SOURCE_PORT="22"
BK_SOURCE_PATH=""
BK_SOURCE_EXTRA_PATH=""   # e.g. moodledata for Moodle
BK_DB_TYPE=""             # mysql/mariadb/postgresql/none
BK_DB_NAME=""
BK_DB_USER=""
BK_DB_PASS=""
BK_DB_HOST="localhost"
BK_OUTPUT_DIR=""
BK_MODE="full"            # full, files-only, db-only

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 14: Backup-Only Capture (no restore)
  Captures a remote site's files and database into compressed archives.
  Does NOT restore, does NOT need a local vhost or DB engine.

  Output: /var/backups/sre-helpers/{domain}/{timestamp}/
    - {domain}_{ts}_files.tar.gz
    - {domain}_{ts}_db.sql.gz       (if DB included)
    - {domain}_{ts}_manifest.txt    (metadata)

  Modes:
    full         Files + database (default)
    files-only   Files only, skip database
    db-only      Database only, skip files

Options:
  --domain <name>        Domain (used for backup folder name) — required
  --source-host <host>   Source server IP or hostname — required
  --source-user <user>   SSH user on source (default: root)
  --source-port <port>   SSH port (default: 22)
  --source-path <path>   Files path on source server (e.g. /home/user/public_html)
  --extra-path <path>    Extra path to bundle (e.g. moodledata)
  --db-type <type>       Source DB type: mysql, mariadb, postgresql
  --db-name <name>       Source database name
  --db-user <user>       Source database user
  --db-pass <pass>       Source database password
  --db-host <host>       Source DB host (default: localhost on source)
  --output <dir>         Output directory (default: /var/backups/sre-helpers/{domain}/{ts})
  --mode <mode>          Backup mode: full, files-only, db-only
  --dry-run              Print planned actions
  --yes                  Accept defaults
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --domain old.example.com --source-host 1.2.3.4 \\
              --source-path /home/user/public_html --db-type mysql \\
              --db-name oldsite_db --db-user oldsite --db-pass secret
  sudo bash $0 --domain assets.example.com --mode files-only \\
              --source-host 1.2.3.4 --source-path /var/www/html
EOF
}

################################################################################
# State persistence (per domain)
################################################################################

BK_STATE_DIR="/etc/sre-helpers/backups"

_bk_state_file() {
    echo "${BK_STATE_DIR}/${1}.conf"
}

bk_save_state() {
    mkdir -p "$BK_STATE_DIR"
    local sf
    sf=$(_bk_state_file "$BK_DOMAIN")
    cat > "$sf" <<STATE
# Backup-only state for ${BK_DOMAIN}
# Saved on $(date '+%Y-%m-%d %H:%M:%S')
BK_DOMAIN="${BK_DOMAIN}"
BK_SOURCE_HOST="${BK_SOURCE_HOST}"
BK_SOURCE_USER="${BK_SOURCE_USER}"
BK_SOURCE_PORT="${BK_SOURCE_PORT}"
BK_SOURCE_PATH="${BK_SOURCE_PATH}"
BK_SOURCE_EXTRA_PATH="${BK_SOURCE_EXTRA_PATH}"
BK_DB_TYPE="${BK_DB_TYPE}"
BK_DB_NAME="${BK_DB_NAME}"
BK_DB_USER="${BK_DB_USER}"
BK_DB_PASS="${BK_DB_PASS}"
BK_DB_HOST="${BK_DB_HOST}"
STATE
    sre_info "Backup state saved to: $sf"
}

bk_load_state() {
    local sf
    sf=$(_bk_state_file "$1")
    if [[ -f "$sf" ]]; then
        # shellcheck source=/dev/null
        source "$sf"
        sre_success "Loaded saved backup state for $1"
        return 0
    fi
    return 1
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "14-backup-only.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)        ((_i++)); BK_DOMAIN="${_raw_args[$_i]:-}" ;;
        --source-host)   ((_i++)); BK_SOURCE_HOST="${_raw_args[$_i]:-}" ;;
        --source-user)   ((_i++)); BK_SOURCE_USER="${_raw_args[$_i]:-root}" ;;
        --source-port)   ((_i++)); BK_SOURCE_PORT="${_raw_args[$_i]:-22}" ;;
        --source-path)   ((_i++)); BK_SOURCE_PATH="${_raw_args[$_i]:-}" ;;
        --extra-path)    ((_i++)); BK_SOURCE_EXTRA_PATH="${_raw_args[$_i]:-}" ;;
        --db-type)       ((_i++)); BK_DB_TYPE="${_raw_args[$_i]:-}" ;;
        --db-name)       ((_i++)); BK_DB_NAME="${_raw_args[$_i]:-}" ;;
        --db-user)       ((_i++)); BK_DB_USER="${_raw_args[$_i]:-}" ;;
        --db-pass)       ((_i++)); BK_DB_PASS="${_raw_args[$_i]:-}" ;;
        --db-host)       ((_i++)); BK_DB_HOST="${_raw_args[$_i]:-localhost}" ;;
        --output)        ((_i++)); BK_OUTPUT_DIR="${_raw_args[$_i]:-}" ;;
        --mode)          ((_i++)); BK_MODE="${_raw_args[$_i]:-full}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 14: Backup-Only Capture (No Restore)"

################################################################################
# Mode
################################################################################

case "$BK_MODE" in
    full|files-only|db-only) ;;
    *) sre_error "Invalid mode: $BK_MODE (use: full, files-only, db-only)"; exit 1 ;;
esac

do_files=false
do_db=false
case "$BK_MODE" in
    full)        do_files=true; do_db=true ;;
    files-only)  do_files=true ;;
    db-only)     do_db=true ;;
esac

################################################################################
# Domain
################################################################################

if [[ -z "$BK_DOMAIN" ]]; then
    # If a previous backup state exists, offer to pick from it
    prev_domains=()
    if [[ -d "$BK_STATE_DIR" ]]; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            prev_domains+=("$(basename "$f" .conf)")
        done < <(ls -1 "$BK_STATE_DIR"/*.conf 2>/dev/null)
    fi

    if [[ ${#prev_domains[@]} -gt 0 ]]; then
        domain_choice=$(prompt_choice "Domain:" "${prev_domains[@]}" "enter-new")
        if [[ "$domain_choice" != "enter-new" ]]; then
            BK_DOMAIN="$domain_choice"
        fi
    fi

    if [[ -z "$BK_DOMAIN" ]]; then
        BK_DOMAIN=$(prompt_input "Domain (used for backup folder name)" "")
    fi
fi
[[ -z "$BK_DOMAIN" ]] && { sre_error "Domain is required."; exit 1; }
sre_info "Domain: $BK_DOMAIN"

################################################################################
# Load saved state
################################################################################

saved_state_exists=false
if bk_load_state "$BK_DOMAIN" 2>/dev/null; then
    saved_state_exists=true
    sre_info "Previous backup data found. Values will be used as defaults."
fi

################################################################################
# Source server (only needed if files mode)
################################################################################

if [[ "$do_files" == "true" ]] || [[ "$do_db" == "true" ]]; then
    sre_header "Source Server"

    BK_SOURCE_HOST=$(prompt_input "Source server IP or hostname" "$BK_SOURCE_HOST")
    [[ -z "$BK_SOURCE_HOST" ]] && { sre_error "Source host is required."; exit 1; }

    BK_SOURCE_USER=$(prompt_input "SSH user on source" "${BK_SOURCE_USER:-root}")
    BK_SOURCE_PORT=$(prompt_input "SSH port on source" "$BK_SOURCE_PORT")

    sre_info "Source: ${BK_SOURCE_USER}@${BK_SOURCE_HOST}:${BK_SOURCE_PORT}"

    # Test SSH
    sre_info "Testing SSH connection..."
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" "echo OK" &>/dev/null; then
            sre_error "Cannot connect to ${BK_SOURCE_USER}@${BK_SOURCE_HOST}:${BK_SOURCE_PORT}"
            sre_error "Ensure SSH key-based access is set up:"
            sre_error "  ssh-copy-id -p ${BK_SOURCE_PORT} ${BK_SOURCE_USER}@${BK_SOURCE_HOST}"
            exit 1
        fi
        sre_success "SSH connection OK"
    fi
fi

################################################################################
# Files path
################################################################################

if [[ "$do_files" == "true" ]]; then
    BK_SOURCE_PATH=$(prompt_input "Files path on source server (web root)" "$BK_SOURCE_PATH")
    [[ -z "$BK_SOURCE_PATH" ]] && { sre_error "Source path is required for file backup."; exit 1; }

    if prompt_yesno "Include an extra path? (e.g. moodledata, separate uploads dir)" "no"; then
        BK_SOURCE_EXTRA_PATH=$(prompt_input "Extra path on source" "$BK_SOURCE_EXTRA_PATH")
    fi
fi

################################################################################
# Database details
################################################################################

if [[ "$do_db" == "true" ]]; then
    sre_header "Source Database"

    if [[ -z "$BK_DB_TYPE" ]]; then
        BK_DB_TYPE=$(prompt_choice "Source database type:" "mysql" "mariadb" "postgresql" "skip")
    fi

    if [[ "$BK_DB_TYPE" == "skip" ]]; then
        do_db=false
        sre_info "Skipping database backup"
    else
        case "$BK_DB_TYPE" in
            mysql|mariadb|postgresql) ;;
            *) sre_error "Invalid db type: $BK_DB_TYPE"; exit 1 ;;
        esac

        BK_DB_NAME=$(prompt_input "Source database name" "$BK_DB_NAME")
        [[ -z "$BK_DB_NAME" ]] && { sre_error "Database name is required."; exit 1; }

        BK_DB_USER=$(prompt_input "Source database user" "$BK_DB_USER")
        [[ -z "$BK_DB_USER" ]] && { sre_error "Database user is required."; exit 1; }

        BK_DB_PASS=$(prompt_input "Source database password" "$BK_DB_PASS")
        BK_DB_HOST=$(prompt_input "Source database host (on source server)" "${BK_DB_HOST:-localhost}")

        sre_info "Database: $BK_DB_NAME (type: $BK_DB_TYPE, user: $BK_DB_USER)"
    fi
fi

################################################################################
# Output directory
################################################################################

backup_ts=$(date +%Y%m%d-%H%M%S)
if [[ -z "$BK_OUTPUT_DIR" ]]; then
    BK_OUTPUT_DIR="/var/backups/sre-helpers/${BK_DOMAIN}/${backup_ts}"
fi
sre_info "Output: $BK_OUTPUT_DIR"

# Save state before long operations
bk_save_state

################################################################################
# Summary + confirmation
################################################################################

sre_header "Backup Summary"

sre_info "Domain:      $BK_DOMAIN"
sre_info "Mode:        $BK_MODE"
sre_info "Source:      ${BK_SOURCE_USER}@${BK_SOURCE_HOST}:${BK_SOURCE_PORT}"
[[ "$do_files" == "true" ]] && sre_info "Files path:  $BK_SOURCE_PATH"
[[ -n "$BK_SOURCE_EXTRA_PATH" ]] && sre_info "Extra path:  $BK_SOURCE_EXTRA_PATH"
[[ "$do_db" == "true" ]] && sre_info "Database:    $BK_DB_NAME (${BK_DB_TYPE})"
sre_info "Output:      $BK_OUTPUT_DIR"

if ! prompt_yesno "Proceed with backup?" "yes"; then
    sre_info "Backup cancelled."
    exit 0
fi

################################################################################
# Create output dir
################################################################################

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    mkdir -p "$BK_OUTPUT_DIR"
    chmod 700 "$BK_OUTPUT_DIR"
fi

# Filename prefix
prefix="${BK_DOMAIN}_${backup_ts}"
files_archive="${BK_OUTPUT_DIR}/${prefix}_files.tar.gz"
extra_archive="${BK_OUTPUT_DIR}/${prefix}_extra.tar.gz"
db_dump="${BK_OUTPUT_DIR}/${prefix}_db.sql.gz"
manifest="${BK_OUTPUT_DIR}/${prefix}_manifest.txt"

################################################################################
# FILES BACKUP
################################################################################

if [[ "$do_files" == "true" ]]; then
    sre_header "Capturing Files"

    sre_info "Source: ${BK_SOURCE_USER}@${BK_SOURCE_HOST}:${BK_SOURCE_PATH}"
    sre_info "Output: $files_archive"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        # Verify source path exists
        if ! ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
             "[ -d '${BK_SOURCE_PATH}' ]"; then
            sre_error "Source path does not exist on remote: $BK_SOURCE_PATH"
            exit 1
        fi

        # Stream tar+gzip from source -> local file (no temp on source)
        sre_info "Streaming compressed archive from source (this may take a while)..."

        # cd into parent so the archive contains a meaningful directory name
        src_parent=$(dirname "$BK_SOURCE_PATH")
        src_base=$(basename "$BK_SOURCE_PATH")

        set +e
        ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
            "cd '${src_parent}' && tar -czf - '${src_base}'" > "$files_archive" 2>/tmp/bk_files_err_$$
        tar_rc=$?
        set -e

        if [[ $tar_rc -ne 0 ]] || [[ ! -s "$files_archive" ]]; then
            sre_error "File archive failed (exit: $tar_rc)"
            [[ -s /tmp/bk_files_err_$$ ]] && cat /tmp/bk_files_err_$$ >&2
            rm -f /tmp/bk_files_err_$$ "$files_archive"
            exit 1
        fi
        rm -f /tmp/bk_files_err_$$

        files_size=$(du -h "$files_archive" | cut -f1)
        sre_success "Files archive: $files_archive ($files_size)"

        # Extra path
        if [[ -n "$BK_SOURCE_EXTRA_PATH" ]]; then
            sre_info "Capturing extra path: $BK_SOURCE_EXTRA_PATH"

            if ! ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
                 "[ -d '${BK_SOURCE_EXTRA_PATH}' ]"; then
                sre_warning "Extra path does not exist on remote: $BK_SOURCE_EXTRA_PATH (skipping)"
            else
                extra_parent=$(dirname "$BK_SOURCE_EXTRA_PATH")
                extra_base=$(basename "$BK_SOURCE_EXTRA_PATH")

                set +e
                ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
                    "cd '${extra_parent}' && tar -czf - '${extra_base}'" > "$extra_archive" 2>/tmp/bk_extra_err_$$
                extra_rc=$?
                set -e

                if [[ $extra_rc -ne 0 ]] || [[ ! -s "$extra_archive" ]]; then
                    sre_error "Extra archive failed (exit: $extra_rc)"
                    [[ -s /tmp/bk_extra_err_$$ ]] && cat /tmp/bk_extra_err_$$ >&2
                    rm -f /tmp/bk_extra_err_$$ "$extra_archive"
                else
                    extra_size=$(du -h "$extra_archive" | cut -f1)
                    sre_success "Extra archive: $extra_archive ($extra_size)"
                fi
                rm -f /tmp/bk_extra_err_$$
            fi
        fi
    else
        sre_info "[DRY-RUN] Would stream tar.gz from $BK_SOURCE_PATH to $files_archive"
        [[ -n "$BK_SOURCE_EXTRA_PATH" ]] && sre_info "[DRY-RUN] Would also archive $BK_SOURCE_EXTRA_PATH"
    fi
fi

################################################################################
# DATABASE BACKUP
################################################################################

if [[ "$do_db" == "true" ]]; then
    sre_header "Capturing Database"

    sre_info "Database: $BK_DB_NAME (type: $BK_DB_TYPE)"
    sre_info "Output:   $db_dump"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$BK_DB_TYPE" in
            mysql|mariadb)
                # Verify mysqldump available on source
                mysqldump_path=$(ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
                    "command -v mysqldump 2>/dev/null || echo NOT_FOUND")
                if [[ "$mysqldump_path" == "NOT_FOUND" ]] || [[ -z "$mysqldump_path" ]]; then
                    sre_error "mysqldump not found on source server."
                    sre_error "Install: apt install mysql-client  OR  yum install mysql"
                    exit 1
                fi
                sre_success "mysqldump found at: $mysqldump_path"

                sre_info "Streaming compressed dump from source..."

                dump_err_file="/tmp/bk_dump_err_$$"

                set +e
                # Stream to a here-doc'd remote script: write a private my.cnf,
                # mysqldump | gzip, capture and forward to local file
                ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
                    "bash -s" <<REMOTE_DUMP > "$db_dump" 2>"$dump_err_file"
#!/bin/bash
_tmpdir=\$(mktemp -d)
_cnf="\${_tmpdir}/.my.cnf"
chmod 700 "\${_tmpdir}"
cat > "\${_cnf}" <<CNF
[client]
host=${BK_DB_HOST}
user=${BK_DB_USER}
password=${BK_DB_PASS}
CNF
chmod 600 "\${_cnf}"
mysqldump --defaults-extra-file="\${_cnf}" \
    '${BK_DB_NAME}' --single-transaction --quick --routines --triggers --events \
    | gzip -c
rc=\${PIPESTATUS[0]}
rm -rf "\${_tmpdir}"
exit \$rc
REMOTE_DUMP
                dump_rc=$?
                set -e

                if [[ -s "$dump_err_file" ]]; then
                    sre_warning "Remote mysqldump messages:"
                    cat "$dump_err_file" >&2
                fi
                rm -f "$dump_err_file"

                if [[ $dump_rc -ne 0 ]] || [[ ! -s "$db_dump" ]]; then
                    sre_error "Database dump failed (exit: $dump_rc)"
                    sre_error ""
                    sre_error "Verify on SOURCE server:"
                    sre_error "  mysql -h ${BK_DB_HOST} -u ${BK_DB_USER} -p'<pass>' ${BK_DB_NAME} -e 'SELECT 1;'"
                    rm -f "$db_dump"
                    exit 1
                fi
                ;;

            postgresql)
                sre_info "Streaming PostgreSQL dump from source..."
                set +e
                ssh -p "$BK_SOURCE_PORT" "${BK_SOURCE_USER}@${BK_SOURCE_HOST}" \
                    "PGPASSWORD='${BK_DB_PASS}' pg_dump -h '${BK_DB_HOST}' -U '${BK_DB_USER}' '${BK_DB_NAME}' | gzip -c" \
                    > "$db_dump" 2>/tmp/bk_pg_err_$$
                dump_rc=$?
                set -e

                if [[ -s /tmp/bk_pg_err_$$ ]]; then
                    sre_warning "Remote pg_dump messages:"
                    cat /tmp/bk_pg_err_$$ >&2
                fi
                rm -f /tmp/bk_pg_err_$$

                if [[ $dump_rc -ne 0 ]] || [[ ! -s "$db_dump" ]]; then
                    sre_error "PostgreSQL dump failed (exit: $dump_rc)"
                    rm -f "$db_dump"
                    exit 1
                fi
                ;;
        esac

        db_size=$(du -h "$db_dump" | cut -f1)
        sre_success "Database dump: $db_dump ($db_size)"
    else
        sre_info "[DRY-RUN] Would dump $BK_DB_NAME to $db_dump"
    fi
fi

################################################################################
# WRITE MANIFEST
################################################################################

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    sre_header "Writing Manifest"

    {
        echo "# SRE Helpers — Backup-Only Manifest"
        echo "# Captured on $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo ""
        echo "Domain:        $BK_DOMAIN"
        echo "Mode:          $BK_MODE"
        echo "Backup ts:     $backup_ts"
        echo "Output dir:    $BK_OUTPUT_DIR"
        echo ""
        echo "Source server: ${BK_SOURCE_USER}@${BK_SOURCE_HOST}:${BK_SOURCE_PORT}"
        if [[ "$do_files" == "true" ]]; then
            echo "Source path:   $BK_SOURCE_PATH"
            [[ -n "$BK_SOURCE_EXTRA_PATH" ]] && echo "Extra path:    $BK_SOURCE_EXTRA_PATH"
        fi
        if [[ "$do_db" == "true" ]]; then
            echo "DB type:       $BK_DB_TYPE"
            echo "DB name:       $BK_DB_NAME"
            echo "DB user:       $BK_DB_USER"
            echo "DB host:       $BK_DB_HOST"
        fi
        echo ""
        echo "# Artifacts"
        if [[ -f "$files_archive" ]]; then
            echo "Files:    $(basename "$files_archive")    $(du -h "$files_archive" | cut -f1)    sha256:$(sha256sum "$files_archive" | cut -d' ' -f1)"
        fi
        if [[ -f "$extra_archive" ]]; then
            echo "Extra:    $(basename "$extra_archive")    $(du -h "$extra_archive" | cut -f1)    sha256:$(sha256sum "$extra_archive" | cut -d' ' -f1)"
        fi
        if [[ -f "$db_dump" ]]; then
            echo "Database: $(basename "$db_dump")    $(du -h "$db_dump" | cut -f1)    sha256:$(sha256sum "$db_dump" | cut -d' ' -f1)"
        fi
        echo ""
        echo "# Restore hints"
        echo "# Files:    tar -xzf $(basename "$files_archive") -C /target/path"
        if [[ "$do_db" == "true" ]]; then
            case "$BK_DB_TYPE" in
                mysql|mariadb)
                    echo "# Database: gunzip -c $(basename "$db_dump") | mysql <newdb>"
                    ;;
                postgresql)
                    echo "# Database: gunzip -c $(basename "$db_dump") | psql <newdb>"
                    ;;
            esac
        fi
    } > "$manifest"

    chmod 600 "$manifest"
    sre_success "Manifest written: $manifest"
fi

################################################################################
# Summary
################################################################################

sre_header "Backup Complete"

sre_info "Output directory: $BK_OUTPUT_DIR"
if [[ "$SRE_DRY_RUN" != "true" ]] && [[ -d "$BK_OUTPUT_DIR" ]]; then
    total_size=$(du -sh "$BK_OUTPUT_DIR" 2>/dev/null | cut -f1)
    sre_info "Total size:       $total_size"
    sre_info ""
    sre_info "Contents:"
    ls -lh "$BK_OUTPUT_DIR" | tail -n +2 | awk '{print "  " $0}'
fi

sre_success "Backup-only capture complete for $BK_DOMAIN"

recommend_next_step "$CURRENT_STEP"
