#!/bin/bash
################################################################################
# SRE Helpers - Step 13: Deploy New Project from Git
# Creates a new project from a git repository.
# Handles: git clone, directory setup, database creation, post-setup, permissions.
# Saves state per domain for re-runs.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=13

DEPLOY_DOMAIN=""
DEPLOY_TYPE=""
DEPLOY_REPO_URL=""
DEPLOY_BRANCH="main"
DEPLOY_DB_NAME=""
DEPLOY_DB_USER=""
DEPLOY_DB_PASS=""
DEPLOY_MOODLEDATA_DIR=""

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 13: Deploy New Project from Git
  Clones a git repository and sets up a new project on the server.
  Creates directory structure, database, .env, runs build commands.
  Saves all entered data per domain so re-runs use previous values.

Prerequisites:
  - Virtual host (step 8) must exist for the domain
  - Database engine (step 5) must be installed (for Laravel/Moodle)
  - Git must be installed

Options:
  --domain <name>        Domain to deploy to (or pick from existing vhosts)
  --type <type>          Project type: laravel, moodle, nuxt, vue
  --repo <url>           Git repository URL (SSH or HTTPS)
  --branch <branch>      Git branch to clone (default: main)
  --dry-run              Print planned actions without executing
  --yes                  Accept defaults without prompting
  --config               Override config file path
  --log                  Override log file path
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --domain app.example.com --type laravel --repo git@github.com:user/app.git
  sudo bash $0 --domain lms.example.com --type moodle --repo git@github.com:user/moodle.git --branch MOODLE_404_STABLE
EOF
}

################################################################################
# State persistence (per domain)
################################################################################

DEPLOY_STATE_DIR="/etc/sre-helpers/deployments"

_deploy_state_file() {
    echo "${DEPLOY_STATE_DIR}/${1}.conf"
}

deploy_save_state() {
    mkdir -p "$DEPLOY_STATE_DIR"
    local sf
    sf=$(_deploy_state_file "$DEPLOY_DOMAIN")
    cat > "$sf" <<STATE
# Deployment state for ${DEPLOY_DOMAIN}
# Saved on $(date '+%Y-%m-%d %H:%M:%S')
DEPLOY_DOMAIN="${DEPLOY_DOMAIN}"
DEPLOY_TYPE="${DEPLOY_TYPE}"
DEPLOY_REPO_URL="${DEPLOY_REPO_URL}"
DEPLOY_BRANCH="${DEPLOY_BRANCH}"
DEPLOY_MOODLEDATA_DIR="${DEPLOY_MOODLEDATA_DIR}"
DEPLOY_DB_NAME="${DEPLOY_DB_NAME}"
DEPLOY_DB_USER="${DEPLOY_DB_USER}"
DEPLOY_DB_PASS="${DEPLOY_DB_PASS}"
STATE
    sre_info "Deployment state saved to: $sf"
}

deploy_load_state() {
    local sf
    sf=$(_deploy_state_file "$1")
    if [[ -f "$sf" ]]; then
        # shellcheck source=/dev/null
        source "$sf"
        sre_success "Loaded saved deployment state for $1"
        return 0
    fi
    return 1
}

################################################################################
# Parse arguments
################################################################################

_raw_args=("$@")
sre_parse_args "13-new-project.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --domain)  ((_i++)); DEPLOY_DOMAIN="${_raw_args[$_i]:-}" ;;
        --type)    ((_i++)); DEPLOY_TYPE="${_raw_args[$_i]:-}" ;;
        --repo)    ((_i++)); DEPLOY_REPO_URL="${_raw_args[$_i]:-}" ;;
        --branch)  ((_i++)); DEPLOY_BRANCH="${_raw_args[$_i]:-main}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 13: Deploy New Project from Git"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
db_engine=$(config_get "SRE_DB_ENGINE" "none")
php_version=$(config_get "SRE_PHP_VERSION" "8.3")

# Verify git is installed
if ! command -v git &>/dev/null; then
    sre_error "Git is not installed. Install it first."
    exit 2
fi

################################################################################
# Select domain
################################################################################

sre_header "Select Domain"

if [[ -z "$DEPLOY_DOMAIN" ]]; then
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

    DEPLOY_DOMAIN=$(prompt_choice "Select domain to deploy to:" "${vhost_domains[@]}")
fi

sre_info "Domain: $DEPLOY_DOMAIN"

