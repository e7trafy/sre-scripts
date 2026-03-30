#!/bin/bash
################################################################################
# SRE Helpers - Step 9: Migrate from cPanel/WHM Server
# Migrates a project from a cPanel/WHM server to a configured vhost.
# Handles: file rsync, database creation, database import, post-migration setup.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=9

MIG_SOURCE_HOST=""
MIG_SOURCE_USER=""
MIG_SOURCE_PORT="22"
MIG_SOURCE_PATH=""
MIG_DOMAIN=""
MIG_PROJECT_TYPE=""
MIG_DB_NAME=""
MIG_DB_USER=""
MIG_DB_PASS=""
MIG_SOURCE_DB_NAME=""
MIG_SOURCE_DB_USER=""
MIG_SOURCE_DB_PASS=""

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 9: Migrate from cPanel/WHM Server
  Migrates a website from a cPanel/WHM server to a local vhost.
  Steps: rsync files, create database + user, import database dump,
  update configuration, fix permissions.

Prerequisites:
  - Virtual host (step 8) must exist for the domain
  - Database engine (step 5) must be installed
  - SSH access to the source cPanel server (key-based recommended)

Options:
  --domain <name>        Domain to migrate (or pick from existing vhosts)
  --source-host <host>   Source cPanel server IP or hostname
  --source-user <user>   SSH user on source server (default: root)
  --source-port <port>   SSH port on source server (default: 22)
  --source-path <path>   Project root on source server (e.g., /home/user/public_html)
  --type <type>          Project type: laravel, moodle, nuxt, vue
  --dry-run              Print planned actions without executing
  --yes                  Accept defaults without prompting
  --config               Override config file path
  --log                  Override log file path
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --domain app.example.com --source-host 1.2.3.4 --source-path /home/appuser/public_html --type laravel
EOF
}

# Parse script-specific args
_raw_args=("$@")
sre_parse_args "09-migrate-cpanel.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)       ((_i++)); MIG_DOMAIN="${_raw_args[$_i]:-}" ;;
        --source-host)  ((_i++)); MIG_SOURCE_HOST="${_raw_args[$_i]:-}" ;;
        --source-user)  ((_i++)); MIG_SOURCE_USER="${_raw_args[$_i]:-}" ;;
        --source-port)  ((_i++)); MIG_SOURCE_PORT="${_raw_args[$_i]:-22}" ;;
        --source-path)  ((_i++)); MIG_SOURCE_PATH="${_raw_args[$_i]:-}" ;;
        --type)         ((_i++)); MIG_PROJECT_TYPE="${_raw_args[$_i]:-}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 9: Migrate from cPanel/WHM Server"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
db_engine=$(config_get "SRE_DB_ENGINE" "none")

################################################################################
# Step 1: Select vhost / domain
################################################################################

sre_header "Select Domain to Migrate"

