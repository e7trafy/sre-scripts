#!/bin/bash
################################################################################
# SRE Helpers - Step 7: Performance Tuning
# Calculates and applies tuning values based on server specs.
# Covers: PHP-FPM, Nginx/Apache, Database, OPcache.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=7

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 7: Performance Tuning
  Calculates optimal settings based on server hardware specs
  and applies them to PHP-FPM, web server, and database configs.

  Safe to re-run after hardware changes (e.g., RAM upgrade).
  Creates backups before modifying any config file.

Prerequisites: Web server (step 3) and/or PHP (step 4) installed.

Options:
  --dry-run   Print planned actions and calculated values without applying
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --dry-run
EOF
}

sre_parse_args "07-tune.sh" "$@"
require_root

sre_header "Step 7: Performance Tuning"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

# Re-detect specs (may have changed since step 1, e.g., RAM upgrade)
detect_specs

# Update config with latest specs
config_set "SRE_CPU_CORES" "$SRE_CPU_CORES"
config_set "SRE_RAM_MB" "$SRE_RAM_MB"
config_set "SRE_DISK_TYPE" "$SRE_DISK_TYPE"

################################################################################
# T018: Tuning Calculations
################################################################################

sre_header "Calculating Tuning Parameters"

ram=$SRE_RAM_MB
cpu=$SRE_CPU_CORES
disk=$SRE_DISK_TYPE

os_family=$(config_get "SRE_OS_FAMILY" "debian")
web_server=$(config_get "SRE_WEB_SERVER" "")
php_version=$(config_get "SRE_PHP_VERSION" "")
db_engine=$(config_get "SRE_DB_ENGINE" "none")

# --- PHP-FPM Tuning ---
fpm_max_children=$(clamp $((ram / 50)) 5 200)
fpm_start_servers=$(clamp $((fpm_max_children / 4)) 2 50)
fpm_min_spare=$(clamp $((fpm_max_children / 8)) 1 25)
fpm_max_spare=$(clamp $((fpm_max_children / 4)) 3 50)

config_set "SRE_FPM_MAX_CHILDREN" "$fpm_max_children"
config_set "SRE_FPM_START_SERVERS" "$fpm_start_servers"
config_set "SRE_FPM_MIN_SPARE" "$fpm_min_spare"
config_set "SRE_FPM_MAX_SPARE" "$fpm_max_spare"

sre_info "PHP-FPM: max_children=$fpm_max_children, start=$fpm_start_servers, min_spare=$fpm_min_spare, max_spare=$fpm_max_spare"

# --- Web Server Tuning ---
if [[ "$web_server" == "nginx" ]]; then
    nginx_workers=$cpu
    if [[ "$disk" == "ssd" ]]; then
        nginx_connections=1024
    else
        nginx_connections=512
    fi
    config_set "SRE_NGINX_WORKERS" "$nginx_workers"
    config_set "SRE_NGINX_CONNECTIONS" "$nginx_connections"
    sre_info "Nginx: workers=$nginx_workers, connections=$nginx_connections"
elif [[ "$web_server" == "apache" ]]; then
    apache_max_workers=$(clamp $((ram / 50)) 10 400)
    apache_threads=25
    config_set "SRE_APACHE_MAX_WORKERS" "$apache_max_workers"
    config_set "SRE_APACHE_THREADS" "$apache_threads"
    sre_info "Apache: MaxRequestWorkers=$apache_max_workers, ThreadsPerChild=$apache_threads"
fi

# --- Database Tuning ---
if [[ "$db_engine" != "none" ]]; then
    db_buffer_pool=$((ram / 4))
    db_max_connections=$(clamp $((ram / 20)) 50 500)
    config_set "SRE_DB_BUFFER_POOL_MB" "$db_buffer_pool"
    config_set "SRE_DB_MAX_CONNECTIONS" "$db_max_connections"
    sre_info "Database: buffer_pool=${db_buffer_pool}MB, max_connections=$db_max_connections"
fi

# --- OPcache Tuning ---
opcache_mem=$((ram / 8))
(( opcache_mem > 256 )) && opcache_mem=256
(( opcache_mem < 64 )) && opcache_mem=64
config_set "SRE_OPCACHE_MEMORY_MB" "$opcache_mem"
sre_info "OPcache: memory=${opcache_mem}MB"

################################################################################
# T019: Apply Tuning
################################################################################