# Verify vhost exists
vhost_conf_path="$(get_vhost_dir "$web_server")/${DEPLOY_DOMAIN}.conf"
if [[ ! -f "$vhost_conf_path" ]]; then
    sre_error "Vhost config not found: $vhost_conf_path"
    sre_error "Run step 8 (vhost) first for this domain."
    exit 2
fi

################################################################################
# Load saved state (use as defaults if re-running)
################################################################################

saved_state_exists=false
if deploy_load_state "$DEPLOY_DOMAIN" 2>/dev/null; then
    saved_state_exists=true
    sre_info "Previous deployment data found. Values will be used as defaults."
fi

################################################################################
# Project type
################################################################################

if [[ -z "$DEPLOY_TYPE" ]]; then
    DEPLOY_TYPE=$(prompt_choice "Project type:" "laravel" "moodle" "nuxt" "vue")
fi

case "$DEPLOY_TYPE" in
    laravel|moodle|nuxt|vue) ;;
    *) sre_error "Invalid project type: $DEPLOY_TYPE"; exit 1 ;;
esac

sre_info "Project type: $DEPLOY_TYPE"

################################################################################
# PHP version selection (Laravel/Moodle only)
################################################################################

if [[ "$DEPLOY_TYPE" == "laravel" || "$DEPLOY_TYPE" == "moodle" ]]; then
    extra_versions=$(config_get "SRE_PHP_EXTRA_VERSIONS" "")
    if [[ -n "$extra_versions" ]]; then
        available_versions=("$php_version")
        IFS=',' read -ra _extra <<< "$extra_versions"
        for v in "${_extra[@]}"; do
            v=$(echo "$v" | tr -d ' ')
            [[ -n "$v" && "$v" != "$php_version" ]] && available_versions+=("$v")
        done

        if [[ ${#available_versions[@]} -gt 1 ]]; then
            php_version=$(prompt_choice "PHP version for this project:" "${available_versions[@]}")
        fi
    fi
    sre_info "PHP version: $php_version"
fi

################################################################################
# Git repository details
################################################################################

sre_header "Git Repository"

default_repo="${DEPLOY_REPO_URL}"
DEPLOY_REPO_URL=$(prompt_input "Git repository URL (SSH or HTTPS)" "$default_repo")
if [[ -z "$DEPLOY_REPO_URL" ]]; then
    sre_error "Git repository URL is required."
    exit 1
fi

default_branch="${DEPLOY_BRANCH:-main}"
DEPLOY_BRANCH=$(prompt_input "Branch to clone" "$default_branch")

sre_info "Repo: $DEPLOY_REPO_URL"
sre_info "Branch: $DEPLOY_BRANCH"

################################################################################
# Determine paths based on project type
################################################################################

project_dir="/var/www/${DEPLOY_DOMAIN}"

case "$DEPLOY_TYPE" in
    laravel)
        # Clone into project_dir root — code lives at project_dir level
        # Document root is current/public (vhost expects this)
        clone_target="${project_dir}"
        local_root="${project_dir}"
        ;;
    moodle)
        # Code lives at public_html (vhost expects /var/www/{domain}/public_html)
        clone_target="${project_dir}/public_html"
        local_root="${project_dir}/public_html"
        ;;
    nuxt)
        # Code lives at project_dir root
        # Document root is current (vhost expects this)
        clone_target="${project_dir}"
        local_root="${project_dir}"
        ;;
    vue)
        # Code lives at project_dir root — build output goes to dist/
        # Document root is current/dist (vhost expects this)
        clone_target="${project_dir}"
        local_root="${project_dir}"
        ;;
esac

################################################################################
# Moodle: moodledata path (may be on block storage)
################################################################################

if [[ "$DEPLOY_TYPE" == "moodle" ]]; then
    sre_header "Moodle Data Directory"

    # Priority: saved state > block storage > default
    default_moodledata="${DEPLOY_MOODLEDATA_DIR}"
    if [[ -z "$default_moodledata" ]]; then
        if [[ -d "/u02/appdata" ]]; then
            default_moodledata="/u02/appdata/${DEPLOY_DOMAIN}/moodledata"
            sre_info "Block storage detected at /u02/appdata"
        else
            default_moodledata="/var/www/${DEPLOY_DOMAIN}/moodledata"
        fi
    fi

    DEPLOY_MOODLEDATA_DIR=$(prompt_input "Moodledata directory" "$default_moodledata")
    sre_info "Moodledata path: $DEPLOY_MOODLEDATA_DIR"
