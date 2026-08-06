#!/bin/bash
################################################################################
# SRE Helpers - Step 5: Database Installation
# Installs and secures MariaDB, MySQL, PostgreSQL, and/or Redis.
# Supports multiple engines (comma-separated SRE_DB_ENGINE).
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=5

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 5: Database Installation
  Installs the database engine(s) selected in step 1 (MariaDB, MySQL,
  PostgreSQL — can install multiple), enables services, secures
  MariaDB/MySQL, and optionally installs Redis.

  Can also point the whole stack at an EXTERNAL SQL server instead of
  installing one locally (--remote). In that mode only the client packages
  are installed; databases and users are then created on the remote server
  by steps 13 / 16 / 10 exactly as they would be locally.

Prerequisites: Step 1 (base-setup) must be complete.

Options:
  --remote            Use an external SQL server (prompts for host/credentials)
  --db-host HOST      Remote SQL host (implies --remote)
  --db-port PORT      Remote SQL port (default: 3306)
  --db-admin-user U   Remote admin user (default: root)
  --db-admin-pass P   Remote admin password (prefer --db-admin-pass-file)
  --db-admin-pass-file F
                      Read the remote admin password from a file
  --db-grant-host H   Host part for CREATE USER/GRANT (default: %)
  --db-client-host H  Override what apps put in DB_HOST (default: --db-host)
  --local             Force local mode (install a server here)
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Examples:
  sudo bash $0
  sudo bash $0 --yes --dry-run
  sudo bash $0 --remote --db-host db.internal --db-admin-pass-file /root/dbpass
EOF
}

################################################################################
# Remote-mode argument parsing (consumed before the common parser sees them)
################################################################################

OPT_MODE=""
OPT_DB_HOST=""
OPT_DB_PORT=""
OPT_DB_ADMIN_USER=""
OPT_DB_ADMIN_PASS=""
OPT_DB_GRANT_HOST=""
OPT_DB_CLIENT_HOST=""

_argv=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)             OPT_MODE="remote" ;;
        --local)              OPT_MODE="local" ;;
        --db-host)            shift; OPT_DB_HOST="${1:?--db-host requires a value}"; OPT_MODE="${OPT_MODE:-remote}" ;;
        --db-port)            shift; OPT_DB_PORT="${1:?--db-port requires a value}" ;;
        --db-admin-user)      shift; OPT_DB_ADMIN_USER="${1:?--db-admin-user requires a value}" ;;
        --db-admin-pass)      shift; OPT_DB_ADMIN_PASS="${1:?--db-admin-pass requires a value}" ;;
        --db-admin-pass-file) shift
                              _pf="${1:?--db-admin-pass-file requires a path}"
                              [[ -s "$_pf" ]] || { echo "[ERROR] Password file not found or empty: $_pf" >&2; exit 2; }
                              OPT_DB_ADMIN_PASS="$(head -n1 "$_pf")" ;;
        --db-grant-host)      shift; OPT_DB_GRANT_HOST="${1:?--db-grant-host requires a value}" ;;
        --db-client-host)     shift; OPT_DB_CLIENT_HOST="${1:?--db-client-host requires a value}" ;;
        *)                    _argv+=("$1") ;;
    esac
    shift
done
set -- "${_argv[@]+"${_argv[@]}"}"

sre_parse_args "05-database.sh" "$@"
require_root

sre_header "Step 5: Database Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

SRE_DB_ENGINE=$(config_get "SRE_DB_ENGINE" "none")
SRE_OS_FAMILY=$(require_config_key "SRE_OS_FAMILY" "1")
SRE_REDIS=$(config_get "SRE_REDIS" "false")

################################################################################
# Resolve local vs remote mode
################################################################################

# Precedence: CLI flag > previously saved config > interactive prompt > local.
DB_MODE="$OPT_MODE"
if [[ -z "$DB_MODE" ]]; then
    DB_MODE=$(config_get "SRE_DB_MODE" "")
fi
if [[ -z "$DB_MODE" ]]; then
    if [[ "$SRE_YES" == "true" ]]; then
        DB_MODE="local"
    elif prompt_yesno "Use an EXTERNAL (remote) SQL server instead of installing one here?" "no"; then
        DB_MODE="remote"
    else
        DB_MODE="local"
    fi
