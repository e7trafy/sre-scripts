#!/bin/bash
################################################################################
# SRE Helpers - Database connection library
#
# Single source of truth for "how do we talk to the SQL server". Every script
# that administers MySQL/MariaDB builds its client command through here instead
# of hardcoding `mysql -u root -p$(cat /root/.db_root_password)`.
#
# Two modes, selected by SRE_DB_MODE in the config file:
#
#   local  (default)  The SQL server runs on this machine. Behaviour is
#                     byte-identical to what the scripts did before this
#                     library existed: connect over the local socket as root
#                     using /root/.db_root_password when present.
#
#   remote            The SQL server is another host. Admin credentials live in
#                     the config file (host/port/user) plus a 0600 password
#                     file; app configs get pointed at the remote host and
#                     GRANTs are issued for the configured grant host.
#
# Config keys (written by stack/05-database.sh, read everywhere):
#   SRE_DB_MODE        local | remote
#   SRE_DB_HOST        remote hostname/IP           (remote only)
#   SRE_DB_PORT        remote port, default 3306    (remote only)
#   SRE_DB_ADMIN_USER  admin/root-equivalent user   (remote only)
#   SRE_DB_GRANT_HOST  host part of CREATE USER ... @'<here>'; default '%'
#   SRE_DB_CLIENT_HOST optional override for what apps put in DB_HOST
#
# Admin password file: /etc/sre-helpers/db-admin.pass (0600). The password is
# deliberately NOT stored in setup.conf — that file is sourced, echoed and
# grepped all over the place.
#
# Passwords never appear in argv. Every command is built around a private
# --defaults-extra-file so credentials stay out of `ps`.
#
# Sourced by common/lib.sh. Functions assume root.
################################################################################

[[ -n "${_SRE_DBCONN_LOADED:-}" ]] && return 0
_SRE_DBCONN_LOADED=1

SRE_DB_ADMIN_PASS_FILE="${SRE_DB_ADMIN_PASS_FILE:-/etc/sre-helpers/db-admin.pass}"

# Directory holding this run's credentials file.
#
# The path MUST be deterministic rather than mktemp-random: db_admin_cmd() is
# almost always called inside a command substitution — `cmd="$(db_admin_cmd)"`
# — which runs in a SUBSHELL. Any variable it sets is lost to the parent, so a
# random path would be regenerated on every call, leaking a tmpdir each time
# and (worse) returning a path the subshell's own EXIT trap had already
# deleted. Keying on the top-level PID makes the path stable across subshells
# and lets repeat calls reuse the same file.
#
# $$ is the parent shell's PID even when evaluated inside a subshell, which is
# exactly the property needed here.
_SRE_DB_CNF_DIR="${TMPDIR:-/tmp}/.sre-dbconn-$$"
_SRE_DB_CNF="${_SRE_DB_CNF_DIR}/client.cnf"

################################################################################
# Mode / accessors
################################################################################

# Current mode: "local" or "remote". Anything unrecognised falls back to local
# so a typo can never silently point provisioning at the wrong server.
db_mode() {
    local mode
    mode=$(config_get "SRE_DB_MODE" "local")
    case "$mode" in
        remote) printf 'remote' ;;
        *)      printf 'local'  ;;
    esac
}

db_is_remote() {
    [[ "$(db_mode)" == "remote" ]]
}

db_admin_host() { config_get "SRE_DB_HOST" ""; }
db_admin_port() { config_get "SRE_DB_PORT" "3306"; }
db_admin_user() {
    local u
    u=$(config_get "SRE_DB_ADMIN_USER" "")
    printf '%s' "${u:-root}"
}

# Host part for CREATE USER / GRANT statements.
#
# In local mode this is 'localhost' — the app and the DB share a socket.
# In remote mode the app connects over the network, so a 'localhost' grant
# would authorise a client running on the DB box rather than this app server.
db_grant_host() {
    local gh
    gh=$(config_get "SRE_DB_GRANT_HOST" "")
    if [[ -n "$gh" ]]; then
        printf '%s' "$gh"
        return 0
    fi
    if db_is_remote; then
        printf '%%'
    else
        printf 'localhost'
    fi
}