fi

################################################################################
# Database details (Laravel/Moodle only)
################################################################################

needs_db=false
if [[ "$DEPLOY_TYPE" == "laravel" || "$DEPLOY_TYPE" == "moodle" ]] && [[ "$db_engine" != "none" ]]; then
    if prompt_yesno "Create a database for this project?" "yes"; then
        needs_db=true

        sre_header "Database Configuration"

        # Generate defaults from domain
        safe_name=$(echo "$DEPLOY_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-32)

        default_db_name="${DEPLOY_DB_NAME:-$safe_name}"
        default_db_user="${DEPLOY_DB_USER:-$safe_name}"
        default_db_pass="${DEPLOY_DB_PASS}"

        DEPLOY_DB_NAME=$(prompt_input "Database name" "$default_db_name")
        DEPLOY_DB_USER=$(prompt_input "Database user" "$default_db_user")
        DEPLOY_DB_PASS=$(prompt_input "Database password (empty = auto-generate)" "$default_db_pass")

        if [[ -z "$DEPLOY_DB_PASS" ]]; then
            DEPLOY_DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
            sre_info "Auto-generated password: $DEPLOY_DB_PASS"
        fi

        sre_info "Database: $DEPLOY_DB_NAME"
        sre_info "DB User:  $DEPLOY_DB_USER"
    fi
fi

################################################################################
# Save state before performing actions
################################################################################

deploy_save_state

################################################################################
# Summary + confirmation
################################################################################

sre_header "Deployment Summary"

sre_info "Domain:       $DEPLOY_DOMAIN"
sre_info "Type:         $DEPLOY_TYPE"
sre_info "Repository:   $DEPLOY_REPO_URL"
sre_info "Branch:       $DEPLOY_BRANCH"
sre_info "Project dir:  $project_dir"
sre_info "Clone target: $clone_target"
[[ "$DEPLOY_TYPE" == "laravel" || "$DEPLOY_TYPE" == "moodle" ]] && sre_info "PHP version:  $php_version"
[[ "$DEPLOY_TYPE" == "moodle" ]] && sre_info "Moodledata:   $DEPLOY_MOODLEDATA_DIR"
[[ "$needs_db" == "true" ]] && sre_info "Database:     $DEPLOY_DB_NAME (engine: $db_engine)"

if ! prompt_yesno "Proceed with deployment?" "yes"; then
    sre_info "Deployment cancelled."
    exit 0
fi

################################################################################
# CREATE DIRECTORY STRUCTURE
################################################################################

sre_header "Creating Directory Structure"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    mkdir -p "$project_dir"

    case "$DEPLOY_TYPE" in
        laravel)
            mkdir -p "${project_dir}/shared/storage"/{app/public,framework/{cache,sessions,views},logs}
            mkdir -p "${project_dir}/releases"
            sre_success "Created Laravel directory structure"
            ;;
        moodle)
            mkdir -p "$clone_target"
            mkdir -p "$DEPLOY_MOODLEDATA_DIR"
            sre_success "Created Moodle directory structure"
            ;;
        nuxt|vue)
            mkdir -p "$project_dir"
            sre_success "Created project directory"
            ;;
    esac

    chown -R www-data:www-data "$project_dir"
    sre_success "Directory structure ready: $project_dir"
else
    sre_info "[DRY-RUN] Would create directory structure at $project_dir"
fi

################################################################################
# GIT CLONE
################################################################################

sre_header "Cloning Repository"

