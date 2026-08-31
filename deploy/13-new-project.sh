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
  --type <type>          Project type: laravel, moodle, wordpress, nuxt, vue, static
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
    # State files hold plaintext DB credentials — keep the whole tree root-only
    install -d -m 700 /etc/sre-helpers
    install -d -m 700 "$DEPLOY_STATE_DIR"
    local sf
    sf=$(_deploy_state_file "$DEPLOY_DOMAIN")
    touch "$sf"
    chmod 600 "$sf"
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
DEPLOY_OS_USER="${DEPLOY_OS_USER:-}"
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
        --domain)  _i=$((_i + 1)); DEPLOY_DOMAIN="${_raw_args[$_i]:-}" ;;
        --type)    _i=$((_i + 1)); DEPLOY_TYPE="${_raw_args[$_i]:-}" ;;
        --repo)    _i=$((_i + 1)); DEPLOY_REPO_URL="${_raw_args[$_i]:-}" ;;
        --branch)  _i=$((_i + 1)); DEPLOY_BRANCH="${_raw_args[$_i]:-main}" ;;
    esac
    _i=$((_i + 1))
done

require_root

sre_header "Step 13: Deploy New Project from Git"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
db_engines_config=$(config_get "SRE_DB_ENGINE" "none")
db_engine=""  # per-project engine, resolved later
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
    DEPLOY_TYPE=$(prompt_choice "Project type:" "laravel" "moodle" "wordpress" "nuxt" "vue" "static")
fi

case "$DEPLOY_TYPE" in
    laravel|moodle|wordpress|nuxt|vue|static) ;;
    *) sre_error "Invalid project type: $DEPLOY_TYPE"; exit 1 ;;
esac

sre_info "Project type: $DEPLOY_TYPE"

################################################################################
# PHP version selection (Laravel/Moodle/WordPress only)
################################################################################

if [[ "$DEPLOY_TYPE" == "laravel" || "$DEPLOY_TYPE" == "moodle" || "$DEPLOY_TYPE" == "wordpress" ]]; then
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
DEPLOY_OS_USER=$(iso_user_for "$DEPLOY_DOMAIN")

# Run git as the project user with its per-project deploy key
deploy_git() {
    sudo -u "$DEPLOY_OS_USER" -H \
        env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
        git "$@"
}