fi
[[ "$DB_MODE" == "remote" ]] || DB_MODE="local"

sre_info "Database mode: $DB_MODE"
sre_info "Database engine(s): $SRE_DB_ENGINE"
sre_info "Redis: $SRE_REDIS"
sre_info "OS family: $SRE_OS_FAMILY"

################################################################################
# REMOTE MODE
#
# Nothing is installed or secured locally: the remote server is somebody
# else's responsibility. We install the client packages so the later steps can
# run mysql/mysqldump, persist the connection details, then prove the
# connection works before declaring the step done.
################################################################################

if [[ "$DB_MODE" == "remote" ]]; then
    sre_header "Configuring External SQL Server"

    # --- Gather connection details ---
    db_host="$OPT_DB_HOST"
    [[ -z "$db_host" ]] && db_host=$(config_get "SRE_DB_HOST" "")
    if [[ -z "$db_host" ]]; then
        db_host=$(prompt_input "Remote SQL host (hostname or IP)" "")
    fi
    if [[ -z "$db_host" ]]; then
        sre_error "A remote SQL host is required in remote mode."
        sre_error "Pass --db-host HOST or set SRE_DB_HOST in $SRE_CONFIG_FILE."
        exit 2
    fi

    db_port="$OPT_DB_PORT"
    [[ -z "$db_port" ]] && db_port=$(config_get "SRE_DB_PORT" "")
    [[ -z "$db_port" ]] && db_port=$(prompt_input "Remote SQL port" "3306")
    [[ -z "$db_port" ]] && db_port="3306"
    if ! [[ "$db_port" =~ ^[0-9]+$ ]]; then
        sre_error "Invalid port: $db_port"
        exit 2
    fi

    db_admin_u="$OPT_DB_ADMIN_USER"
    [[ -z "$db_admin_u" ]] && db_admin_u=$(config_get "SRE_DB_ADMIN_USER" "")
    [[ -z "$db_admin_u" ]] && db_admin_u=$(prompt_input "Remote SQL admin user" "root")
    [[ -z "$db_admin_u" ]] && db_admin_u="root"

    db_grant_h="$OPT_DB_GRANT_HOST"
    [[ -z "$db_grant_h" ]] && db_grant_h=$(config_get "SRE_DB_GRANT_HOST" "")
    [[ -z "$db_grant_h" ]] && db_grant_h="%"

    db_client_h="$OPT_DB_CLIENT_HOST"
    [[ -z "$db_client_h" ]] && db_client_h=$(config_get "SRE_DB_CLIENT_HOST" "")
    [[ -z "$db_client_h" ]] && db_client_h="$db_host"

    # --- Engine the remote server speaks ---
    remote_engine="$SRE_DB_ENGINE"
    if [[ "$remote_engine" == "none" || -z "$remote_engine" ]]; then
        remote_engine=$(prompt_choice "Which engine does the remote server run?" "mariadb" "mysql")
    fi
    # PostgreSQL has no remote path yet (local peer auth only).
    if [[ ",$remote_engine," == *",postgresql,"* ]]; then
        sre_error "PostgreSQL is not supported in remote database mode yet."
        sre_error "Remote support currently covers MySQL and MariaDB only."
        sre_error "Re-run with --local, or select mysql/mariadb for the remote server."
        exit 2
    fi

    # --- Install client packages only ---
    sre_info "Installing SQL client packages (no server will be installed here)..."
    case "$SRE_OS_FAMILY" in
        debian)
            # mariadb-client speaks to both MariaDB and MySQL servers.
            pkg_install mariadb-client || pkg_install mysql-client
            ;;
        rhel)
            pkg_install mariadb || pkg_install mysql
            ;;
    esac

    # --- Persist connection details BEFORE validating, so a failed check
    #     leaves a config the user can fix and re-run against. ---
    config_set "SRE_DB_MODE"        "remote"
    config_set "SRE_DB_HOST"        "$db_host"
    config_set "SRE_DB_PORT"        "$db_port"
    config_set "SRE_DB_ADMIN_USER"  "$db_admin_u"
    config_set "SRE_DB_GRANT_HOST"  "$db_grant_h"
    config_set "SRE_DB_CLIENT_HOST" "$db_client_h"
    config_set "SRE_DB_ENGINE"      "$remote_engine"

    # --- Admin password into the 0600 file (never into setup.conf) ---
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        db_pass="$OPT_DB_ADMIN_PASS"
        if [[ -z "$db_pass" && -s "$SRE_DB_ADMIN_PASS_FILE" ]]; then
            sre_info "Reusing existing admin password from $SRE_DB_ADMIN_PASS_FILE"
            db_pass="$(head -n1 "$SRE_DB_ADMIN_PASS_FILE")"
        fi
        if [[ -z "$db_pass" ]]; then
            if [[ "$SRE_YES" == "true" ]]; then
                sre_error "No admin password supplied and none stored."
                sre_error "Pass --db-admin-pass-file FILE (preferred) or --db-admin-pass."
                exit 2
            fi
            # Read without echoing, and never through prompt_input (which echoes).
            read -r -s -p "Password for ${db_admin_u}@${db_host}: " db_pass
            echo ""
        fi
        if [[ -z "$db_pass" ]]; then
            sre_error "An admin password is required to create databases on the remote server."
            exit 2
        fi
        db_admin_pass_write "$db_pass"
        unset db_pass
        sre_success "Admin password stored at $SRE_DB_ADMIN_PASS_FILE (600)"
    else
        sre_info "[DRY-RUN] Would store the remote admin password at $SRE_DB_ADMIN_PASS_FILE"
    fi

    sre_success "Remote SQL server configured: ${db_admin_u}@${db_host}:${db_port} (engine: $remote_engine)"
    sre_info "GRANT host for project users: '${db_grant_h}'"
    sre_info "Apps will connect to: ${db_client_h}:${db_port}"

    # --- Prove it works ---
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        sre_header "Validating Remote Connection"
        if ! db_check_connection; then
            sre_error "Remote database configuration saved but NOT usable yet."
            sre_error "Fix the issues above and re-run: sudo bash $0"
            exit 1
        fi

        # Confirm the admin user can actually create databases — a read-only
        # account connects fine but fails every later provisioning step.
        _probe="sre_helpers_probe_$$"
        _mysql="$(db_admin_cmd)"
        if $_mysql -e "CREATE DATABASE \`${_probe}\`;" 2>/dev/null; then
            $_mysql -e "DROP DATABASE \`${_probe}\`;" 2>/dev/null || true
            sre_success "Admin user can create and drop databases"
        else
            sre_warning "Connected, but '${db_admin_u}' could not create a test database."
            sre_warning "Project provisioning (steps 13/16/10) needs CREATE, DROP,"
            sre_warning "CREATE USER and GRANT OPTION privileges. Verify with:"
            sre_warning "  SHOW GRANTS FOR '${db_admin_u}'@'<this-host>';"
        fi

        _sv=$($_mysql -N -B -e "SELECT VERSION();" 2>/dev/null || true)
        [[ -n "$_sv" ]] && sre_info "Remote server version: $_sv"

        # utf8mb4 matters for Arabic content; the remote server owns this
        # setting, so warn rather than silently rely on it.
        _cs=$($_mysql -N -B -e "SELECT @@character_set_server;" 2>/dev/null || true)
        if [[ -n "$_cs" && "$_cs" != "utf8mb4" ]]; then
            sre_warning "Remote server default charset is '$_cs', not utf8mb4."
            sre_warning "Databases are created explicitly as utf8mb4 so new projects are"
            sre_warning "fine, but consider setting character-set-server=utf8mb4 there."
        elif [[ "$_cs" == "utf8mb4" ]]; then
            sre_success "Remote server default charset is utf8mb4"
        fi
    fi

    config_set "SRE_DB_INSTALLED" "true"