sre_header "Applying Tuning Parameters"

# --- Apply PHP-FPM Pool Config ---
if [[ -n "$php_version" ]]; then
    pool_conf=""
    case "$os_family" in
        debian) pool_conf="/etc/php/${php_version}/fpm/pool.d/www.conf" ;;
        rhel)   pool_conf="/etc/php-fpm.d/www.conf" ;;
    esac

    if [[ -f "$pool_conf" ]]; then
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            backup_config "$pool_conf"
            sed -i "s/^pm.max_children\s*=.*/pm.max_children = $fpm_max_children/" "$pool_conf"
            sed -i "s/^pm.start_servers\s*=.*/pm.start_servers = $fpm_start_servers/" "$pool_conf"
            sed -i "s/^pm.min_spare_servers\s*=.*/pm.min_spare_servers = $fpm_min_spare/" "$pool_conf"
            sed -i "s/^pm.max_spare_servers\s*=.*/pm.max_spare_servers = $fpm_max_spare/" "$pool_conf"

            # Ensure dynamic PM mode
            sed -i "s/^pm\s*=.*/pm = dynamic/" "$pool_conf"

            sre_success "PHP-FPM pool tuned: $pool_conf"
        else
            sre_info "[DRY-RUN] Would tune PHP-FPM pool: $pool_conf"
        fi
    else
        sre_warning "PHP-FPM pool config not found at $pool_conf"
    fi

    # --- Apply OPcache Settings ---
    php_ini=""
    case "$os_family" in
        debian) php_ini="/etc/php/${php_version}/fpm/php.ini" ;;
        rhel)   php_ini="/etc/php.ini" ;;
    esac

    if [[ -f "$php_ini" ]]; then
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            backup_config "$php_ini"
            # Enable OPcache and set memory
            sed -i "s/^;*opcache.enable\s*=.*/opcache.enable=1/" "$php_ini"
            sed -i "s/^;*opcache.memory_consumption\s*=.*/opcache.memory_consumption=$opcache_mem/" "$php_ini"
            sed -i "s/^;*opcache.interned_strings_buffer\s*=.*/opcache.interned_strings_buffer=16/" "$php_ini"
            sed -i "s/^;*opcache.max_accelerated_files\s*=.*/opcache.max_accelerated_files=10000/" "$php_ini"
            sed -i "s/^;*opcache.validate_timestamps\s*=.*/opcache.validate_timestamps=0/" "$php_ini"
            sre_success "OPcache tuned: $php_ini"
        else
            sre_info "[DRY-RUN] Would tune OPcache in: $php_ini"
        fi
    fi
fi

# --- Apply Nginx Tuning ---
if [[ "$web_server" == "nginx" ]]; then
    nginx_conf="/etc/nginx/nginx.conf"
    if [[ -f "$nginx_conf" ]]; then
        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            backup_config "$nginx_conf"
            sed -i "s/^worker_processes.*/worker_processes $nginx_workers;/" "$nginx_conf"
            # Update worker_connections inside events block
            sed -i "s/worker_connections.*/worker_connections $nginx_connections;/" "$nginx_conf"
            sre_success "Nginx tuned: $nginx_conf"
        else
            sre_info "[DRY-RUN] Would tune Nginx: workers=$nginx_workers, connections=$nginx_connections"
        fi
    fi
fi

# --- Apply Apache Tuning ---
if [[ "$web_server" == "apache" ]]; then
    apache_conf=""
    case "$os_family" in
        debian) apache_conf="/etc/apache2/mods-available/mpm_event.conf" ;;
        rhel)   apache_conf="/etc/httpd/conf.modules.d/00-mpm.conf" ;;
    esac

    # Create or update MPM event config
    mpm_config="<IfModule mpm_event_module>
    StartServers             $fpm_start_servers
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadLimit              64
    ThreadsPerChild          $apache_threads
    MaxRequestWorkers        $apache_max_workers
    MaxConnectionsPerChild   10000
</IfModule>"

    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        if [[ -f "$apache_conf" ]]; then
            backup_config "$apache_conf"
        fi
        echo "$mpm_config" > "$apache_conf"
        sre_success "Apache MPM event tuned: $apache_conf"
    else
        sre_info "[DRY-RUN] Would tune Apache MPM event: MaxRequestWorkers=$apache_max_workers"
    fi
fi

