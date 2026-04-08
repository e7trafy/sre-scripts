#!/bin/bash
################################################################################
# SRE Helpers - Step 5: Database Installation
# Installs and secures MariaDB, MySQL, or PostgreSQL based on config.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=5

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 5: Database Installation
  Installs the database engine selected in step 1 (MariaDB, MySQL, or
  PostgreSQL), enables the service, and runs a secure-installation
  equivalent for MariaDB/MySQL.

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

SRE_DB_ENGINE=$(require_config_key "SRE_DB_ENGINE" "1")
SRE_OS_FAMILY=$(require_config_key "SRE_OS_FAMILY" "1")

sre_info "Database engine: $SRE_DB_ENGINE"
sre_info "OS family: $SRE_OS_FAMILY"

# --- Skip if none ---
if [[ "$SRE_DB_ENGINE" == "none" ]]; then
    sre_skipped "Database engine set to 'none'. Nothing to install."
    recommend_next_step "$CURRENT_STEP"
    exit 0
fi

# --- Install database packages ---
sre_header "Installing $SRE_DB_ENGINE"

case "$SRE_DB_ENGINE" in
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
        sre_error "Unsupported database engine: $SRE_DB_ENGINE"
        exit 1
        ;;
esac

# --- Secure installation (MariaDB/MySQL only) ---
if [[ "$SRE_DB_ENGINE" == "mariadb" || "$SRE_DB_ENGINE" == "mysql" ]]; then
    sre_header "Securing $SRE_DB_ENGINE Installation"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        # Generate a random root password
        DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

        sre_info "Setting root password and removing insecure defaults..."

        # Set root password and secure the installation
        # Use UPDATE on mysql.user for compatibility with fresh MariaDB installs
        # where unix_socket auth is default and ALTER USER may not work
        mysql -u root <<-EOSQL
			-- Set root password (works on both MariaDB and MySQL fresh installs)
			UPDATE mysql.user SET Password=PASSWORD('${DB_ROOT_PASS}'), plugin='mysql_native_password'
			    WHERE User='root';

			-- Remove anonymous users
			DELETE FROM mysql.user WHERE User='';

			-- Disallow remote root login
			DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

			-- Remove test database
			DROP DATABASE IF EXISTS test;
			DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

			-- Reload privilege tables
			FLUSH PRIVILEGES;
		EOSQL

        # Store root password securely
        echo "$DB_ROOT_PASS" > /root/.db_root_password
        chmod 600 /root/.db_root_password

        sre_success "Database secured: anonymous users removed, test DB dropped, remote root disabled"
        sre_warning "Root DB password saved to /root/.db_root_password"
    else
        sre_info "[DRY-RUN] Would secure $SRE_DB_ENGINE: set root password, remove anonymous users, drop test DB"
    fi
fi

# --- Persist completion ---
config_set "SRE_DB_INSTALLED" "true"

sre_success "Database installation complete!"

recommend_next_step "$CURRENT_STEP"
