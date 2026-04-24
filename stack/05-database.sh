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

Prerequisites: Step 1 (base-setup) must be complete.

Options:
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes --dry-run
EOF
}

sre_parse_args "05-database.sh" "$@"
require_root

sre_header "Step 5: Database Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

SRE_DB_ENGINE=$(config_get "SRE_DB_ENGINE" "none")
SRE_OS_FAMILY=$(require_config_key "SRE_OS_FAMILY" "1")
SRE_REDIS=$(config_get "SRE_REDIS" "false")

sre_info "Database engine(s): $SRE_DB_ENGINE"
sre_info "Redis: $SRE_REDIS"
sre_info "OS family: $SRE_OS_FAMILY"

# --- Skip if none and no redis ---
if [[ "$SRE_DB_ENGINE" == "none" ]] && [[ "$SRE_REDIS" != "true" ]]; then
    sre_skipped "No database engines or Redis selected. Nothing to install."
    recommend_next_step "$CURRENT_STEP"
    exit 0
fi

################################################################################
# Install database engines (loop through comma-separated list)
################################################################################

if [[ "$SRE_DB_ENGINE" != "none" ]]; then
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

            svc_restart redis-server 2>/dev/null || svc_restart redis 2>/dev/null || true
            sre_success "Redis installed and configured (maxmemory: ${max_mem_mb}MB, policy: allkeys-lru)"
        else
            sre_success "Redis installed (config file not found — using defaults)"
        fi

        # Verify Redis is running
        if redis-cli ping 2>/dev/null | grep -q "PONG"; then
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

sre_success "Database installation complete!"

recommend_next_step "$CURRENT_STEP"