fi

################################################################################
# LOCAL MODE
################################################################################

if [[ "$DB_MODE" == "local" ]]; then
    config_set "SRE_DB_MODE" "local"
fi

# --- Skip if none and no redis (local mode only; remote handled above) ---
if [[ "$DB_MODE" == "local" ]] && [[ "$SRE_DB_ENGINE" == "none" ]] && [[ "$SRE_REDIS" != "true" ]]; then
    sre_skipped "No database engines or Redis selected. Nothing to install."
    recommend_next_step "$CURRENT_STEP"
    exit 0
fi

################################################################################
# Install database engines (loop through comma-separated list)
################################################################################

if [[ "$DB_MODE" == "local" ]] && [[ "$SRE_DB_ENGINE" != "none" ]]; then
    IFS=',' read -ra engines <<< "$SRE_DB_ENGINE"
    for engine in "${engines[@]}"; do
        engine=$(echo "$engine" | tr -d ' ')
        [[ -z "$engine" || "$engine" == "none" ]] && continue

        sre_header "Installing $engine"

        case "$engine" in
            mariadb)
                case "$SRE_OS_FAMILY" in
                    debian) pkg_install mariadb-server mariadb-client ;;
                    rhel)   pkg_install mariadb-server mariadb ;;
                esac
                svc_enable_start mariadb
                sre_success "MariaDB installed and running"
                ;;
            mysql)
                case "$SRE_OS_FAMILY" in
                    debian)
                        pkg_install mysql-server mysql-client
                        svc_enable_start mysql
                        ;;
                    rhel)
                        pkg_install mysql-server
                        svc_enable_start mysqld
                        ;;
                esac
                sre_success "MySQL installed and running"
                ;;
            postgresql)
                case "$SRE_OS_FAMILY" in
                    debian)
                        pkg_install postgresql postgresql-client
                        ;;
                    rhel)
                        pkg_install postgresql-server postgresql
                        if [[ "$SRE_DRY_RUN" != "true" ]]; then
                            postgresql-setup --initdb 2>/dev/null || true
                        else
                            sre_info "[DRY-RUN] Would run postgresql-setup --initdb"
                        fi
                        ;;
                esac
                svc_enable_start postgresql
                sre_success "PostgreSQL installed and running"
                ;;
            *)
                sre_warning "Unknown database engine: $engine — skipping"
                continue
                ;;
        esac

        # --- UTF-8 (utf8mb4) for MySQL-compatible engines ---
        if [[ "$engine" == "mariadb" || "$engine" == "mysql" ]]; then
            sre_header "Configuring UTF-8 (utf8mb4) for $engine"

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                cnf_dir="/etc/mysql/conf.d"
                [[ "$SRE_OS_FAMILY" == "rhel" ]] && cnf_dir="/etc/my.cnf.d"
                mkdir -p "$cnf_dir"

                cat > "${cnf_dir}/utf8mb4.cnf" <<'EOCNF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