# --- Apply Database Tuning ---
if [[ "$db_engine" != "none" && "$db_engine" != "" ]]; then
    case "$db_engine" in
        mariadb|mysql)
            my_cnf=""
            if [[ -d "/etc/mysql/mariadb.conf.d" ]]; then
                my_cnf="/etc/mysql/mariadb.conf.d/99-sre-tuning.cnf"
            elif [[ -d "/etc/mysql/conf.d" ]]; then
                my_cnf="/etc/mysql/conf.d/99-sre-tuning.cnf"
            elif [[ -d "/etc/my.cnf.d" ]]; then
                my_cnf="/etc/my.cnf.d/99-sre-tuning.cnf"
            else
                my_cnf="/etc/mysql/conf.d/99-sre-tuning.cnf"
                mkdir -p "$(dirname "$my_cnf")"
            fi

            db_config="[mysqld]
innodb_buffer_pool_size = ${db_buffer_pool}M
max_connections = $db_max_connections
innodb_log_file_size = $((db_buffer_pool / 4))M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
query_cache_type = 0
tmp_table_size = 64M
max_heap_table_size = 64M"

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                [[ -f "$my_cnf" ]] && backup_config "$my_cnf"
                echo "$db_config" > "$my_cnf"
                sre_success "MySQL/MariaDB tuned: $my_cnf"
            else
                sre_info "[DRY-RUN] Would tune MySQL/MariaDB: buffer_pool=${db_buffer_pool}M, max_connections=$db_max_connections"
            fi
            ;;
        postgresql)
            pg_conf=""
            pg_conf=$(find /etc/postgresql -name postgresql.conf 2>/dev/null | head -1)
            if [[ -z "$pg_conf" ]]; then
                pg_conf="/var/lib/pgsql/data/postgresql.conf"
            fi

            if [[ -f "$pg_conf" ]]; then
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    backup_config "$pg_conf"
                    # shared_buffers = 25% of RAM
                    sed -i "s/^#*shared_buffers\s*=.*/shared_buffers = ${db_buffer_pool}MB/" "$pg_conf"
                    sed -i "s/^#*max_connections\s*=.*/max_connections = $db_max_connections/" "$pg_conf"
                    sed -i "s/^#*effective_cache_size\s*=.*/effective_cache_size = $((ram * 3 / 4))MB/" "$pg_conf"
                    sed -i "s/^#*work_mem\s*=.*/work_mem = $((ram / db_max_connections))MB/" "$pg_conf"
                    sre_success "PostgreSQL tuned: $pg_conf"
                else
                    sre_info "[DRY-RUN] Would tune PostgreSQL: shared_buffers=${db_buffer_pool}MB"
                fi
            else
                sre_warning "PostgreSQL config not found"
            fi
            ;;
    esac
fi

# --- Restart Services ---
sre_header "Restarting Services"

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    if [[ -n "$php_version" ]]; then
        case "$os_family" in
            debian) svc_restart "php${php_version}-fpm" ;;
            rhel)   svc_restart "php-fpm" ;;
        esac
        sre_success "PHP-FPM restarted"
    fi

    if [[ "$web_server" == "nginx" ]]; then
        svc_reload nginx
        sre_success "Nginx reloaded"
    elif [[ "$web_server" == "apache" ]]; then
        case "$os_family" in
            debian) svc_reload apache2 ;;
            rhel)   svc_reload httpd ;;
        esac
        sre_success "Apache reloaded"
    fi

    if [[ "$db_engine" == "mariadb" || "$db_engine" == "mysql" ]]; then
        db_svc=""
        case "$os_family" in
            debian) db_svc="mariadb"
                    [[ "$db_engine" == "mysql" ]] && db_svc="mysql"
                    ;;
            rhel)   db_svc="mariadb"
                    [[ "$db_engine" == "mysql" ]] && db_svc="mysqld"
                    ;;
        esac
        svc_restart "$db_svc"
        sre_success "Database restarted"
    elif [[ "$db_engine" == "postgresql" ]]; then
        svc_restart postgresql
        sre_success "PostgreSQL restarted"
    fi
else
    sre_info "[DRY-RUN] Would restart PHP-FPM, web server, and database"
fi

config_set "SRE_TUNING_DONE" "true"

sre_success "Performance tuning complete!"
sre_info "Tuning parameters saved to: $SRE_CONFIG_FILE"

recommend_next_step "$CURRENT_STEP"