# The value applications put in DB_HOST / $CFG->dbhost / DB_HOST constant.
#
# NOTE this is intentionally separate from db_admin_host(): provisioning can
# reach the server as an admin over one address while the app uses another.
db_client_host() {
    local ch
    ch=$(config_get "SRE_DB_CLIENT_HOST" "")
    if [[ -n "$ch" ]]; then
        printf '%s' "$ch"
        return 0
    fi
    if db_is_remote; then
        printf '%s' "$(db_admin_host)"
    else
        printf '127.0.0.1'
    fi
}

# Client host for configs that historically used the string 'localhost'
# (Moodle, WordPress). Keeps local-mode output byte-identical to before.
db_client_host_legacy() {
    if db_is_remote; then
        printf '%s' "$(db_client_host)"
    else
        printf 'localhost'
    fi
}

# Port apps should use. Empty-safe: always prints something numeric.
db_client_port() {
    if db_is_remote; then
        printf '%s' "$(db_admin_port)"
    else
        printf '3306'
    fi
}

################################################################################
# Admin credentials
################################################################################

db_admin_pass() {
    if db_is_remote; then
        [[ -s "$SRE_DB_ADMIN_PASS_FILE" ]] && head -n1 "$SRE_DB_ADMIN_PASS_FILE"
    else
        [[ -s /root/.db_root_password ]] && head -n1 /root/.db_root_password
    fi
    return 0
}

db_admin_pass_write() {
    local pass="$1"
    local dir
    dir="$(dirname "$SRE_DB_ADMIN_PASS_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
    # Create empty with tight perms BEFORE writing, so the secret is never
    # briefly world-readable.
    touch "$SRE_DB_ADMIN_PASS_FILE"
    chmod 600 "$SRE_DB_ADMIN_PASS_FILE"
    printf '%s\n' "$pass" > "$SRE_DB_ADMIN_PASS_FILE"
}

################################################################################
# Command builders
################################################################################

db_cnf_cleanup() {
    [[ -f "$_SRE_DB_CNF" ]] && rm -f "$_SRE_DB_CNF"
    [[ -d "$_SRE_DB_CNF_DIR" ]] && rmdir "$_SRE_DB_CNF_DIR" 2>/dev/null
    return 0
}

# Write (once per run) a 0600 defaults-file holding the admin credentials and
# echo its path. Keeping the password in a file rather than argv is what stops
# it showing up in `ps` for every other user on the box.
_db_ensure_cnf() {
    # Reuse an existing file: cheap, and required for correctness because this
    # function usually runs in a subshell that cannot memoise anything.
    if [[ -f "$_SRE_DB_CNF" ]]; then
        printf '%s' "$_SRE_DB_CNF"
        return 0
    fi

    local pass user
    pass="$(db_admin_pass)"
    user="$(db_admin_user)"

    # No password available. In local mode that is a legitimate state (fresh
    # install, socket auth as root), so fall through to a credential-less
    # command. In remote mode it is fatal and the caller must surface it.
    if [[ -z "$pass" ]] && ! db_is_remote; then
        printf ''
        return 0
    fi

    # Create the dir 0700 and the file 0600 BEFORE any secret is written, so
    # the credentials are never briefly world-readable.
    if [[ ! -d "$_SRE_DB_CNF_DIR" ]]; then
        mkdir -p "$_SRE_DB_CNF_DIR" || return 1
    fi
    chmod 700 "$_SRE_DB_CNF_DIR"
    touch "$_SRE_DB_CNF"
    chmod 600 "$_SRE_DB_CNF"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        printf 'password=%s\n' "$pass"
        if db_is_remote; then
            printf 'host=%s\n' "$(db_admin_host)"
            printf 'port=%s\n' "$(db_admin_port)"
        fi
    } > "$_SRE_DB_CNF"

    printf '%s' "$_SRE_DB_CNF"
}