EOCNF

                svc_restart "$(get_db_svc "$engine")"
                sre_success "Default charset set to utf8mb4 (full Arabic/Unicode support)"
            else
                sre_info "[DRY-RUN] Would configure utf8mb4 as default charset"
            fi
        fi

        # --- Secure installation (MariaDB/MySQL only) ---
        if [[ "$engine" == "mariadb" || "$engine" == "mysql" ]]; then
            sre_header "Securing $engine Installation"

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

                sre_info "Setting root password and removing insecure defaults..."

                if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';" 2>/dev/null; then
                    sre_info "Root password set via ALTER USER"
                else
                    sre_warning "ALTER USER failed, trying legacy method..."
                    mysql -u root -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_ROOT_PASS}');" 2>/dev/null \
                        || mysql -u root -e "UPDATE mysql.user SET Password=PASSWORD('${DB_ROOT_PASS}') WHERE User='root'; FLUSH PRIVILEGES;" 2>/dev/null \
                        || sre_warning "Could not set root password automatically — set it manually"
                fi

                mysql -u root -p"${DB_ROOT_PASS}" <<-EOSQL
					DROP USER IF EXISTS ''@'localhost';
					DROP USER IF EXISTS ''@'$(hostname)';
					DROP DATABASE IF EXISTS test;
					FLUSH PRIVILEGES;
				EOSQL

                echo "$DB_ROOT_PASS" > /root/.db_root_password
                chmod 600 /root/.db_root_password

                sre_success "Database secured: anonymous users removed, test DB dropped"
                sre_warning "Root DB password saved to /root/.db_root_password"
            else
                sre_info "[DRY-RUN] Would secure $engine: set root password, remove anonymous users, drop test DB"
            fi
        fi

    done
