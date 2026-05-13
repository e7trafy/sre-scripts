#!/bin/bash
################################################################################
# SRE Helpers - Step 16: Clone Project (Staging Copy)
#
# Clones an existing provisioned site on this server into a new project under
# a different domain. Useful for spinning up a staging copy of production.
#
# What it does:
#   1. Detect source project type (laravel/moodle/wordpress/nuxt/vue/static)
#      and its document root from the existing vhost.
#   2. Copy files via rsync (handles release/current symlink layout).
#   3. Copy database into a fresh DB + user with a new generated password.
#   4. Rewrite app config for the new domain + DB:
#        Laravel    → .env (DB_*, APP_URL, APP_KEY refresh optional)
#        WordPress  → wp-config.php DB_* + ${prefix}options.siteurl/home
#        Moodle     → config.php wwwroot/dataroot/DB + ${prefix}config.wwwroot
#   5. Create a new vhost (delegates to step 8 --yes).
#   6. Fix permissions.
#   7. Offer SSL via step 11.
#
# What it does NOT do:
#   - Touch DNS (you point the new domain at this server yourself, or use the
#     same wildcard cert + a *.staging.<base> name).
#   - Touch the source files or source database. The clone is read-only on the
#     source side.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=16

CL_SOURCE_DOMAIN=""
CL_TARGET_DOMAIN=""
CL_MODE="full"      # full, files-only, db-only
CL_REGEN_APP_KEY="ask"   # laravel only: ask|yes|no

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 16: Clone Project (Staging Copy)

  Copies an existing provisioned site on this server into a new project under
  a different domain. Files + database get cloned, app config is rewritten
  for the new domain, a new vhost is created.

Options:
  --source <domain>     Source domain to clone (or prompted)
  --target <domain>     Target domain for the clone (or prompted)
  --mode <mode>         full | files-only | db-only       (default: full)
  --regen-app-key       Laravel: generate a fresh APP_KEY in the clone
  --keep-app-key        Laravel: reuse the source APP_KEY
  --dry-run             Print planned actions only
  --yes                 Accept defaults without prompting
  --help                Show this help

Examples:
  sudo bash $0
  sudo bash $0 --source app.example.com --target staging.example.com
  sudo bash $0 --source shop.example.com --target shop-stage.example.com --mode files-only
EOF
}

_raw_args=("$@")
sre_parse_args "16-clone-project.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --source)         _i=$((_i + 1)); CL_SOURCE_DOMAIN="${_raw_args[$_i]:-}" ;;
        --target)         _i=$((_i + 1)); CL_TARGET_DOMAIN="${_raw_args[$_i]:-}" ;;
        --mode)           _i=$((_i + 1)); CL_MODE="${_raw_args[$_i]:-full}" ;;
        --regen-app-key)  CL_REGEN_APP_KEY="yes" ;;
        --keep-app-key)   CL_REGEN_APP_KEY="no" ;;
    esac
    _i=$((_i + 1))
done

require_root
sre_header "Step 16: Clone Project (Staging Copy)"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")
db_engines_config=$(config_get "SRE_DB_ENGINE" "none")

if [[ -z "$web_server" ]]; then
    sre_error "Web server not configured. Run step 3 first."
    exit 2
fi

################################################################################
# Pick source domain
################################################################################

vhost_dir=$(get_vhost_dir "$web_server")