if [[ "$SRE_DRY_RUN" != "true" ]]; then

    case "$DEPLOY_TYPE" in
        laravel)
            # Clone into a timestamped release directory
            release_ts=$(date +%Y%m%d%H%M%S)
            release_dir="${project_dir}/releases/${release_ts}"
            mkdir -p "$release_dir"

            sre_info "Cloning into release: $release_dir"
            git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
            git_rc=${PIPESTATUS[0]:-$?}

            if [[ $git_rc -ne 0 ]]; then
                sre_error "Git clone failed (exit: $git_rc)"
                sre_error "Check: repository URL, branch name, SSH keys"
                rm -rf "$release_dir"
                exit 1
            fi

            # Create current symlink (remove dir if vhost step created it)
            [[ -d "${project_dir}/current" && ! -L "${project_dir}/current" ]] && rm -rf "${project_dir}/current"
            ln -sfn "$release_dir" "${project_dir}/current"
            sre_success "Release directory: $release_dir"
            sre_success "Current symlink → $release_dir"

            # Symlink shared resources
            if [[ -d "${project_dir}/shared/storage" ]]; then
                rm -rf "${release_dir}/storage"
                ln -sfn "${project_dir}/shared/storage" "${release_dir}/storage"
                sre_success "Linked shared/storage"
            fi

            local_root="$release_dir"
            ;;

        moodle)
            sre_info "Cloning into: $clone_target"

            # If target already has files, offer to overwrite
            if [[ -d "${clone_target}/.git" ]]; then
                if prompt_yesno "Git repo already exists at $clone_target. Pull latest instead of clone?" "yes"; then
                    cd "$clone_target"
                    git fetch origin "$DEPLOY_BRANCH"
                    git checkout "$DEPLOY_BRANCH"
                    git pull origin "$DEPLOY_BRANCH" 2>&1 | tail -5
                    sre_success "Pulled latest from $DEPLOY_BRANCH"
                else
                    sre_info "Removing existing repo and re-cloning..."
                    rm -rf "$clone_target"
                    mkdir -p "$clone_target"
                    git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$clone_target" 2>&1 | tail -5
                fi
            else
                # Clean clone
                if [[ "$(ls -A "$clone_target" 2>/dev/null)" ]]; then
                    sre_warning "Target directory is not empty: $clone_target"
                    if ! prompt_yesno "Remove existing files and clone fresh?" "no"; then
                        sre_error "Aborting — target directory not empty."
                        exit 1
                    fi
                    rm -rf "${clone_target:?}"/*
                fi
                git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$clone_target" 2>&1 | tail -5
            fi

            git_rc=${PIPESTATUS[0]:-$?}
            if [[ $git_rc -ne 0 ]]; then
                sre_error "Git clone failed (exit: $git_rc)"
                exit 1
            fi
            sre_success "Repository cloned to $clone_target"
            local_root="$clone_target"
            ;;

        nuxt)
            release_ts=$(date +%Y%m%d%H%M%S)
            release_dir="${project_dir}/releases/${release_ts}"
            mkdir -p "${project_dir}/releases"

            sre_info "Cloning into release: $release_dir"
            git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
            git_rc=${PIPESTATUS[0]:-$?}

            if [[ $git_rc -ne 0 ]]; then
                sre_error "Git clone failed (exit: $git_rc)"
                rm -rf "$release_dir"
                exit 1
            fi

            [[ -d "${project_dir}/current" && ! -L "${project_dir}/current" ]] && rm -rf "${project_dir}/current"
            ln -sfn "$release_dir" "${project_dir}/current"
            sre_success "Cloned and linked: current → $release_dir"
            local_root="$release_dir"
            ;;

        vue)
            release_ts=$(date +%Y%m%d%H%M%S)
            release_dir="${project_dir}/releases/${release_ts}"
            mkdir -p "${project_dir}/releases"

            sre_info "Cloning into release: $release_dir"
            git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
            git_rc=${PIPESTATUS[0]:-$?}

            if [[ $git_rc -ne 0 ]]; then
                sre_error "Git clone failed (exit: $git_rc)"
                rm -rf "$release_dir"
                exit 1
            fi

            [[ -d "${project_dir}/current" && ! -L "${project_dir}/current" ]] && rm -rf "${project_dir}/current"
            ln -sfn "$release_dir" "${project_dir}/current"
            sre_success "Cloned and linked: current → $release_dir"
            local_root="$release_dir"
            ;;
    esac

    chown -R www-data:www-data "$project_dir"
    sre_success "Git clone complete"
else
    sre_info "[DRY-RUN] Would clone $DEPLOY_REPO_URL ($DEPLOY_BRANCH) into $clone_target"
fi

################################################################################
# CREATE DATABASE
################################################################################

if [[ "$needs_db" == "true" ]]; then
    sre_header "Creating Database"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$db_engine" in
            mariadb|mysql)
                db_root_pass=""
                [[ -f /root/.db_root_password ]] && db_root_pass=$(cat /root/.db_root_password)

                mysql_cmd="mysql"
                [[ -n "$db_root_pass" ]] && mysql_cmd="mysql -u root -p${db_root_pass}"

                $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${DEPLOY_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                sre_success "Database created: $DEPLOY_DB_NAME"

                $mysql_cmd -e "CREATE USER IF NOT EXISTS '${DEPLOY_DB_USER}'@'localhost' IDENTIFIED BY '${DEPLOY_DB_PASS}';" 2>/dev/null
                $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${DEPLOY_DB_NAME}\`.* TO '${DEPLOY_DB_USER}'@'localhost';" 2>/dev/null
                $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null
                sre_success "Database user created: $DEPLOY_DB_USER"
                ;;

            postgresql)
                sudo -u postgres psql -c "DO \$\$ BEGIN
                    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DEPLOY_DB_USER}') THEN
                        CREATE ROLE ${DEPLOY_DB_USER} WITH LOGIN PASSWORD '${DEPLOY_DB_PASS}';
                    END IF;
                END \$\$;" 2>/dev/null
                sre_success "PostgreSQL user created: $DEPLOY_DB_USER"

                if ! sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$DEPLOY_DB_NAME"; then
                    sudo -u postgres createdb -O "$DEPLOY_DB_USER" "$DEPLOY_DB_NAME"
                fi
                sre_success "PostgreSQL database created: $DEPLOY_DB_NAME"
                ;;
        esac
    else
        sre_info "[DRY-RUN] Would create database: $DEPLOY_DB_NAME"
        sre_info "[DRY-RUN] Would create user: $DEPLOY_DB_USER"
    fi
fi

################################################################################
# POST-SETUP
################################################################################

sre_header "Post-Setup"

if prompt_yesno "Run post-setup? (env, dependencies, build)" "yes"; then
if [[ "$SRE_DRY_RUN" != "true" ]]; then
    case "$DEPLOY_TYPE" in
        laravel)
            sre_info "Configuring Laravel..."

            # .env setup
            if prompt_yesno "Setup .env file?" "yes"; then
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
                    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DEPLOY_DB_NAME}|" "${local_root}/.env"
                    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DEPLOY_DB_USER}|" "${local_root}/.env"
                    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DEPLOY_DB_PASS}|" "${local_root}/.env"
                    sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "${local_root}/.env"
                    sre_success "Updated .env with database credentials"
                fi

                sed -i "s|^APP_URL=.*|APP_URL=http://${DEPLOY_DOMAIN}|" "${local_root}/.env"
                sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${local_root}/.env"
                sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${local_root}/.env"
                sre_success ".env configured"
            else
                sre_skipped ".env setup"
            fi

            # Storage directories (in shared if symlinked, else in release)
            if prompt_yesno "Create storage directories?" "yes"; then
                storage_dir="${local_root}/storage"
                # If storage is a symlink to shared, ensure shared has the dirs
                if [[ -L "$storage_dir" ]]; then
                    storage_dir=$(readlink -f "$storage_dir")
                fi
                mkdir -p "${storage_dir}"/{app/public,framework/{cache,sessions,views},logs}
                mkdir -p "${local_root}/bootstrap/cache"
                sre_success "Storage directories created"
            fi

            # Composer install
            if command -v composer &>/dev/null; then
                if prompt_yesno "Run composer install?" "yes"; then
                    sre_info "Running: composer install --no-dev --optimize-autoloader..."
                    cd "$local_root" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -5
                    sre_success "Composer dependencies installed"
                else
                    sre_skipped "composer install"
                fi
            else
                sre_warning "Composer not found — skipping"
            fi

            # APP_KEY
            if ! grep -q "^APP_KEY=base64:" "${local_root}/.env" 2>/dev/null; then
                if prompt_yesno "Generate application key? (APP_KEY is missing)" "yes"; then
                    cd "$local_root" && php artisan key:generate --no-interaction
                    sre_success "Application key generated"
                fi
            fi

            # Artisan migrate
            if [[ "$needs_db" == "true" ]]; then
                if prompt_yesno "Run php artisan migrate?" "no"; then
                    sre_info "Running: php artisan migrate..."
                    cd "$local_root" && php artisan migrate --force --no-interaction 2>&1 | tail -5
                    sre_success "Database migrations complete"
                else
                    sre_skipped "artisan migrate"
                fi
            fi

            # npm install + build
            if [[ -f "${local_root}/package.json" ]]; then
                if prompt_yesno "Run npm install && npm run build?" "yes"; then
                    sre_info "Running: npm install..."
                    cd "$local_root" && npm install 2>&1 | tail -3
                    sre_info "Running: npm run build..."
                    npm run build 2>&1 | tail -5
                    sre_success "Frontend assets built"
                else
                    sre_skipped "npm install/build"
                fi
            fi

            # Cache
            if prompt_yesno "Rebuild Laravel caches? (config, route, view)" "yes"; then
                cd "$local_root"
                php artisan config:cache --no-interaction 2>/dev/null || true
                php artisan route:cache --no-interaction 2>/dev/null || true
                php artisan view:cache --no-interaction 2>/dev/null || true
                sre_success "Laravel caches rebuilt"
            else
                sre_skipped "Cache rebuild"
            fi

            # Storage link
            if prompt_yesno "Run php artisan storage:link?" "yes"; then
                cd "$local_root" && php artisan storage:link --no-interaction 2>/dev/null || true
                sre_success "Storage symlink created"
            else
                sre_skipped "storage:link"
            fi
            ;;

        moodle)
            sre_info "Configuring Moodle..."

            mkdir -p "$DEPLOY_MOODLEDATA_DIR"

            # Determine dbtype for config.php
            case "$db_engine" in
                mariadb|mysql) moodle_dbtype="mysqli" ;;
                postgresql)    moodle_dbtype="pgsql" ;;
                *)             moodle_dbtype="mysqli" ;;
            esac

            moodle_prefix=$(prompt_input "Moodle table prefix" "mdl_")

            [[ -f "${local_root}/config.php" ]] && cp "${local_root}/config.php" "${local_root}/config.php.bak"

            if [[ "$needs_db" == "true" ]]; then
                cat > "${local_root}/config.php" <<MOODLE_CONFIG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = '${moodle_dbtype}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${DEPLOY_DB_NAME}';
\$CFG->dbuser    = '${DEPLOY_DB_USER}';
\$CFG->dbpass    = '${DEPLOY_DB_PASS}';
\$CFG->prefix    = '${moodle_prefix}';

\$CFG->wwwroot   = 'http://${DEPLOY_DOMAIN}';
\$CFG->dataroot  = '${DEPLOY_MOODLEDATA_DIR}';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0770;

require_once(__DIR__ . '/lib/setup.php');
MOODLE_CONFIG
                sre_success "Moodle config.php written (dbtype: $moodle_dbtype, prefix: $moodle_prefix)"
                sre_info "  wwwroot:  http://${DEPLOY_DOMAIN}"
                sre_info "  dataroot: ${DEPLOY_MOODLEDATA_DIR}"
            else
                sre_warning "No database — config.php not generated (manual setup required)"
            fi
            ;;

        nuxt)
            sre_info "Configuring Nuxt..."
            if [[ -f "${local_root}/package.json" ]]; then
                if prompt_yesno "Run npm install?" "yes"; then
                    cd "$local_root"
                    sre_info "Running: npm install..."
                    npm install 2>&1 | tail -3
                    sre_success "Node dependencies installed"
                else
                    sre_skipped "npm install"
                fi

                if prompt_yesno "Run npm run build?" "yes"; then
                    cd "$local_root"
                    sre_info "Running: npm run build..."
                    npm run build 2>&1 | tail -5
                    sre_success "Nuxt built"
                else
                    sre_skipped "npm run build"
                fi

                if command -v pm2 &>/dev/null; then
                    if prompt_yesno "Start PM2 process?" "yes"; then
                        pm2 delete "${DEPLOY_DOMAIN}" 2>/dev/null || true

                        # Nuxt 3 builds to .output/server/index.mjs
                        if [[ -f "${local_root}/.output/server/index.mjs" ]]; then
                            pm2 start "${local_root}/.output/server/index.mjs" \
                                --name "${DEPLOY_DOMAIN}" \
                                --cwd "${local_root}"
                        elif [[ -f "${local_root}/.output/server/index.js" ]]; then
                            pm2 start "${local_root}/.output/server/index.js" \
                                --name "${DEPLOY_DOMAIN}" \
                                --cwd "${local_root}"
                        else
                            # Nuxt 2 / custom start script fallback
                            pm2 start npm --name "${DEPLOY_DOMAIN}" --cwd "${local_root}" -- start
                        fi
                        pm2 save
                        sre_success "PM2 process started: ${DEPLOY_DOMAIN}"
                    else
                        sre_skipped "PM2 start"
                    fi
                fi
            fi
            ;;

        vue)
            sre_info "Configuring Vue..."
            if [[ -f "${local_root}/package.json" ]]; then
                if prompt_yesno "Run npm install && npm run build?" "yes"; then
                    cd "$local_root"
                    sre_info "Running: npm install..."
                    npm install 2>&1 | tail -3
                    sre_info "Running: npm run build..."
                    npm run build 2>&1 | tail -5
                    sre_success "Vue built to dist/"
                else
                    sre_skipped "npm install/build"
                fi
            fi
            ;;
    esac

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
    sre_info "[DRY-RUN] Would configure $DEPLOY_TYPE"
fi
else
    sre_skipped "Post-setup (user skipped)"
fi

################################################################################
# FIX PERMISSIONS — always runs after deployment
################################################################################

sre_header "Fix Permissions"

if [[ "$SRE_DRY_RUN" != "true" ]]; then

    require_acl

    # ── Base ownership ────────────────────────────────────────────────────────
    sre_info "Setting ownership: www-data:www-data on $project_dir"
    chown -R www-data:www-data "$project_dir"
    sre_success "Ownership: www-data:www-data on $project_dir"

    # Fix moodledata ownership (may be outside project_dir)
    if [[ "$DEPLOY_TYPE" == "moodle" ]] && [[ -n "${DEPLOY_MOODLEDATA_DIR:-}" ]] \
            && [[ -d "$DEPLOY_MOODLEDATA_DIR" ]] \
            && [[ "$DEPLOY_MOODLEDATA_DIR" != "$project_dir"* ]]; then
        sre_info "Fixing ownership on external moodledata: $DEPLOY_MOODLEDATA_DIR"
        chown -R www-data:www-data "$DEPLOY_MOODLEDATA_DIR"
        sre_success "Ownership: www-data:www-data on $DEPLOY_MOODLEDATA_DIR"
    fi

    # ── Base permissions ──────────────────────────────────────────────────────
    find "$project_dir" -type d -exec chmod 755 {} \;
    find "$project_dir" -type f -exec chmod 644 {} \;
    sre_success "Base: dirs=755, files=644"

    # ── Default ACLs for inheritance ──────────────────────────────────────────
    setfacl -R -m d:u:www-data:rwX "$project_dir"
    setfacl -R -m u:www-data:rwX "$project_dir"
    setfacl -R -m d:u:root:rwX "$project_dir"
    setfacl -R -m u:root:rwX "$project_dir"
    sre_success "Default ACL: www-data + root have rwX"

    # ── Executable scripts / binaries ─────────────────────────────────────────
    for pattern in "*.sh" "artisan"; do
        find "$project_dir" -name "$pattern" -type f -exec chmod 755 {} \; 2>/dev/null || true
    done
    for bin_dir in "${local_root}/vendor/bin" "${local_root}/node_modules/.bin"; do
        if [[ -d "$bin_dir" ]]; then
            find "$bin_dir" -type f -exec chmod 755 {} \;
        fi
    done

    # ── Project-type-specific ─────────────────────────────────────────────────
    case "$DEPLOY_TYPE" in
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
            sre_success "Laravel: storage + bootstrap/cache → 775, ACL rwX"

            if [[ -f "${local_root}/.env" ]]; then
                chmod 640 "${local_root}/.env"
                setfacl -m u:www-data:r-- "${local_root}/.env"
                sre_success ".env: 640, www-data read-only"
            fi

            [[ -f "${local_root}/artisan" ]] && chmod 755 "${local_root}/artisan"
            ;;

        moodle)
            if [[ -n "${DEPLOY_MOODLEDATA_DIR:-}" ]] && [[ -d "$DEPLOY_MOODLEDATA_DIR" ]]; then
                chown -R www-data:www-data "$DEPLOY_MOODLEDATA_DIR"
                chmod -R 775 "$DEPLOY_MOODLEDATA_DIR"
                setfacl -R -m u:www-data:rwX "$DEPLOY_MOODLEDATA_DIR"
                setfacl -R -m d:u:www-data:rwX "$DEPLOY_MOODLEDATA_DIR"
                setfacl -R -m g:www-data:rwX "$DEPLOY_MOODLEDATA_DIR"
                setfacl -R -m d:g:www-data:rwX "$DEPLOY_MOODLEDATA_DIR"

                mount_point=$(df "$DEPLOY_MOODLEDATA_DIR" --output=target 2>/dev/null | tail -1)
                if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
                    if ! mount | grep "$mount_point" | grep -q "acl"; then
                        sre_warning "Block storage at $mount_point may need 'acl' mount option in /etc/fstab"
                    fi
                fi

                sre_success "Moodledata ($DEPLOY_MOODLEDATA_DIR): 775, ACL rwX"
            fi

            if [[ -f "${local_root}/config.php" ]]; then
                chmod 640 "${local_root}/config.php"
                setfacl -m u:www-data:r-- "${local_root}/config.php"
                sre_success "config.php: 640, www-data read-only"
            fi
            ;;
    esac
else
    sre_info "[DRY-RUN] Would fix permissions on $project_dir"
fi

################################################################################
# SUPERVISOR QUEUE WORKER (Laravel only)
################################################################################

if [[ "$DEPLOY_TYPE" == "laravel" ]] && [[ "$(config_get SRE_SUPERVISOR)" == "true" ]]; then
    if prompt_yesno "Setup Supervisor queue worker for this Laravel project?" "yes"; then
        sre_header "Supervisor Queue Worker"

        worker_queue=$(prompt_input "Queue name" "default")
        worker_processes=$(prompt_input "Number of worker processes" "2")
        worker_tries=$(prompt_input "Max retries per job" "3")
        worker_timeout=$(prompt_input "Job timeout (seconds)" "90")

        setup_horizon="no"
        if prompt_yesno "Use Laravel Horizon instead of default queue:work?" "no"; then
            setup_horizon="yes"
        fi

        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            supervisor_conf_dir="/etc/supervisor/conf.d"
            [[ "$SRE_OS_FAMILY" == "rhel" ]] && supervisor_conf_dir="/etc/supervisord.d"
            mkdir -p "$supervisor_conf_dir"

            if [[ "$setup_horizon" == "yes" ]]; then
                cat > "${supervisor_conf_dir}/${DEPLOY_DOMAIN}-horizon.conf" <<HORIZONEOF
[program:${DEPLOY_DOMAIN}-horizon]
process_name=%(program_name)s
command=php ${project_dir}/current/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${project_dir}/current/storage/logs/horizon.log
stopwaitsecs=3600
HORIZONEOF
                sre_success "Horizon worker config: ${supervisor_conf_dir}/${DEPLOY_DOMAIN}-horizon.conf"
            else
                cat > "${supervisor_conf_dir}/${DEPLOY_DOMAIN}-worker.conf" <<WORKEREOF
[program:${DEPLOY_DOMAIN}-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${project_dir}/current/artisan queue:work --sleep=3 --tries=${worker_tries} --timeout=${worker_timeout} --queue=${worker_queue}
autostart=true
autorestart=true
user=www-data
numprocs=${worker_processes}
redirect_stderr=true
stdout_logfile=${project_dir}/current/storage/logs/worker.log
stopwaitsecs=3600
WORKEREOF
                sre_success "Queue worker config: ${supervisor_conf_dir}/${DEPLOY_DOMAIN}-worker.conf"
            fi

            # Scheduler cron
            if prompt_yesno "Also setup Laravel scheduler cron?" "yes"; then
                cron_line="* * * * * www-data cd ${project_dir}/current && php artisan schedule:run >> /dev/null 2>&1"
                cron_file="/etc/cron.d/${DEPLOY_DOMAIN//\./-}-scheduler"
                echo "$cron_line" > "$cron_file"
                chmod 644 "$cron_file"
                sre_success "Scheduler cron created: $cron_file"
            fi

            supervisorctl reread 2>/dev/null || true
            supervisorctl update 2>/dev/null || true
            sre_success "Supervisor updated — workers starting"
        else
            sre_info "[DRY-RUN] Would create supervisor worker config for $DEPLOY_DOMAIN"
        fi
    fi
fi

################################################################################
# DONE
################################################################################

sre_header "Deployment Complete"

sre_success "Project deployed: $DEPLOY_DOMAIN ($DEPLOY_TYPE)"
sre_info "Project dir:  $project_dir"
sre_info "Code root:    $local_root"
[[ "$needs_db" == "true" ]] && sre_info "Database:     $DEPLOY_DB_NAME"
[[ "$DEPLOY_TYPE" == "moodle" ]] && sre_info "Moodledata:   $DEPLOY_MOODLEDATA_DIR"
sre_info ""
sre_info "Next steps:"
sre_info "  - Run SSL setup (step 11) if not done"
sre_info "  - Test the site: http://${DEPLOY_DOMAIN}"
sre_info "  - Check logs if issues: tail -f ${local_root}/storage/logs/laravel.log" 2>/dev/null || true

recommend_next_step "$CURRENT_STEP"