fi

################################################################################
# Install Redis
################################################################################

if [[ "$SRE_REDIS" == "true" ]]; then
    sre_header "Installing Redis"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        case "$SRE_OS_FAMILY" in
            debian) pkg_install redis-server ;;
            rhel)   pkg_install redis ;;
        esac

        svc_enable_start redis-server 2>/dev/null || svc_enable_start redis 2>/dev/null || true

        # Basic security: bind to localhost only and enable protected mode
        redis_conf=""
        [[ -f /etc/redis/redis.conf ]] && redis_conf="/etc/redis/redis.conf"
        [[ -f /etc/redis.conf ]] && redis_conf="/etc/redis.conf"

        if [[ -n "$redis_conf" ]]; then
            backup_config "$redis_conf"
            # Ensure bind to localhost
            if grep -q "^bind " "$redis_conf"; then
                sed -i 's/^bind .*/bind 127.0.0.1 ::1/' "$redis_conf"
            else
                echo "bind 127.0.0.1 ::1" >> "$redis_conf"
            fi
            # Enable protected mode
            sed -i 's/^protected-mode no/protected-mode yes/' "$redis_conf"

            # Set maxmemory based on system RAM (10% of RAM, min 64MB, max 2GB)
            ram_mb=$(config_get "SRE_RAM_MB" "1024")
            max_mem_mb=$(( ram_mb / 10 ))
            (( max_mem_mb < 64 )) && max_mem_mb=64
            (( max_mem_mb > 2048 )) && max_mem_mb=2048

            if grep -q "^maxmemory " "$redis_conf"; then
                sed -i "s/^maxmemory .*/maxmemory ${max_mem_mb}mb/" "$redis_conf"
            else
                echo "maxmemory ${max_mem_mb}mb" >> "$redis_conf"
            fi

            # Set eviction policy
            if grep -q "^maxmemory-policy " "$redis_conf"; then
                sed -i 's/^maxmemory-policy .*/maxmemory-policy allkeys-lru/' "$redis_conf"
            else
                echo "maxmemory-policy allkeys-lru" >> "$redis_conf"
            fi

            # Require a password: all projects share this Redis, and without
            # auth any local process (including a compromised site) can read
            # every project's cache/session/queue keys.
            if ! grep -qE "^requirepass " "$redis_conf"; then
                redis_pass=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-40)
                echo "requirepass ${redis_pass}" >> "$redis_conf"
                touch /etc/sre-helpers/redis.pass
                chmod 600 /etc/sre-helpers/redis.pass
                printf '%s\n' "$redis_pass" > /etc/sre-helpers/redis.pass
                sre_success "Redis requirepass set (stored at /etc/sre-helpers/redis.pass, 600)"
                sre_info "Add REDIS_PASSWORD to each project's .env that uses Redis"
            fi

            svc_restart redis-server 2>/dev/null || svc_restart redis 2>/dev/null || true
            sre_success "Redis installed and configured (maxmemory: ${max_mem_mb}MB, policy: allkeys-lru)"
        else
            sre_success "Redis installed (config file not found — using defaults)"
        fi

        # Verify Redis is running (authenticate if a password is set)
        redis_ping="redis-cli"
        [[ -s /etc/sre-helpers/redis.pass ]] && redis_ping="redis-cli -a $(cat /etc/sre-helpers/redis.pass) --no-auth-warning"
        if $redis_ping ping 2>/dev/null | grep -q "PONG"; then
            sre_success "Redis responding: PONG"
        else
            sre_warning "Redis installed but not responding to ping — check service status"
        fi
    else
        sre_info "[DRY-RUN] Would install and configure Redis"
    fi

    config_set "SRE_REDIS_INSTALLED" "true"
fi

################################################################################
# Persist completion
################################################################################

config_set "SRE_DB_INSTALLED" "true"

if [[ "$DB_MODE" == "remote" ]]; then
    sre_success "External database configured — projects will be created on $(db_admin_host)"
else
    sre_success "Database installation complete!"
fi

recommend_next_step "$CURRENT_STEP"