# Echo a ready-to-use mysql client invocation.
#
# Callers use it unquoted, matching the existing convention in these scripts:
#   mysql_cmd="$(db_admin_cmd)"
#   $mysql_cmd -e "SELECT 1;"
# The emitted words never contain spaces, so word-splitting is safe here.
db_admin_cmd() {
    local cnf
    cnf="$(_db_ensure_cnf)"
    if [[ -n "$cnf" ]]; then
        printf 'mysql --defaults-extra-file=%s' "$cnf"
    else
        printf 'mysql'
    fi
}

# Same, for mysqldump.
db_dump_cmd() {
    local cnf
    cnf="$(_db_ensure_cnf)"
    if [[ -n "$cnf" ]]; then
        printf 'mysqldump --defaults-extra-file=%s' "$cnf"
    else
        printf 'mysqldump'
    fi
}

################################################################################
# Validation
################################################################################

# Verify we can actually reach the server and run a statement.
# Returns 0 on success; on failure prints actionable diagnostics and returns 1.
db_check_connection() {
    local quiet="${1:-}"
    local cmd err rc
    cmd="$(db_admin_cmd)"
    err=$(mktemp)

    set +e
    $cmd -N -B -e "SELECT 1;" >/dev/null 2>"$err"
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        [[ "$quiet" == "quiet" ]] || sre_success "Database connection OK ($(db_describe))"
        rm -f "$err"
        return 0
    fi

    sre_error "Cannot connect to the database server ($(db_describe))"
    [[ -s "$err" ]] && sed 's/^/    /' "$err" >&2
    rm -f "$err"

    if db_is_remote; then
        sre_error ""
        sre_error "Checks for a remote SQL server:"
        sre_error "  1. Reachable:   nc -vz $(db_admin_host) $(db_admin_port)"
        sre_error "  2. Credentials: $SRE_DB_ADMIN_PASS_FILE holds the password for '$(db_admin_user)'"
        sre_error "  3. Remote grant: the admin user must be allowed from THIS host"
        sre_error "     On the DB server:"
        sre_error "       SELECT user, host FROM mysql.user WHERE user='$(db_admin_user)';"
        sre_error "  4. Bind address: the server must not be bound to 127.0.0.1 only"
        sre_error "  5. Firewall/security list must permit $(db_admin_port)/tcp from this host"
    else
        sre_error ""
        sre_error "Checks for a local SQL server:"
        sre_error "  1. Running:     systemctl status mariadb (or mysql)"
        sre_error "  2. Credentials: /root/.db_root_password"
        sre_error "  3. Installed:   run step 5 first"
    fi
    return 1
}

# Human-readable description of the current target, for logs and errors.
db_describe() {
    if db_is_remote; then
        printf 'remote %s@%s:%s' "$(db_admin_user)" "$(db_admin_host)" "$(db_admin_port)"
    else
        printf 'local socket as %s' "$(db_admin_user)"
    fi
}

# Guard for the PostgreSQL paths, which still use `sudo -u postgres psql`
# (local peer auth) and have no remote equivalent yet. Call before any PG
# admin work so remote+PG fails loudly instead of silently hitting a local
# server that may not exist.
db_require_local_pg() {
    if db_is_remote; then
        sre_error "PostgreSQL is not supported in remote database mode yet."
        sre_error "The PostgreSQL paths use local peer authentication (sudo -u postgres psql),"
        sre_error "which has no remote equivalent. Remote support currently covers"
        sre_error "MySQL and MariaDB only."
        sre_error ""
        sre_error "Options:"
        sre_error "  - Use MySQL/MariaDB for this project, or"
        sre_error "  - Set SRE_DB_MODE=local in $SRE_CONFIG_FILE and run a local PostgreSQL."
        return 1
    fi
    return 0
}