# Run a build command (composer/npm/artisan) as the project user in a directory
deploy_as_user() {
    local dir="$1"
    shift
    sudo -u "$DEPLOY_OS_USER" -H bash -c "cd \"$dir\" && $*"
}

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
    wordpress)
        # WordPress files (index.php, wp-config.php, wp-content/) live at clone root
        # Document root is current (vhost expects this)
        clone_target="${project_dir}"
        local_root="${project_dir}"
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
    static)
        # Plain static files served directly from current/
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
if [[ "$DEPLOY_TYPE" == "laravel" || "$DEPLOY_TYPE" == "moodle" || "$DEPLOY_TYPE" == "wordpress" ]] && [[ "$db_engines_config" != "none" ]]; then

    # Resolve which engine to use for this project
    available_engines=()
    IFS=',' read -ra _eng <<< "$db_engines_config"
    for e in "${_eng[@]}"; do
        e=$(echo "$e" | tr -d ' ')
        [[ -n "$e" && "$e" != "none" ]] && available_engines+=("$e")
    done

    # WordPress only supports MySQL/MariaDB — filter out PostgreSQL
    if [[ "$DEPLOY_TYPE" == "wordpress" ]]; then
        wp_engines=()
        for e in "${available_engines[@]}"; do
            [[ "$e" == "mariadb" || "$e" == "mysql" ]] && wp_engines+=("$e")
        done
        if [[ ${#wp_engines[@]} -eq 0 ]]; then
            sre_error "WordPress requires MySQL or MariaDB, but only PostgreSQL is installed."
            sre_error "Install MariaDB/MySQL via step 5 first."
            exit 2
        fi
        available_engines=("${wp_engines[@]}")
    fi

    if [[ ${#available_engines[@]} -eq 1 ]]; then
        db_engine="${available_engines[0]}"
    elif [[ ${#available_engines[@]} -gt 1 ]]; then
        db_engine=$(prompt_choice "Database engine for this project:" "${available_engines[@]}")
    fi

    sre_info "Database engine: $db_engine"

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
# PROJECT ISOLATION — dedicated system user + per-project deploy key
################################################################################

sre_header "Project Isolation"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    iso_ensure_user "$DEPLOY_DOMAIN" "$project_dir"
    sre_info "Project user: $DEPLOY_OS_USER"

    if [[ "$DEPLOY_REPO_URL" == git@* || "$DEPLOY_REPO_URL" == ssh://* ]]; then
        deploy_pubkey=$(iso_deploy_pubkey "$DEPLOY_DOMAIN" "$project_dir")
        sre_info "Register this as a READ-ONLY deploy key on the repository:"
        echo ""
        echo "    ${deploy_pubkey}"
        echo ""
        if ! prompt_yesno "Deploy key registered on the repository?" "yes"; then
            sre_warning "Continuing — git clone will fail until the key is registered"
        fi
    fi
else
    sre_info "[DRY-RUN] Would create project user $DEPLOY_OS_USER + deploy key"
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
        wordpress|nuxt|vue|static)
            mkdir -p "${project_dir}/releases"
            sre_success "Created project directory structure"
            ;;
    esac

    chown -R "$DEPLOY_OS_USER:$DEPLOY_OS_USER" "$project_dir"
    sre_success "Directory structure ready: $project_dir (owner $DEPLOY_OS_USER)"
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
            install -d -o "$DEPLOY_OS_USER" -g "$DEPLOY_OS_USER" "$release_dir"

            sre_info "Cloning into release: $release_dir"
            deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
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
                    deploy_git -C "$clone_target" fetch origin "$DEPLOY_BRANCH"
                    deploy_git -C "$clone_target" checkout "$DEPLOY_BRANCH"
                    deploy_git -C "$clone_target" pull origin "$DEPLOY_BRANCH" 2>&1 | tail -5
                    sre_success "Pulled latest from $DEPLOY_BRANCH"
                else
                    sre_info "Removing existing repo and re-cloning..."
                    rm -rf "$clone_target"
                    mkdir -p "$clone_target"
                    deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$clone_target" 2>&1 | tail -5
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
                deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$clone_target" 2>&1 | tail -5
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
            deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
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
            deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
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

        wordpress|static)
            release_ts=$(date +%Y%m%d%H%M%S)
            release_dir="${project_dir}/releases/${release_ts}"
            mkdir -p "${project_dir}/releases"

            sre_info "Cloning into release: $release_dir"
            deploy_git clone --branch "$DEPLOY_BRANCH" --single-branch --depth 1 "$DEPLOY_REPO_URL" "$release_dir" 2>&1 | tail -5
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

    chown -R "$DEPLOY_OS_USER:$DEPLOY_OS_USER" "$project_dir"
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
                # Connection target (local socket vs remote server) comes from
                # the dbconn library — see common/dbconn.sh and step 5.
                mysql_cmd="$(db_admin_cmd)"
                grant_host="$(db_grant_host)"
                sre_info "Target: $(db_describe)"

                # Fail fast with real diagnostics. These statements used to be
                # 2>/dev/null, which reported success even when nothing was
                # created — unacceptable once the server can be unreachable.
                db_check_connection quiet || {
                    db_check_connection
                    sre_error "Cannot create the database for $DEPLOY_DOMAIN."
                    exit 1
                }

                db_err=$(mktemp)
                if ! $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${DEPLOY_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>"$db_err"; then
                    sre_error "Failed to create database: $DEPLOY_DB_NAME"
                    [[ -s "$db_err" ]] && sed 's/^/    /' "$db_err" >&2
                    rm -f "$db_err"
                    exit 1
                fi
                sre_success "Database created: $DEPLOY_DB_NAME"

                if ! $mysql_cmd -e "CREATE USER IF NOT EXISTS '${DEPLOY_DB_USER}'@'${grant_host}' IDENTIFIED BY '${DEPLOY_DB_PASS}';" 2>"$db_err"; then
                    sre_error "Failed to create database user: ${DEPLOY_DB_USER}@${grant_host}"
                    [[ -s "$db_err" ]] && sed 's/^/    /' "$db_err" >&2
                    rm -f "$db_err"
                    exit 1
                fi
                # IF NOT EXISTS leaves a pre-existing user's password alone;
                # ALTER guarantees the password matches what we write to .env.
                $mysql_cmd -e "ALTER USER '${DEPLOY_DB_USER}'@'${grant_host}' IDENTIFIED BY '${DEPLOY_DB_PASS}';" 2>/dev/null || true

                if ! $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${DEPLOY_DB_NAME}\`.* TO '${DEPLOY_DB_USER}'@'${grant_host}';" 2>"$db_err"; then
                    sre_error "Failed to grant privileges to ${DEPLOY_DB_USER}@${grant_host}"
                    [[ -s "$db_err" ]] && sed 's/^/    /' "$db_err" >&2
                    rm -f "$db_err"
                    exit 1
                fi
                $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null || true
                rm -f "$db_err"
                sre_success "Database user created: ${DEPLOY_DB_USER}@${grant_host}"

                # Prove the app's own credentials work from here, rather than
                # discovering it after the site 500s.
                _app_cnf=$(mktemp); chmod 600 "$_app_cnf"
                {
                    printf '[client]\n'
                    printf 'user=%s\n' "$DEPLOY_DB_USER"
                    printf 'password=%s\n' "$DEPLOY_DB_PASS"
                    printf 'host=%s\n' "$(db_client_host)"
                    printf 'port=%s\n' "$(db_client_port)"
                } > "$_app_cnf"
                if mysql --defaults-extra-file="$_app_cnf" -e "USE \`${DEPLOY_DB_NAME}\`; SELECT 1;" >/dev/null 2>&1; then
                    sre_success "Verified app login: ${DEPLOY_DB_USER}@$(db_client_host) → $DEPLOY_DB_NAME"
                else
                    sre_warning "Could not verify the app's DB login from this host."
                    sre_warning "The database and user exist, but ${DEPLOY_DB_USER} could not"
                    sre_warning "connect to $(db_client_host):$(db_client_port)."
                    if db_is_remote; then
                        sre_warning "Most likely the GRANT host '${grant_host}' does not cover this server."
                    fi
                fi
                rm -f "$_app_cnf"
                ;;

            postgresql)
                # PostgreSQL admin here is local peer auth only.
                db_require_local_pg || exit 1

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
                    sed -i "s|^DB_HOST=.*|DB_HOST=$(db_client_host)|" "${local_root}/.env"
                    sed -i "s|^DB_PORT=.*|DB_PORT=$(db_client_port)|" "${local_root}/.env"
                    sre_success "Updated .env with database credentials (host: $(db_client_host):$(db_client_port))"
                fi

                sed -i "s|^APP_URL=.*|APP_URL=http://${DEPLOY_DOMAIN}|" "${local_root}/.env"
                sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${local_root}/.env"
                sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${local_root}/.env"
                chown "$DEPLOY_OS_USER:$DEPLOY_OS_USER" "${local_root}/.env"
                chmod 600 "${local_root}/.env"
                sre_success ".env configured (600, owner $DEPLOY_OS_USER)"
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
                chown -R "$DEPLOY_OS_USER:$DEPLOY_OS_USER" "$storage_dir" "${local_root}/bootstrap/cache"
                sre_success "Storage directories created"
            fi

            # Composer install
            if command -v composer &>/dev/null; then
                if prompt_yesno "Run composer install?" "yes"; then
                    sre_info "Running: composer install --no-dev --optimize-autoloader..."
                    deploy_as_user "$local_root" "composer install --no-dev --optimize-autoloader --no-interaction" 2>&1 | tail -5
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
                    deploy_as_user "$local_root" "php artisan key:generate --no-interaction"
                    sre_success "Application key generated"
                fi
            fi

            # Artisan migrate
            if [[ "$needs_db" == "true" ]]; then
                if prompt_yesno "Run php artisan migrate?" "no"; then
                    sre_info "Running: php artisan migrate..."
                    deploy_as_user "$local_root" "php artisan migrate --force --no-interaction" 2>&1 | tail -5
                    sre_success "Database migrations complete"
                else
                    sre_skipped "artisan migrate"
                fi
            fi

            # npm install + build
            if [[ -f "${local_root}/package.json" ]]; then
                if prompt_yesno "Run npm install && npm run build?" "yes"; then
                    sre_info "Running: npm install..."
                    deploy_as_user "$local_root" "npm install" 2>&1 | tail -3
                    sre_info "Running: npm run build..."
                    deploy_as_user "$local_root" "npm run build" 2>&1 | tail -5
                    sre_success "Frontend assets built"
                else
                    sre_skipped "npm install/build"
                fi
            fi

            # Cache
            if prompt_yesno "Rebuild Laravel caches? (config, route, view)" "yes"; then
                deploy_as_user "$local_root" "php artisan config:cache --no-interaction" 2>/dev/null || true
                deploy_as_user "$local_root" "php artisan route:cache --no-interaction" 2>/dev/null || true
                deploy_as_user "$local_root" "php artisan view:cache --no-interaction" 2>/dev/null || true
                sre_success "Laravel caches rebuilt"
            else
                sre_skipped "Cache rebuild"
            fi

            # Storage link
            if prompt_yesno "Run php artisan storage:link?" "yes"; then
                deploy_as_user "$local_root" "php artisan storage:link --no-interaction" 2>/dev/null || true
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
\$CFG->dbhost    = '$(db_client_host_legacy)';
\$CFG->dbname    = '${DEPLOY_DB_NAME}';
\$CFG->dbuser    = '${DEPLOY_DB_USER}';
\$CFG->dbpass    = '${DEPLOY_DB_PASS}';
\$CFG->prefix    = '${moodle_prefix}';
\$CFG->dboptions = array(
    'dbpersist' => false,
    'dbport'    => '$(db_client_port)',
    'dbsocket'  => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);

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
                    sre_info "Running: npm install..."
                    deploy_as_user "$local_root" "npm install" 2>&1 | tail -3
                    sre_success "Node dependencies installed"
                else
                    sre_skipped "npm install"
                fi

                if prompt_yesno "Run npm run build?" "yes"; then
                    sre_info "Running: npm run build..."
                    deploy_as_user "$local_root" "npm run build" 2>&1 | tail -5
                    sre_success "Nuxt built"
                else
                    sre_skipped "npm run build"
                fi

                if command -v pm2 &>/dev/null; then
                    if prompt_yesno "Start PM2 process?" "yes"; then
                        # Read the proxy port the vhost is configured for. The vhost
                        # is the source of truth (11-ssl.sh reads it the same way);
                        # PM2 must bind that exact port or nginx will proxy blindly.
                        nuxt_port=$(nuxt_port_from_conf "$vhost_conf_path")
                        [[ -z "$nuxt_port" ]] && nuxt_port="3000"
                        sre_info "PM2 will bind PORT=${nuxt_port} (HOST=127.0.0.1)"

                        # PM2 runs a per-project daemon as the project user.
                        # `sudo -u` strips the environment — wrap with `env` so PORT/HOST
                        # actually reach the node process. Without this, Nuxt falls back
                        # to :3000 regardless of what we prefix.
                        pm2_run() {
                            sudo -u "$DEPLOY_OS_USER" -H env \
                                "PORT=${nuxt_port}" "HOST=127.0.0.1" \
                                pm2 "$@"
                        }
                        pm2_run delete "${DEPLOY_DOMAIN}" 2>/dev/null || true

                        # Nuxt 3 builds to .output/server/index.mjs
                        if [[ -f "${local_root}/.output/server/index.mjs" ]]; then
                            pm2_run start "${local_root}/.output/server/index.mjs" \
                                --name "${DEPLOY_DOMAIN}" \
                                --cwd "${local_root}"
                        elif [[ -f "${local_root}/.output/server/index.js" ]]; then
                            pm2_run start "${local_root}/.output/server/index.js" \
                                --name "${DEPLOY_DOMAIN}" \
                                --cwd "${local_root}"
                        else
                            # Nuxt 2 / custom start script fallback
                            pm2_run start npm --name "${DEPLOY_DOMAIN}" --cwd "${local_root}" -- start
                        fi
                        pm2_run save
                        pm2 startup systemd -u "$DEPLOY_OS_USER" --hp "$project_dir" 2>/dev/null | grep -v "^\[PM2\]" || true
                        sre_success "PM2 process started: ${DEPLOY_DOMAIN} on :${nuxt_port} (user $DEPLOY_OS_USER)"
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
                    sre_info "Running: npm install..."
                    deploy_as_user "$local_root" "npm install" 2>&1 | tail -3
                    sre_info "Running: npm run build..."
                    deploy_as_user "$local_root" "npm run build" 2>&1 | tail -5
                    sre_success "Vue built to dist/"
                else
                    sre_skipped "npm install/build"
                fi
            fi
            ;;

        wordpress)
            sre_info "Configuring WordPress..."

            wp_table_prefix=$(prompt_input "WordPress table prefix" "wp_")

            # Generate wp-config.php from sample if missing
            wp_config="${local_root}/wp-config.php"
            wp_sample="${local_root}/wp-config-sample.php"

            if [[ ! -f "$wp_config" ]] && [[ "$needs_db" == "true" ]]; then
                if [[ -f "$wp_sample" ]]; then
                    cp "$wp_sample" "$wp_config"
                    sre_info "Created wp-config.php from wp-config-sample.php"
                else
                    sre_warning "No wp-config-sample.php found — generating minimal wp-config.php"
                    cat > "$wp_config" <<'WP_HEADER'
<?php
define('DB_NAME',     '__DB_NAME__');
define('DB_USER',     '__DB_USER__');
define('DB_PASSWORD', '__DB_PASS__');
define('DB_HOST',     'localhost');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

define('AUTH_KEY',         '__AUTH_KEY__');
define('SECURE_AUTH_KEY',  '__SECURE_AUTH_KEY__');
define('LOGGED_IN_KEY',    '__LOGGED_IN_KEY__');
define('NONCE_KEY',        '__NONCE_KEY__');
define('AUTH_SALT',        '__AUTH_SALT__');
define('SECURE_AUTH_SALT', '__SECURE_AUTH_SALT__');
define('LOGGED_IN_SALT',   '__LOGGED_IN_SALT__');
define('NONCE_SALT',       '__NONCE_SALT__');

$table_prefix = 'wp_';

define('WP_DEBUG', false);

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
WP_HEADER
                fi
            fi

            if [[ -f "$wp_config" ]] && [[ "$needs_db" == "true" ]]; then
                # DB credentials
                sed -i "s|define( *['\"]DB_NAME['\"] *,.*|define('DB_NAME', '${DEPLOY_DB_NAME}');|" "$wp_config"
                sed -i "s|define( *['\"]DB_USER['\"] *,.*|define('DB_USER', '${DEPLOY_DB_USER}');|" "$wp_config"
                sed -i "s|define( *['\"]DB_PASSWORD['\"] *,.*|define('DB_PASSWORD', '${DEPLOY_DB_PASS}');|" "$wp_config"
                # WordPress takes host:port in a single DB_HOST constant.
                _wp_db_host="$(db_client_host_legacy)"
                if db_is_remote; then
                    _wp_db_host="${_wp_db_host}:$(db_client_port)"
                fi
                sed -i "s|define( *['\"]DB_HOST['\"] *,.*|define('DB_HOST', '${_wp_db_host}');|" "$wp_config"
                sed -i "s|define( *['\"]DB_CHARSET['\"] *,.*|define('DB_CHARSET', 'utf8mb4');|" "$wp_config"

                # Table prefix
                sed -i "s|^\$table_prefix *=.*|\$table_prefix = '${wp_table_prefix}';|" "$wp_config"

                # Replace fallback placeholders if minimal config was generated
                sed -i "s|__DB_NAME__|${DEPLOY_DB_NAME}|g" "$wp_config"
                sed -i "s|__DB_USER__|${DEPLOY_DB_USER}|g" "$wp_config"
                sed -i "s|__DB_PASS__|${DEPLOY_DB_PASS}|g" "$wp_config"

                # Generate unique salt keys (8 keys)
                for salt_key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                                AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
                    salt_val=$(openssl rand -base64 64 | tr -d '\n' | tr -d '"' | tr -d "'" | tr -d '\\' | cut -c1-64)
                    # Replace both real-config style placeholder ('put your...here')
                    # and our minimal-config placeholder (__AUTH_KEY__ etc.)
                    sed -i "s|define( *['\"]${salt_key}['\"] *,.*|define('${salt_key}', '${salt_val}');|" "$wp_config"
                    sed -i "s|__${salt_key}__|${salt_val}|g" "$wp_config"
                done

                sre_success "wp-config.php configured (DB + unique salts, prefix: ${wp_table_prefix})"
            elif [[ "$needs_db" != "true" ]]; then
                sre_warning "No database — wp-config.php skipped (manual setup required)"
            fi
            ;;

        static)
            sre_info "Static site — no build step needed"
            sre_info "Files served directly from: ${local_root}"
            # If repo has a build script, optionally run it
            if [[ -f "${local_root}/package.json" ]]; then
                if prompt_yesno "Found package.json — run npm install && npm run build?" "no"; then
                    deploy_as_user "$local_root" "npm install" 2>&1 | tail -3
                    deploy_as_user "$local_root" "npm run build" 2>&1 | tail -5
                    sre_success "Static site built"
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
    # Isolated scheme: owner p-<key>, dirs 750 / files 640, secrets 600,
    # legacy www-data/root ACLs stripped. Web server reads via the project group.
    if [[ "$DEPLOY_TYPE" == "moodle" ]]; then
        iso_apply_perms "$DEPLOY_DOMAIN" "$project_dir" "$DEPLOY_TYPE" "${DEPLOY_MOODLEDATA_DIR:-}"
    else
        iso_apply_perms "$DEPLOY_DOMAIN" "$project_dir" "$DEPLOY_TYPE"
    fi
else
    sre_info "[DRY-RUN] Would apply isolated permissions on $project_dir (owner $DEPLOY_OS_USER)"
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
user=${DEPLOY_OS_USER}
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
user=${DEPLOY_OS_USER}
numprocs=${worker_processes}
redirect_stderr=true
stdout_logfile=${project_dir}/current/storage/logs/worker.log
stopwaitsecs=3600
WORKEREOF
                sre_success "Queue worker config: ${supervisor_conf_dir}/${DEPLOY_DOMAIN}-worker.conf"
            fi

            # Scheduler cron
            if prompt_yesno "Also setup Laravel scheduler cron?" "yes"; then
                cron_line="* * * * * ${DEPLOY_OS_USER} cd ${project_dir}/current && php artisan schedule:run >> /dev/null 2>&1"
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