if [[ -z "$MIG_DOMAIN" ]]; then
    # List available vhosts
    vhost_dir=$(get_vhost_dir "$web_server")
    if [[ ! -d "$vhost_dir" ]]; then
        sre_error "Vhost directory not found: $vhost_dir"
        sre_error "Run step 8 (vhost) first to create a virtual host."
        exit 2
    fi

    # Collect vhost files
    vhost_files=()
    vhost_domains=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        domain_name=$(basename "$f" .conf)
        # Skip default configs
        [[ "$domain_name" == "default" || "$domain_name" == "000-default" || "$domain_name" == "security" ]] && continue
        vhost_files+=("$f")
        vhost_domains+=("$domain_name")
    done < <(ls -1 "$vhost_dir"/*.conf 2>/dev/null)

    if [[ ${#vhost_domains[@]} -eq 0 ]]; then
        sre_error "No virtual hosts found in $vhost_dir"
        sre_error "Run step 8 (vhost) first to create a virtual host."
        exit 2
    fi

    sre_info "Available virtual hosts:"
    MIG_DOMAIN=$(prompt_choice "Select domain to migrate:" "${vhost_domains[@]}")
fi

sre_info "Domain: $MIG_DOMAIN"

# Verify vhost exists
vhost_conf_path="$(get_vhost_dir "$web_server")/${MIG_DOMAIN}.conf"
if [[ ! -f "$vhost_conf_path" ]]; then
    sre_error "Vhost config not found: $vhost_conf_path"
    sre_error "Run step 8 first: sudo bash ${SRE_SCRIPTS_DIR}/vhost/08-vhost.sh --domain $MIG_DOMAIN"
    exit 2
fi

################################################################################
# Step 2: Project type
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
# Step 3: Source server details
################################################################################

sre_header "Source Server (cPanel/WHM)"

if [[ -z "$MIG_SOURCE_HOST" ]]; then
    MIG_SOURCE_HOST=$(prompt_input "Source server IP or hostname" "")
    [[ -z "$MIG_SOURCE_HOST" ]] && { sre_error "Source host is required."; exit 1; }
fi

if [[ -z "$MIG_SOURCE_USER" ]]; then
    MIG_SOURCE_USER=$(prompt_input "SSH user on source server" "root")
fi

MIG_SOURCE_PORT=$(prompt_input "SSH port on source server" "$MIG_SOURCE_PORT")

if [[ -z "$MIG_SOURCE_PATH" ]]; then
    MIG_SOURCE_PATH=$(prompt_input "Project root path on source server (e.g., /home/user/public_html)" "")
    [[ -z "$MIG_SOURCE_PATH" ]] && { sre_error "Source path is required."; exit 1; }
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
else
    sre_info "[DRY-RUN] Would test SSH connection"
fi

################################################################################
# Step 4: Determine local paths
################################################################################

case "$MIG_PROJECT_TYPE" in
    laravel) local_root="/var/www/${MIG_DOMAIN}/current" ;;
    moodle)  local_root="/var/www/${MIG_DOMAIN}/current" ;;
    nuxt)    local_root="/var/www/${MIG_DOMAIN}/current" ;;
    vue)     local_root="/var/www/${MIG_DOMAIN}/current/dist" ;;
esac

sre_info "Local root: $local_root"

################################################################################
# Step 5: Detect source database credentials
################################################################################

sre_header "Database Migration"

needs_db=false
case "$MIG_PROJECT_TYPE" in
    laravel|moodle) needs_db=true ;;
esac

if [[ "$needs_db" == "true" ]]; then
    if [[ "$db_engine" == "none" ]]; then
        sre_error "Project type $MIG_PROJECT_TYPE requires a database but no DB engine is installed."
        sre_error "Run step 5 first: sudo bash ${SRE_SCRIPTS_DIR}/stack/05-database.sh"
        exit 2
    fi

    sre_info "Detecting database credentials from source server..."

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$MIG_PROJECT_TYPE" in
            laravel)
                # Read .env from source
                source_env=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "cat ${MIG_SOURCE_PATH}/.env 2>/dev/null" || true)

                if [[ -n "$source_env" ]]; then
                    MIG_SOURCE_DB_NAME=$(echo "$source_env" | grep -m1 "^DB_DATABASE=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    MIG_SOURCE_DB_USER=$(echo "$source_env" | grep -m1 "^DB_USERNAME=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    MIG_SOURCE_DB_PASS=$(echo "$source_env" | grep -m1 "^DB_PASSWORD=" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                    sre_success "Detected source DB: $MIG_SOURCE_DB_NAME (user: $MIG_SOURCE_DB_USER)"
                else
                    sre_warning "Could not read .env from source. Manual input required."
                fi
                ;;
            moodle)
                # Read config.php from source
                source_config=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "cat ${MIG_SOURCE_PATH}/config.php 2>/dev/null" || true)

                if [[ -n "$source_config" ]]; then
                    MIG_SOURCE_DB_NAME=$(echo "$source_config" | grep -oP "\\\$CFG->dbname\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    MIG_SOURCE_DB_USER=$(echo "$source_config" | grep -oP "\\\$CFG->dbuser\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    MIG_SOURCE_DB_PASS=$(echo "$source_config" | grep -oP "\\\$CFG->dbpass\s*=\s*['\"]?\K[^'\";\s]+" | head -1)
                    sre_success "Detected source DB: $MIG_SOURCE_DB_NAME (user: $MIG_SOURCE_DB_USER)"
                else
                    sre_warning "Could not read config.php from source. Manual input required."
                fi
                ;;
        esac
    fi

    # Prompt for anything not auto-detected
    if [[ -z "$MIG_SOURCE_DB_NAME" ]]; then
        MIG_SOURCE_DB_NAME=$(prompt_input "Source database name" "")
        [[ -z "$MIG_SOURCE_DB_NAME" ]] && { sre_error "Source database name is required."; exit 1; }
    fi
    if [[ -z "$MIG_SOURCE_DB_USER" ]]; then
        MIG_SOURCE_DB_USER=$(prompt_input "Source database user" "")
    fi
    if [[ -z "$MIG_SOURCE_DB_PASS" ]]; then
        MIG_SOURCE_DB_PASS=$(prompt_input "Source database password" "")
    fi

    # New local database credentials
    sre_info ""
    sre_info "Configure local database credentials:"
    MIG_DB_NAME=$(prompt_input "Local database name" "$MIG_SOURCE_DB_NAME")
    MIG_DB_USER=$(prompt_input "Local database user" "$MIG_SOURCE_DB_USER")
    MIG_DB_PASS=$(prompt_input "Local database password (leave empty to generate)" "")

    if [[ -z "$MIG_DB_PASS" ]]; then
        MIG_DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        sre_info "Generated DB password: $MIG_DB_PASS"
    fi
fi

################################################################################
# Step 6: Rsync files from source
################################################################################

sre_header "Syncing Files from Source"

sre_info "Syncing: ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}/ -> ${local_root}/"

# Ask about file exclusions
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
        sre_info "Enter files/directories to exclude (one per line, empty line to finish):"
        while true; do
            read -r -p "  Exclude: " exc_entry
            [[ -z "$exc_entry" ]] && break
            rsync_excludes+=("--exclude=${exc_entry}")
            sre_info "  Added exclusion: $exc_entry"
        done
        if [[ ${#rsync_excludes[@]} -eq 0 ]]; then
            sre_info "No exclusions set, transferring all files"
        else
            sre_info "Total exclusions: ${#rsync_excludes[@]}"
        fi
        ;;
esac

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    mkdir -p "$local_root"

    rsync -avz --progress \
        "${rsync_excludes[@]}" \
        -e "ssh -p ${MIG_SOURCE_PORT}" \
        "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}/" \
        "${local_root}/"

    sre_success "Files synced successfully"
else
    sre_info "[DRY-RUN] Would rsync from ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}/ to ${local_root}/"
    if [[ ${#rsync_excludes[@]} -gt 0 ]]; then
        sre_info "[DRY-RUN] Excludes: ${rsync_excludes[*]}"
    fi
fi

################################################################################
# Step 7: Create database and user
################################################################################

if [[ "$needs_db" == "true" ]]; then
    sre_header "Creating Local Database"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$db_engine" in
            mariadb|mysql)
                # Read root password
                db_root_pass=""
                if [[ -f /root/.db_root_password ]]; then
                    db_root_pass=$(cat /root/.db_root_password)
                fi

                mysql_cmd="mysql"
                [[ -n "$db_root_pass" ]] && mysql_cmd="mysql -u root -p${db_root_pass}"

                # Create database
                $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${MIG_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                sre_success "Database created: $MIG_DB_NAME"

                # Create user and grant privileges
                $mysql_cmd -e "CREATE USER IF NOT EXISTS '${MIG_DB_USER}'@'localhost' IDENTIFIED BY '${MIG_DB_PASS}';" 2>/dev/null
                $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${MIG_DB_NAME}\`.* TO '${MIG_DB_USER}'@'localhost';" 2>/dev/null
                $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null
                sre_success "Database user created: $MIG_DB_USER"
                ;;

            postgresql)
                # Create user
                sudo -u postgres psql -c "DO \$\$ BEGIN
                    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MIG_DB_USER}') THEN
                        CREATE ROLE ${MIG_DB_USER} WITH LOGIN PASSWORD '${MIG_DB_PASS}';
                    END IF;
                END \$\$;" 2>/dev/null
                sre_success "PostgreSQL user created: $MIG_DB_USER"

                # Create database
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
    # Step 8: Dump and import database
    ############################################################################

    sre_header "Importing Database from Source"

    dump_file="/tmp/migration_${MIG_SOURCE_DB_NAME}_$(date +%Y%m%d%H%M%S).sql"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        sre_info "Dumping database from source server..."

        case "$db_engine" in
            mariadb|mysql)
                ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "mysqldump -u '${MIG_SOURCE_DB_USER}' -p'${MIG_SOURCE_DB_PASS}' '${MIG_SOURCE_DB_NAME}' --single-transaction --quick" \
                    > "$dump_file" 2>/dev/null

                if [[ ! -s "$dump_file" ]]; then
                    sre_error "Database dump is empty or failed."
                    sre_error "Verify source credentials and try manually:"
                    sre_error "  ssh -p ${MIG_SOURCE_PORT} ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST} 'mysqldump -u ${MIG_SOURCE_DB_USER} -p ${MIG_SOURCE_DB_NAME}' > dump.sql"
                    exit 1
                fi

                dump_size=$(du -h "$dump_file" | cut -f1)
                sre_success "Database dump downloaded: $dump_file ($dump_size)"

                sre_info "Importing into local database..."
                $mysql_cmd "$MIG_DB_NAME" < "$dump_file"
                sre_success "Database imported: $MIG_DB_NAME"
                ;;

            postgresql)
                ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                    "PGPASSWORD='${MIG_SOURCE_DB_PASS}' pg_dump -U '${MIG_SOURCE_DB_USER}' '${MIG_SOURCE_DB_NAME}'" \
                    > "$dump_file" 2>/dev/null

                if [[ ! -s "$dump_file" ]]; then
                    sre_error "Database dump is empty or failed."
                    exit 1
                fi

                dump_size=$(du -h "$dump_file" | cut -f1)
                sre_success "Database dump downloaded: $dump_file ($dump_size)"

                sre_info "Importing into local database..."
                sudo -u postgres psql "$MIG_DB_NAME" < "$dump_file" >/dev/null
                sre_success "Database imported: $MIG_DB_NAME"
                ;;
        esac

        # Clean up dump file
        if prompt_yesno "Remove dump file ($dump_file)?" "yes"; then
            rm -f "$dump_file"
            sre_info "Dump file removed"
        else
            sre_info "Dump file kept at: $dump_file"
        fi
    else
        sre_info "[DRY-RUN] Would dump source DB and import into $MIG_DB_NAME"
    fi
fi

################################################################################
# Step 9: Post-migration setup
################################################################################

sre_header "Post-Migration Setup"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    case "$MIG_PROJECT_TYPE" in
        laravel)
            sre_info "Configuring Laravel..."

            # Create .env if not exists
            if [[ ! -f "${local_root}/.env" ]]; then
                if [[ -f "${local_root}/.env.example" ]]; then
                    cp "${local_root}/.env.example" "${local_root}/.env"
                    sre_info "Created .env from .env.example"
                else
                    touch "${local_root}/.env"
                    sre_info "Created empty .env"
                fi
            fi

            # Update database credentials in .env
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${MIG_DB_NAME}|" "${local_root}/.env"
            sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${MIG_DB_USER}|" "${local_root}/.env"
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${MIG_DB_PASS}|" "${local_root}/.env"
            sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "${local_root}/.env"
            sed -i "s|^APP_URL=.*|APP_URL=http://${MIG_DOMAIN}|" "${local_root}/.env"
            sre_success "Updated .env with local database credentials"

            # Create storage structure
            mkdir -p "${local_root}/storage"/{app/public,framework/{cache,sessions,views},logs}
            sre_info "Storage directories created"

            # Install dependencies
            if command -v composer &>/dev/null; then
                sre_info "Installing Composer dependencies..."
                cd "$local_root" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -3
                sre_success "Composer dependencies installed"
            fi

            # Generate app key if needed
            if ! grep -q "^APP_KEY=base64:" "${local_root}/.env" 2>/dev/null; then
                cd "$local_root" && php artisan key:generate --no-interaction
                sre_success "Application key generated"
            fi

            # Clear and cache
            cd "$local_root"
            php artisan config:cache --no-interaction 2>/dev/null || true
            php artisan route:cache --no-interaction 2>/dev/null || true
            php artisan view:cache --no-interaction 2>/dev/null || true
            sre_success "Laravel caches cleared and rebuilt"
            ;;

        moodle)
            sre_info "Configuring Moodle..."

            # Update config.php
            if [[ -f "${local_root}/config.php" ]]; then
                backup_config "${local_root}/config.php"
            fi

            moodledata_dir="/var/www/${MIG_DOMAIN}/moodledata"
            mkdir -p "$moodledata_dir"

            cat > "${local_root}/config.php" <<MOODLE_CONFIG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = '${db_engine}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${MIG_DB_NAME}';
\$CFG->dbuser    = '${MIG_DB_USER}';
\$CFG->dbpass    = '${MIG_DB_PASS}';
\$CFG->prefix    = 'mdl_';

\$CFG->wwwroot   = 'http://${MIG_DOMAIN}';
\$CFG->dataroot  = '${moodledata_dir}';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');
MOODLE_CONFIG
            sre_success "Moodle config.php created"

            # Sync moodledata if exists on source
            sre_info "Checking for moodledata on source..."
            source_moodledata=$(ssh -p "$MIG_SOURCE_PORT" "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}" \
                "grep -oP \"dataroot\\s*=\\s*['\\\"]?\\K[^'\\\";\s]+\" ${MIG_SOURCE_PATH}/config.php 2>/dev/null" || true)

            if [[ -n "$source_moodledata" ]]; then
                sre_info "Syncing moodledata from: $source_moodledata"
                rsync -avz --progress \
                    -e "ssh -p ${MIG_SOURCE_PORT}" \
                    "${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${source_moodledata}/" \
                    "${moodledata_dir}/"
                sre_success "Moodledata synced"
            else
                sre_warning "Could not detect moodledata path on source. Sync manually if needed."
            fi
            ;;

        nuxt)
            sre_info "Configuring Nuxt..."
            if [[ -f "${local_root}/package.json" ]]; then
                cd "$local_root"
                sre_info "Installing Node dependencies..."
                npm install --production 2>&1 | tail -3
                sre_info "Building..."
                npm run build 2>&1 | tail -5
                sre_success "Nuxt built"

                # Restart PM2 if running
                if command -v pm2 &>/dev/null; then
                    pm2_name="${MIG_DOMAIN}"
                    pm2 delete "$pm2_name" 2>/dev/null || true
                    pm2 start npm --name "$pm2_name" -- start
                    pm2 save
                    sre_success "PM2 process started: $pm2_name"
                fi
            fi
            ;;

        vue)
            sre_info "Configuring Vue..."
            if [[ -f "${local_root}/../package.json" ]]; then
                cd "${local_root}/.."
                sre_info "Installing Node dependencies..."
                npm install 2>&1 | tail -3
                sre_info "Building..."
                npm run build 2>&1 | tail -5
                sre_success "Vue built to dist/"
            fi
            ;;
    esac

    # Fix permissions using POSIX ACLs
    sre_header "Fixing Permissions (POSIX ACL)"

    # Ensure acl package is installed
    if ! command -v setfacl &>/dev/null; then
        sre_info "Installing ACL utilities..."
        pkg_install acl
    fi

    project_dir="/var/www/${MIG_DOMAIN}"

    # Base ownership: www-data owns everything
    chown -R www-data:www-data "$project_dir"
    sre_success "Ownership set to www-data:www-data"

    # Base permissions: directories 755, files 644
    find "$project_dir" -type d -exec chmod 755 {} \;
    find "$project_dir" -type f -exec chmod 644 {} \;
    sre_success "Base permissions: dirs=755, files=644"

    # Default ACL: new files/dirs inherit www-data ownership
    setfacl -R -m d:u:www-data:rwX "$project_dir"
    setfacl -R -m u:www-data:rwX "$project_dir"
    sre_success "Default ACL: www-data has rwX on all files and directories"

    # Grant the current deploy user (root) full access via ACL
    setfacl -R -m d:u:root:rwX "$project_dir"
    setfacl -R -m u:root:rwX "$project_dir"
    sre_info "ACL: root has full access"

    # Project-type-specific writable directories
    case "$MIG_PROJECT_TYPE" in
        laravel)
            writable_dirs=(
                "${local_root}/storage"
                "${local_root}/bootstrap/cache"
            )
            for wd in "${writable_dirs[@]}"; do
                if [[ -d "$wd" ]]; then
                    # Group writable + sticky for writable dirs
                    chmod -R 775 "$wd"
                    # ACL: www-data gets rwx on existing + new files
                    setfacl -R -m u:www-data:rwX "$wd"
                    setfacl -R -m d:u:www-data:rwX "$wd"
                    # ACL: group www-data also gets rwx
                    setfacl -R -m g:www-data:rwX "$wd"
                    setfacl -R -m d:g:www-data:rwX "$wd"
                fi
            done
            sre_success "Laravel writable dirs (storage, bootstrap/cache): ACL rwX for www-data"

            # .env must be readable by www-data only
            if [[ -f "${local_root}/.env" ]]; then
                chmod 640 "${local_root}/.env"
                setfacl -m u:www-data:r-- "${local_root}/.env"
                sre_success ".env: owner rw, www-data read-only"
            fi
            ;;

        moodle)
            moodledata_dir="/var/www/${MIG_DOMAIN}/moodledata"
            if [[ -d "$moodledata_dir" ]]; then
                chmod -R 775 "$moodledata_dir"
                setfacl -R -m u:www-data:rwX "$moodledata_dir"
                setfacl -R -m d:u:www-data:rwX "$moodledata_dir"
                setfacl -R -m g:www-data:rwX "$moodledata_dir"
                setfacl -R -m d:g:www-data:rwX "$moodledata_dir"
                sre_success "Moodledata: ACL rwX for www-data"
            fi

            # config.php must be readable by www-data only
            if [[ -f "${local_root}/config.php" ]]; then
                chmod 640 "${local_root}/config.php"
                setfacl -m u:www-data:r-- "${local_root}/config.php"
                sre_success "config.php: owner rw, www-data read-only"
            fi
            ;;

        nuxt)
            # .nuxt and .output dirs need write access
            for wd in "${local_root}/.nuxt" "${local_root}/.output" "${local_root}/node_modules"; do
                if [[ -d "$wd" ]]; then
                    setfacl -R -m u:www-data:rwX "$wd"
                    setfacl -R -m d:u:www-data:rwX "$wd"
                fi
            done
            sre_success "Nuxt build dirs: ACL rwX for www-data"
            ;;

        vue)
            # dist is static, read-only for www-data is fine (already set above)
            sre_success "Vue dist: read-only for www-data (static files)"
            ;;
    esac

    # Verify ACLs
    sre_info "ACL summary for $project_dir:"
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
    sre_info "[DRY-RUN] Would configure $MIG_PROJECT_TYPE project"
    sre_info "[DRY-RUN] Would fix permissions"
fi

################################################################################
# Summary
################################################################################

sre_header "Migration Summary"

sre_success "Migration complete for $MIG_DOMAIN"
echo ""
sre_info "  Domain:       $MIG_DOMAIN"
sre_info "  Project type: $MIG_PROJECT_TYPE"
sre_info "  Local root:   $local_root"
if [[ "$needs_db" == "true" ]]; then
    sre_info "  Database:     $MIG_DB_NAME"
    sre_info "  DB User:      $MIG_DB_USER"
    sre_info "  DB Password:  $MIG_DB_PASS"
fi
sre_info "  Source:       ${MIG_SOURCE_USER}@${MIG_SOURCE_HOST}:${MIG_SOURCE_PATH}"
echo ""
sre_warning "Save these database credentials!"
echo ""
sre_info "Next: Set up SSL for $MIG_DOMAIN"

recommend_next_step "$CURRENT_STEP"