if [[ -z "$CL_SOURCE_DOMAIN" ]]; then
    sre_header "Pick Source Project"
    avail=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        d=$(basename "$f" .conf)
        [[ "$d" == "default" || "$d" == "000-default" || "$d" == "security" ]] && continue
        avail+=("$d")
    done < <(ls -1 "$vhost_dir"/*.conf 2>/dev/null | sort)

    if [[ ${#avail[@]} -eq 0 ]]; then
        sre_error "No vhosts found in $vhost_dir — nothing to clone."
        exit 2
    fi

    CL_SOURCE_DOMAIN=$(prompt_choice "Source domain to clone:" "${avail[@]}")
fi
[[ -z "$CL_SOURCE_DOMAIN" ]] && { sre_error "Source domain required"; exit 1; }

src_vhost="${vhost_dir}/${CL_SOURCE_DOMAIN}.conf"
[[ -f "$src_vhost" ]] || { sre_error "Source vhost not found: $src_vhost"; exit 2; }

sre_info "Source domain: $CL_SOURCE_DOMAIN"

################################################################################
# Detect source project type + root
################################################################################

# Document root from existing vhost
src_doc_root=""
case "$web_server" in
    nginx)  src_doc_root=$(grep -m1 '^\s*root ' "$src_vhost" | awk '{print $2}' | tr -d ';') ;;
    apache) src_doc_root=$(grep -im1 'DocumentRoot' "$src_vhost" | awk '{print $2}' | tr -d '"') ;;
esac

if [[ -z "$src_doc_root" || ! -d "$src_doc_root" ]]; then
    sre_warning "Could not auto-detect doc root from vhost (got: $src_doc_root)"
    src_doc_root=$(prompt_input "Source document root" "/var/www/${CL_SOURCE_DOMAIN}/current")
fi

# Project base on disk = /var/www/<domain>
src_proj_base="/var/www/${CL_SOURCE_DOMAIN}"

# Detect type: try config files first, then vhost markers
src_type=""
# laravel: doc_root ends in /current/public → release layout
if [[ -f "${src_proj_base}/current/artisan" ]]; then
    src_type="laravel"
elif [[ -f "${src_doc_root}/wp-config.php" ]]; then
    src_type="wordpress"
elif [[ -f "${src_doc_root}/config.php" ]] && grep -q '\$CFG->dbtype' "${src_doc_root}/config.php" 2>/dev/null; then
    src_type="moodle"
elif grep -q 'proxy_pass.*127\.0\.0\.1' "$src_vhost" 2>/dev/null; then
    src_type="nuxt"
elif grep -q 'try_files.*index\.html' "$src_vhost" 2>/dev/null; then
    src_type="vue"
else
    src_type="static"
fi

sre_info "Detected type: $src_type"
sre_info "Source root:   $src_proj_base"
sre_info "Source doc:    $src_doc_root"

################################################################################
# Mode
################################################################################

case "$CL_MODE" in
    full|files-only|db-only) ;;
    *) sre_error "Invalid mode: $CL_MODE"; exit 1 ;;
esac

# Project types without a DB can't do db-only / their full is files-only
case "$src_type" in
    nuxt|vue|static)
        if [[ "$CL_MODE" == "db-only" ]]; then
            sre_error "Project type $src_type has no database — db-only doesn't apply."
            exit 1
        fi
        CL_MODE="files-only"
        ;;
esac

do_files=false; do_db=false
case "$CL_MODE" in
    full)       do_files=true; do_db=true ;;
    files-only) do_files=true ;;
    db-only)    do_db=true ;;
esac

sre_info "Mode: $CL_MODE  (files=$do_files, db=$do_db)"

################################################################################
# Target domain
################################################################################

if [[ -z "$CL_TARGET_DOMAIN" ]]; then
    default_target="${CL_SOURCE_DOMAIN%%.*}-stage.${CL_SOURCE_DOMAIN#*.}"
    CL_TARGET_DOMAIN=$(prompt_input "Target domain for the clone" "$default_target")
fi
[[ -z "$CL_TARGET_DOMAIN" ]] && { sre_error "Target domain required"; exit 1; }

if [[ "$CL_TARGET_DOMAIN" == "$CL_SOURCE_DOMAIN" ]]; then
    sre_error "Target must differ from source."
    exit 1
fi

tgt_vhost="${vhost_dir}/${CL_TARGET_DOMAIN}.conf"
tgt_proj_base="/var/www/${CL_TARGET_DOMAIN}"

# Refuse to overwrite an existing target unless user confirms
if [[ -d "$tgt_proj_base" || -f "$tgt_vhost" ]]; then
    sre_warning "Target already exists: $tgt_proj_base (or vhost $tgt_vhost)"
    if ! prompt_yesno "Overwrite the existing target? (DESTRUCTIVE)" "no"; then
        sre_skipped "Clone cancelled — target exists."
        exit 4
    fi
fi

# Mirror source paths into target
case "$src_type" in
    laravel)   tgt_doc_root="${tgt_proj_base}/current/public" ;;
    moodle)    tgt_doc_root="${tgt_proj_base}/public_html" ;;
    wordpress) tgt_doc_root="${tgt_proj_base}/current" ;;
    nuxt)      tgt_doc_root="${tgt_proj_base}/current" ;;
    vue)       tgt_doc_root="${tgt_proj_base}/current/dist" ;;
    static)    tgt_doc_root="${tgt_proj_base}/current" ;;
esac

sre_info "Target root:   $tgt_proj_base"
sre_info "Target doc:    $tgt_doc_root"

################################################################################
# Detect source DB creds (laravel/wordpress/moodle)
################################################################################

src_db_engine=""
src_db_name=""
src_db_user=""
src_db_pass=""
moodle_prefix="mdl_"
wp_prefix="wp_"

if [[ "$do_db" == "true" ]]; then
    case "$src_type" in
        laravel)
            envf="${src_proj_base}/current/.env"
            [[ -f "$envf" ]] || envf="${src_proj_base}/shared/.env"
            if [[ -f "$envf" ]]; then
                src_db_name=$(grep -m1 '^DB_DATABASE=' "$envf" | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' | tr -d "'")
                src_db_user=$(grep -m1 '^DB_USERNAME=' "$envf" | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' | tr -d "'")
                src_db_pass=$(grep -m1 '^DB_PASSWORD=' "$envf" | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' | tr -d "'")
                conn=$(grep -m1 '^DB_CONNECTION=' "$envf" | cut -d= -f2- | tr -d '"' | tr -d "'")
                case "$conn" in
                    mysql|mariadb) src_db_engine="mariadb" ;;
                    pgsql|postgres|postgresql) src_db_engine="postgresql" ;;
                    *) src_db_engine="" ;;
                esac
            fi
            ;;
        wordpress)
            wpc="${src_doc_root}/wp-config.php"
            if [[ -f "$wpc" ]]; then
                src_db_name=$(grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" | head -1)
                src_db_user=$(grep -oP "define\(\s*['\"]DB_USER['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" | head -1)
                src_db_pass=$(grep -oP "define\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" | head -1)
                src_db_engine="mariadb"   # WP is mysql/mariadb
                pf=$(grep -oP "^\s*\\\$table_prefix\s*=\s*['\"]?\K[^'\"]+" "$wpc" | head -1)
                wp_prefix="${pf:-wp_}"
            fi
            ;;
        moodle)
            mcf="${src_doc_root}/config.php"
            if [[ -f "$mcf" ]]; then
                src_db_name=$(grep -oP "\\\$CFG->dbname\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" | head -1)
                src_db_user=$(grep -oP "\\\$CFG->dbuser\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" | head -1)
                src_db_pass=$(grep -oP "\\\$CFG->dbpass\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" | head -1)
                pf=$(grep -oP "\\\$CFG->prefix\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" | head -1)
                moodle_prefix="${pf:-mdl_}"
                dbt=$(grep -oP "\\\$CFG->dbtype\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" | head -1)
                case "$dbt" in
                    mariadb|mysqli|mysql) src_db_engine="mariadb" ;;
                    pgsql)                src_db_engine="postgresql" ;;
                    *)                    src_db_engine="mariadb" ;;
                esac
            fi
            ;;
    esac

    if [[ -z "$src_db_name" ]]; then
        sre_warning "Could not auto-detect source DB credentials."
        src_db_name=$(prompt_input "Source DB name" "")
        src_db_user=$(prompt_input "Source DB user" "")
        src_db_pass=$(prompt_input "Source DB password" "")
        [[ -z "$src_db_engine" ]] && src_db_engine=$(prompt_choice "Source DB engine:" "mariadb" "mysql" "postgresql")
    fi

    sre_info "Source DB:     ${src_db_name} (${src_db_engine})"
fi

################################################################################
# Target DB plan
################################################################################

# Build a new DB name + user (truncate at 32 chars for mysql limits; 16 for user)
ts=$(date +%y%m%d%H%M)
_san() { echo "$1" | tr '.-' '_' | tr '[:upper:]' '[:lower:]'; }
tgt_db_base="$(_san "${CL_TARGET_DOMAIN%%.*}")"
tgt_db_name="${tgt_db_base}_clone_${ts}"
tgt_db_name="${tgt_db_name:0:60}"
tgt_db_user="${tgt_db_base}_c${ts: -6}"
tgt_db_user="${tgt_db_user:0:32}"
tgt_db_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

if [[ "$do_db" == "true" ]]; then
    sre_info "Target DB:     ${tgt_db_name}"
    sre_info "Target DB user:${tgt_db_user}"
fi

################################################################################
# Summary + confirm
################################################################################

sre_header "Clone Plan"
sre_info "  Source domain: $CL_SOURCE_DOMAIN"
sre_info "  Target domain: $CL_TARGET_DOMAIN"
sre_info "  Type:          $src_type"
sre_info "  Mode:          $CL_MODE"
if [[ "$do_files" == "true" ]]; then
    sre_info "  Files: $src_proj_base  →  $tgt_proj_base"
fi
if [[ "$do_db" == "true" ]]; then
    sre_info "  DB:    $src_db_name  →  $tgt_db_name"
fi

if ! prompt_yesno "Proceed with cloning?" "yes"; then
    sre_skipped "Clone cancelled by user."
    exit 0
fi

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] No further actions."
    exit 0
fi

################################################################################
# COPY FILES
################################################################################

if [[ "$do_files" == "true" ]]; then
    sre_header "Copying Files"

    mkdir -p "$tgt_proj_base"

    case "$src_type" in
        laravel)
            # Source uses release-based layout: copy releases/* + shared, rebuild current symlink
            tgt_release_dir="${tgt_proj_base}/releases/$(date +%Y%m%d%H%M%S)"
            mkdir -p "$tgt_release_dir" "${tgt_proj_base}/shared"

            # Resolve actual source files (current -> releases/X)
            src_release_actual=$(readlink -f "${src_proj_base}/current" 2>/dev/null || echo "${src_proj_base}/current")
            sre_info "Copying release content: ${src_release_actual}/ → ${tgt_release_dir}/"
            rsync -aH --info=progress2 "${src_release_actual}/" "${tgt_release_dir}/"

            # Copy shared (mostly .env + storage)
            if [[ -d "${src_proj_base}/shared" ]]; then
                sre_info "Copying shared/ → ${tgt_proj_base}/shared/"
                rsync -aH "${src_proj_base}/shared/" "${tgt_proj_base}/shared/"
            fi

            # current symlink
            ln -sfn "$tgt_release_dir" "${tgt_proj_base}/current"
            sre_success "Laravel release copied + symlinked"
            ;;

        moodle)
            sre_info "Copying ${src_proj_base}/ → ${tgt_proj_base}/ (excluding moodledata)"
            # Don't copy moodledata directly — find its actual location from config
            mdldata=""
            if [[ -f "${src_doc_root}/config.php" ]]; then
                mdldata=$(grep -oP "\\\$CFG->dataroot\s*=\s*['\"]?\K[^'\";\s]+" "${src_doc_root}/config.php" | head -1)
            fi
            rsync_excludes=()
            if [[ -n "$mdldata" && "$mdldata" == "${src_proj_base}/"* ]]; then
                rel_mdldata="${mdldata#${src_proj_base}/}"
                rsync_excludes+=("--exclude=${rel_mdldata}")
                sre_info "Excluding internal moodledata: $rel_mdldata"
            fi
            rsync -aH --info=progress2 "${rsync_excludes[@]}" "${src_proj_base}/" "${tgt_proj_base}/"

            # Copy moodledata separately (it can be huge — ask)
            tgt_mdldata="${tgt_proj_base}/moodledata"
            if findmnt -n "/u02/appdata" &>/dev/null; then
                tgt_mdldata="/u02/appdata/${CL_TARGET_DOMAIN}/moodledata"
            fi
            if [[ -n "$mdldata" && -d "$mdldata" ]]; then
                if prompt_yesno "Copy moodledata ($(du -sh "$mdldata" 2>/dev/null | cut -f1)) to ${tgt_mdldata}?" "yes"; then
                    mkdir -p "$tgt_mdldata"
                    rsync -aH --info=progress2 "${mdldata}/" "${tgt_mdldata}/"
                    sre_success "Moodledata copied"
                else
                    mkdir -p "$tgt_mdldata"
                    sre_warning "Empty moodledata at $tgt_mdldata — clone will not have user files"
                fi
            else
                mkdir -p "$tgt_mdldata"
            fi
            # Stash for later config rewrite
            CL_TGT_MOODLEDATA="$tgt_mdldata"
            ;;

        wordpress|nuxt|vue|static)
            # Same release layout as deploy/migrate scripts when available
            if [[ -d "${src_proj_base}/current" && ! -L "${src_proj_base}/current" ]]; then
                # Edge case: current is a real dir not a symlink — copy as-is
                sre_info "Copying ${src_proj_base}/ → ${tgt_proj_base}/ (flat layout)"
                rsync -aH --info=progress2 "${src_proj_base}/" "${tgt_proj_base}/"
            elif [[ -L "${src_proj_base}/current" ]]; then
                src_release_actual=$(readlink -f "${src_proj_base}/current")
                tgt_release_dir="${tgt_proj_base}/releases/$(date +%Y%m%d%H%M%S)"
                mkdir -p "$tgt_release_dir"
                sre_info "Copying ${src_release_actual}/ → ${tgt_release_dir}/"
                rsync -aH --info=progress2 "${src_release_actual}/" "${tgt_release_dir}/"
                ln -sfn "$tgt_release_dir" "${tgt_proj_base}/current"
            else
                # No release layout — copy doc_root contents
                mkdir -p "${tgt_proj_base}/current"
                sre_info "Copying ${src_doc_root}/ → ${tgt_proj_base}/current/"
                rsync -aH --info=progress2 "${src_doc_root}/" "${tgt_proj_base}/current/"
            fi
            ;;
    esac

    chown -R www-data:www-data "$tgt_proj_base"
    sre_success "Files copied to $tgt_proj_base"
fi

################################################################################
# COPY DATABASE
################################################################################

if [[ "$do_db" == "true" ]]; then
    sre_header "Copying Database"

    db_root_pass=""
    [[ -f /root/.db_root_password ]] && db_root_pass=$(cat /root/.db_root_password)

    case "$src_db_engine" in
        mariadb|mysql)
            mysql_cmd="mysql"
            mysqldump_cmd="mysqldump"
            if [[ -n "$db_root_pass" ]]; then
                mysql_cmd="mysql -u root -p${db_root_pass}"
                mysqldump_cmd="mysqldump -u root -p${db_root_pass}"
            fi

            # Create target DB + user (idempotent)
            $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${tgt_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
                || { sre_error "Failed creating database ${tgt_db_name}"; exit 1; }
            $mysql_cmd -e "CREATE USER IF NOT EXISTS '${tgt_db_user}'@'localhost' IDENTIFIED BY '${tgt_db_pass}';" 2>/dev/null
            $mysql_cmd -e "ALTER USER '${tgt_db_user}'@'localhost' IDENTIFIED BY '${tgt_db_pass}';" 2>/dev/null
            $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${tgt_db_name}\`.* TO '${tgt_db_user}'@'localhost';" 2>/dev/null
            $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null
            sre_success "Target DB + user created: ${tgt_db_name} / ${tgt_db_user}"

            # Dump source → import target. Stream through gzip to keep tmp footprint small.
            sre_info "Dumping ${src_db_name} → importing into ${tgt_db_name}..."
            $mysqldump_cmd --single-transaction --quick --routines --triggers \
                "$src_db_name" | $mysql_cmd "$tgt_db_name"
            sre_success "Database copied"
            ;;

        postgresql)
            sudo -u postgres psql -c "DO \$\$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${tgt_db_user}') THEN
                    CREATE ROLE ${tgt_db_user} WITH LOGIN PASSWORD '${tgt_db_pass}';
                ELSE
                    ALTER ROLE ${tgt_db_user} WITH LOGIN PASSWORD '${tgt_db_pass}';
                END IF;
            END \$\$;" 2>/dev/null
            sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$tgt_db_name" \
                || sudo -u postgres createdb -O "$tgt_db_user" "$tgt_db_name"
            sre_success "Target role/db created: ${tgt_db_name} / ${tgt_db_user}"

            sre_info "Dumping ${src_db_name} → importing into ${tgt_db_name}..."
            sudo -u postgres pg_dump "$src_db_name" | sudo -u postgres psql "$tgt_db_name" >/dev/null
            sre_success "Database copied"
            ;;

        *)
            sre_error "Unsupported source DB engine: $src_db_engine"
            exit 1
            ;;
    esac
fi

################################################################################
# Rewrite app config for new domain + DB
################################################################################

if [[ "$do_files" == "true" || "$do_db" == "true" ]]; then
    sre_header "Rewriting App Config"

    case "$src_type" in
        laravel)
            tgt_env="${tgt_proj_base}/current/.env"
            # Prefer shared/.env if present (release layout)
            [[ -f "${tgt_proj_base}/shared/.env" ]] && tgt_env="${tgt_proj_base}/shared/.env"
            if [[ -f "$tgt_env" ]]; then
                cp "$tgt_env" "${tgt_env}.preclone.bak"
                if [[ "$do_db" == "true" ]]; then
                    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${tgt_db_name}|" "$tgt_env"
                    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${tgt_db_user}|" "$tgt_env"
                    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${tgt_db_pass}|" "$tgt_env"
                    sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "$tgt_env"
                fi
                sed -i "s|^APP_URL=.*|APP_URL=http://${CL_TARGET_DOMAIN}|" "$tgt_env"
                # Mark as a clone for sanity
                if grep -q '^APP_ENV=' "$tgt_env"; then
                    sed -i "s|^APP_ENV=.*|APP_ENV=staging|" "$tgt_env"
                else
                    echo "APP_ENV=staging" >> "$tgt_env"
                fi
                sre_success ".env rewritten: $tgt_env"

                # APP_KEY: regen or keep
                if [[ "$CL_REGEN_APP_KEY" == "ask" ]]; then
                    if prompt_yesno "Generate a fresh APP_KEY for the clone? (sessions/cookies from source become unusable)" "yes"; then
                        CL_REGEN_APP_KEY="yes"
                    else
                        CL_REGEN_APP_KEY="no"
                    fi
                fi
                if [[ "$CL_REGEN_APP_KEY" == "yes" ]] && command -v php &>/dev/null; then
                    ( cd "${tgt_proj_base}/current" && sudo -u www-data php artisan key:generate --force --no-interaction ) \
                        && sre_success "APP_KEY regenerated" \
                        || sre_warning "APP_KEY regen failed — run manually"
                else
                    sre_info "APP_KEY preserved from source"
                fi

                # Cache rebuild
                if command -v php &>/dev/null && [[ -f "${tgt_proj_base}/current/artisan" ]]; then
                    ( cd "${tgt_proj_base}/current"
                      sudo -u www-data php artisan config:clear >/dev/null 2>&1 || true
                      sudo -u www-data php artisan cache:clear  >/dev/null 2>&1 || true
                      sudo -u www-data php artisan view:clear   >/dev/null 2>&1 || true
                    )
                    sre_success "Laravel caches cleared"
                fi
            fi
            ;;

        wordpress)
            tgt_wpc="${tgt_proj_base}/current/wp-config.php"
            if [[ -f "$tgt_wpc" ]]; then
                cp "$tgt_wpc" "${tgt_wpc}.preclone.bak"
                if [[ "$do_db" == "true" ]]; then
                    sed -i "s|define( *['\"]DB_NAME['\"] *,.*|define('DB_NAME', '${tgt_db_name}');|" "$tgt_wpc"
                    sed -i "s|define( *['\"]DB_USER['\"] *,.*|define('DB_USER', '${tgt_db_user}');|" "$tgt_wpc"
                    sed -i "s|define( *['\"]DB_PASSWORD['\"] *,.*|define('DB_PASSWORD', '${tgt_db_pass}');|" "$tgt_wpc"
                    sed -i "s|define( *['\"]DB_HOST['\"] *,.*|define('DB_HOST', 'localhost');|" "$tgt_wpc"
                fi
                sre_success "wp-config.php rewritten"

                # Update siteurl + home in cloned DB
                if [[ "$do_db" == "true" ]]; then
                    $mysql_cmd "$tgt_db_name" -e \
                        "UPDATE \`${wp_prefix}options\` SET option_value='http://${CL_TARGET_DOMAIN}' WHERE option_name IN ('siteurl','home');" 2>/dev/null \
                        && sre_success "WP siteurl/home → http://${CL_TARGET_DOMAIN}" \
                        || sre_warning "Could not update WP siteurl (run wp-cli search-replace manually)"
                fi
            fi
            ;;

        moodle)
            tgt_mcf="${tgt_proj_base}/public_html/config.php"
            if [[ -f "$tgt_mcf" ]]; then
                cp "$tgt_mcf" "${tgt_mcf}.preclone.bak"
                if [[ "$do_db" == "true" ]]; then
                    # Update dbname/dbuser/dbpass — keep dbtype/prefix
                    sed -i "s|\(\$CFG->dbname\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_name}'|" "$tgt_mcf"
                    sed -i "s|\(\$CFG->dbuser\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_user}'|" "$tgt_mcf"
                    sed -i "s|\(\$CFG->dbpass\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_pass}'|" "$tgt_mcf"
                fi
                # wwwroot + dataroot for new domain
                sed -i "s|\(\$CFG->wwwroot\s*=\s*\)['\"][^'\"]*['\"]|\1'http://${CL_TARGET_DOMAIN}'|" "$tgt_mcf"
                if [[ -n "${CL_TGT_MOODLEDATA:-}" ]]; then
                    sed -i "s|\(\$CFG->dataroot\s*=\s*\)['\"][^'\"]*['\"]|\1'${CL_TGT_MOODLEDATA}'|" "$tgt_mcf"
                fi
                sre_success "Moodle config.php rewritten"

                # Update wwwroot in mdl_config
                if [[ "$do_db" == "true" ]]; then
                    $mysql_cmd "$tgt_db_name" -e \
                        "UPDATE \`${moodle_prefix}config\` SET value='http://${CL_TARGET_DOMAIN}' WHERE name='wwwroot';" 2>/dev/null \
                        && sre_success "Moodle DB wwwroot → http://${CL_TARGET_DOMAIN}" \
                        || sre_warning "Could not update mdl_config.wwwroot"

                    # Purge caches table contents so first request rebuilds
                    $mysql_cmd "$tgt_db_name" -e "DELETE FROM \`${moodle_prefix}config_plugins\` WHERE name='version' AND plugin LIKE 'cache%';" 2>/dev/null || true
                fi
            fi
            ;;

        nuxt|vue|static)
            sre_info "$src_type: no app config rewrite needed (static/HTML)"
            ;;
    esac
fi

################################################################################
# Create new vhost via step 8
################################################################################

sre_header "Creating Vhost for Target Domain"

# Pick a unique Nuxt port if needed
vhost_args=( --domain "$CL_TARGET_DOMAIN" --type "$src_type" --yes )

if [[ "$src_type" == "nuxt" ]]; then
    # Source port from source vhost; pick next free
    src_port=$(grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "$src_vhost" | head -1)
    src_port="${src_port:-3000}"
    new_port=$((src_port + 1))
    while ss -tlnp 2>/dev/null | grep -q ":${new_port} " ; do
        new_port=$((new_port + 1))
        [[ $new_port -gt 65000 ]] && { sre_error "No free port"; exit 1; }
    done
    sre_info "Source Nuxt port: $src_port → target: $new_port"
    vhost_args+=( --port "$new_port" --root "$tgt_doc_root" )
    CL_TGT_PORT="$new_port"
else
    vhost_args+=( --root "$tgt_doc_root" )
fi

bash "${SRE_SCRIPTS_DIR}/vhost/08-vhost.sh" "${vhost_args[@]}" \
    || { sre_error "Vhost creation failed"; exit 1; }

################################################################################
# Type-specific finishing touches
################################################################################

case "$src_type" in
    nuxt)
        # If PM2 available, start the clone with its own name + port
        if command -v pm2 &>/dev/null && [[ -d "${tgt_proj_base}/current" ]]; then
            entry=""
            for f in .output/server/index.mjs .output/server/index.js; do
                [[ -f "${tgt_proj_base}/current/$f" ]] && { entry="${tgt_proj_base}/current/$f"; break; }
            done
            if [[ -n "$entry" ]]; then
                pm2 delete "$CL_TARGET_DOMAIN" 2>/dev/null || true
                PORT="${CL_TGT_PORT:-3001}" pm2 start "$entry" \
                    --name "$CL_TARGET_DOMAIN" \
                    --cwd "${tgt_proj_base}/current" \
                    --update-env
                pm2 save
                sre_success "PM2 started: ${CL_TARGET_DOMAIN} on port ${CL_TGT_PORT}"
            else
                sre_warning "No Nuxt build artifact found — run npm install && npm run build in ${tgt_proj_base}/current"
            fi
        fi
        ;;
    laravel)
        # Storage symlink (in case source didn't have one cached)
        if [[ -f "${tgt_proj_base}/current/artisan" ]]; then
            ( cd "${tgt_proj_base}/current" && sudo -u www-data php artisan storage:link --no-interaction 2>/dev/null || true )
        fi
        ;;
esac

################################################################################
# Fix permissions
################################################################################

sre_header "Fix Permissions"

require_acl

chown -R www-data:www-data "$tgt_proj_base"
find "$tgt_proj_base" -type d -exec chmod 755 {} \;
find "$tgt_proj_base" -type f -exec chmod 644 {} \;
setfacl -R -m u:www-data:rwX -m d:u:www-data:rwX "$tgt_proj_base"

case "$src_type" in
    laravel)
        for wd in "${tgt_proj_base}/current/storage" "${tgt_proj_base}/current/bootstrap/cache" "${tgt_proj_base}/shared/storage"; do
            [[ -d "$wd" ]] && chmod -R 775 "$wd"
        done
        [[ -f "${tgt_proj_base}/current/.env" ]] && chmod 640 "${tgt_proj_base}/current/.env"
        [[ -f "${tgt_proj_base}/shared/.env" ]]  && chmod 640 "${tgt_proj_base}/shared/.env"
        [[ -f "${tgt_proj_base}/current/artisan" ]] && chmod 755 "${tgt_proj_base}/current/artisan"
        ;;
    moodle)
        [[ -f "${tgt_proj_base}/public_html/config.php" ]] && chmod 640 "${tgt_proj_base}/public_html/config.php"
        if [[ -n "${CL_TGT_MOODLEDATA:-}" && -d "$CL_TGT_MOODLEDATA" ]]; then
            chown -R www-data:www-data "$CL_TGT_MOODLEDATA"
            chmod -R 2770 "$CL_TGT_MOODLEDATA"
            setfacl -R -m u:www-data:rwX -m d:u:www-data:rwX "$CL_TGT_MOODLEDATA"
        fi
        ;;
    wordpress)
        if [[ -d "${tgt_proj_base}/current/wp-content" ]]; then
            chmod -R 775 "${tgt_proj_base}/current/wp-content"
            setfacl -R -m u:www-data:rwX -m d:u:www-data:rwX "${tgt_proj_base}/current/wp-content"
        fi
        [[ -f "${tgt_proj_base}/current/wp-config.php" ]] && chmod 640 "${tgt_proj_base}/current/wp-config.php"
        ;;
esac

sre_success "Permissions applied"

################################################################################
# Save clone state
################################################################################

mkdir -p /etc/sre-helpers/clones
clone_state="/etc/sre-helpers/clones/${CL_TARGET_DOMAIN}.conf"
{
    printf '# Clone created %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'CL_SOURCE_DOMAIN=%q\n'  "$CL_SOURCE_DOMAIN"
    printf 'CL_TARGET_DOMAIN=%q\n'  "$CL_TARGET_DOMAIN"
    printf 'CL_PROJECT_TYPE=%q\n'   "$src_type"
    printf 'CL_MODE=%q\n'           "$CL_MODE"
    printf 'CL_TGT_DB_NAME=%q\n'    "${tgt_db_name:-}"
    printf 'CL_TGT_DB_USER=%q\n'    "${tgt_db_user:-}"
    printf 'CL_TGT_DB_PASS=%q\n'    "${tgt_db_pass:-}"
    printf 'CL_TGT_PORT=%q\n'       "${CL_TGT_PORT:-}"
    printf 'CL_TGT_MOODLEDATA=%q\n' "${CL_TGT_MOODLEDATA:-}"
} > "$clone_state"
chmod 600 "$clone_state"
sre_info "Clone state: $clone_state"

################################################################################
# Offer SSL
################################################################################

if prompt_yesno "Setup SSL for $CL_TARGET_DOMAIN now?" "yes"; then
    bash "${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh" --domain "$CL_TARGET_DOMAIN" --yes \
        || sre_warning "SSL setup didn't complete — re-run manually if needed"
fi

################################################################################
# Summary
################################################################################

sre_header "Clone Complete"

sre_success "$CL_SOURCE_DOMAIN  →  $CL_TARGET_DOMAIN"
echo ""
sre_info "  Type:          $src_type"
sre_info "  Mode:          $CL_MODE"
sre_info "  Target root:   $tgt_proj_base"
sre_info "  Target doc:    $tgt_doc_root"
if [[ "$do_db" == "true" ]]; then
    sre_info "  Target DB:     $tgt_db_name"
    sre_info "  Target DB user:$tgt_db_user"
    sre_info "  Target DB pass:$tgt_db_pass"
fi
[[ "$src_type" == "nuxt" ]] && sre_info "  Nuxt port:     ${CL_TGT_PORT:-?}"
echo ""
sre_warning "Save the DB password!"
echo ""
sre_info "Next steps:"
sre_info "  1. Point ${CL_TARGET_DOMAIN} DNS at this server (or rely on wildcard)"
sre_info "  2. Visit http://${CL_TARGET_DOMAIN} (or https if SSL was configured)"
sre_info "  3. Verify app loads cleanly, then test against the clone instead of prod"

recommend_next_step "$CURRENT_STEP"
