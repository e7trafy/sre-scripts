#!/bin/bash
################################################################################
# SRE Helpers - Step 16: Clone Project
#
# Clones an existing provisioned site on this server into a new project under
# a different domain. Two purposes are supported:
#
#   --stage : non-public staging copy. Defaults to ON: noindex headers,
#             htpasswd gate, robots.txt disallow. APP_ENV gets flipped to
#             "staging" for Laravel. Default target is <slug>-stage.<rest>.
#   --live  : a second public copy of the same app under a different domain.
#             No protection by default, no APP_ENV flip, target domain must
#             be supplied (no auto-default — there's no sensible one).
#
# What it does:
#   1. Detect source project type (laravel/moodle/wordpress/nuxt/vue/static)
#      and its document root from the existing vhost.
#   2. Resolve the target URL scheme BEFORE any rewrite: probes the source
#      vhost for SSL; if the source serves https, the clone's APP_URL /
#      wwwroot / siteurl will be written as https from the start. This is
#      load-bearing for Moodle — a wwwroot whose scheme doesn't match the
#      served URL causes redirect loops and broken logins.
#   3. Copy files via rsync (handles release/current symlink layout).
#   4. Copy database into a fresh DB + user with a new generated password.
#   5. Rewrite app config for the new domain + DB + scheme:
#        Laravel    → .env (DB_*, APP_URL); APP_ENV=staging only for --stage
#        WordPress  → wp-config.php DB_*, ${prefix}options.siteurl/home, and
#                     a full wp search-replace (incl. serialized data) when
#                     wp-cli is available
#        Moodle     → config.php wwwroot/dataroot/DB AND tempdir/cachedir/
#                     localcachedir/backuptempdir if they point inside the
#                     source tree; admin/cli/purge_caches.php after rewrite
#   6. Create a new vhost (delegates to step 8 --yes).
#   7. Fix permissions.
#   8. Offer SSL via step 11 (mandatory if scheme was detected as https).
#
# What it does NOT do:
#   - Touch DNS (you point the new domain at this server yourself, or use
#     the same wildcard cert).
#   - Touch the source files or source database. The clone is read-only on
#     the source side.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=16

CL_SOURCE_DOMAIN=""
CL_TARGET_DOMAIN=""
CL_PURPOSE=""            # stage | live  (prompted if unset)
CL_MODE="full"           # full, files-only, db-only
CL_REGEN_APP_KEY="ask"   # laravel only: ask|yes|no
CL_TGT_SCHEME=""         # http | https  (auto-detected from source vhost)

# Protection — DEFAULTS are set after --purpose is resolved (live = off, stage = on)
CL_PROTECT=""               # yes|no   --no-protect / --protect overrides
CL_PROTECT_USER=""
CL_PROTECT_PASS=""
CL_ALLOW_IPS=()

# Table-skip plan for the DB phase. Three lists, populated from --skip-table /
# --skip-tables / --skip-tables-file, then refined at runtime per --skip-mode.
#   CL_SKIP_INPUT       = raw user-supplied table names (de-duped)
#   CL_SKIP_SCHEMA_ONLY = dump CREATE TABLE but no rows (--no-data + --where)
#   CL_SKIP_FULL        = exclude entirely from dump (no CREATE, no rows)
CL_SKIP_INPUT=()
CL_SKIP_SCHEMA_ONLY=()
CL_SKIP_FULL=()
CL_SKIP_MODE="ask"             # ask | schema-only | skip-entirely
CL_SKIP_TABLES_FILE=""
CL_NOINDEX=""               # X-Robots-Tag noindex + robots.txt Disallow: /
CL_HTPASSWD=""              # basic auth gate

# Initialize optional flags so `set -u` doesn't blow up on first reference
SRE_FORCE="${SRE_FORCE:-false}"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 16: Clone Project

  Copies an existing provisioned site on this server into a new project under
  a different domain. Works for laravel / moodle / wordpress / nuxt / vue /
  static. Files + database get cloned, app config is rewritten for the new
  domain + scheme, a new vhost is created.

Purpose:
  --stage               Non-public staging clone (default protection ON,
                        APP_ENV=staging for Laravel, default target -stage.<rest>)
  --live                Public live clone under a different domain
                        (no protection, no APP_ENV flip, --target required)

Options:
  --source <domain>     Source domain to clone (or prompted)
  --target <domain>     Target domain for the clone (or prompted)
  --mode <mode>         full | files-only | db-only       (default: full)
  --regen-app-key       Laravel: generate a fresh APP_KEY in the clone
  --keep-app-key        Laravel: reuse the source APP_KEY
  --scheme <s>          Force target URL scheme: http | https | auto
                        (default: auto — copies the scheme of the source vhost)

Database table skipping (DB phase only):
  --skip-table <name>   Skip rows from this table (repeatable)
  --skip-tables <list>  Comma-separated list of tables to skip
  --skip-tables-file <f>  Read table names from a file (one per line, # comments OK)
  --pick-tables         Interactively show source tables sorted by size and pick
                        which to skip + the mode per table
  --skip-mode <m>       What to do with skipped tables, without prompting:
                          schema-only    — keep CREATE TABLE, drop the rows
                          skip-entirely  — no CREATE, no rows (app must not query it)
                          ask            — prompt per table (default)
  Common targets: Moodle mdl_logstore_standard_log, mdl_sessions, mdl_cache_flags;
                  Laravel sessions, jobs, failed_jobs, cache, telescope_entries

Reset (start fresh after a botched clone):
  --reset               WIPE everything for the target (DB + user, /var/www/<target>,
                        vhost, htpasswd, SSL cert, .progress + .conf state files)
                        then run the clone from scratch. Destructive — requires
                        explicit confirmation unless --yes --force are also set.
  --reset-dry-run       Print what --reset would delete; exit without touching anything.

Protection (default: ON for --stage, OFF for --live):
  --protect             Force protection ON regardless of purpose
  --no-protect          Force protection OFF (htpasswd + noindex)
  --no-htpasswd         Skip HTTP basic auth (keep noindex)
  --no-noindex          Skip X-Robots-Tag + robots.txt (keep htpasswd)
  --protect-user <u>    Basic auth username                (default: staging)
  --protect-pass <p>    Basic auth password                (default: generated)
  --allow-ip <cidr>     IP/CIDR that bypasses basic auth   (repeatable)

Resume:
  --resume              Resume a previously-interrupted clone of the same
                        target. Reuses persisted DB name/user/password and
                        skips already-completed phases.
  --no-resume           Force a fresh run even when a .progress file exists.
                        Implies --force.

  --dry-run             Print planned actions only
  --yes                 Accept defaults without prompting
  --force               Allow overwriting an existing target non-interactively
                        (required with --yes when /var/www/<target> or its
                        vhost already exist; default-no prompt would otherwise
                        silently exit)
  --help                Show this help

Tip:
  Clones can take a while (rsync + mysqldump on large sites). Run under
  tmux/screen or with nohup so an SSH disconnect doesn't kill the clone:
    tmux new -s clone -d 'sudo bash $0 --live --source A --target B --yes --force'
    # then: tmux attach -t clone
  If it does get killed, re-run the SAME command and the script auto-resumes.

Examples:
  # Staging copy with default -stage. suffix
  sudo bash $0 --stage --source app.example.com

  # Live copy under a second public domain (no protection)
  sudo bash $0 --live --source app.example.com --target app2.example.com

  # Live Moodle clone — scheme auto-detected from source vhost
  sudo bash $0 --live --source learn.example.com --target learn2.example.com

  # Files-only sync between two existing domains
  sudo bash $0 --live --source app.example.com --target app2.example.com --mode files-only

  # Moodle clone, skip rows from huge log/session tables (keep schema)
  sudo bash $0 --live --source learn.example.com --target learn2.example.com \\
    --skip-tables mdl_logstore_standard_log,mdl_sessions,mdl_cache_flags \\
    --skip-mode schema-only

  # Same, reading from a file
  echo 'mdl_logstore_standard_log
mdl_sessions
mdl_cache_flags
# Lines starting with # and blank lines are ignored' > /tmp/skip.txt
  sudo bash $0 --live --source A --target B --skip-tables-file /tmp/skip.txt --skip-mode schema-only
EOF
}

_raw_args=("$@")
sre_parse_args "16-clone-project.sh" "${_raw_args[@]}"

_i=0
_protect_explicit=""
_noindex_explicit=""
_htpasswd_explicit=""
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --source)         _i=$((_i + 1)); CL_SOURCE_DOMAIN="${_raw_args[$_i]:-}" ;;
        --target)         _i=$((_i + 1)); CL_TARGET_DOMAIN="${_raw_args[$_i]:-}" ;;
        --mode)           _i=$((_i + 1)); CL_MODE="${_raw_args[$_i]:-full}" ;;
        --regen-app-key)  CL_REGEN_APP_KEY="yes" ;;
        --keep-app-key)   CL_REGEN_APP_KEY="no" ;;
        --stage|--staging) CL_PURPOSE="stage" ;;
        --live|--production) CL_PURPOSE="live" ;;
        --scheme)         _i=$((_i + 1)); CL_TGT_SCHEME="${_raw_args[$_i]:-}" ;;
        --protect)        _protect_explicit="yes"; _noindex_explicit="yes"; _htpasswd_explicit="yes" ;;
        --no-protect)     _protect_explicit="no";  _noindex_explicit="no";  _htpasswd_explicit="no"  ;;
        --no-htpasswd)    _htpasswd_explicit="no" ;;
        --no-noindex)     _noindex_explicit="no" ;;
        --protect-user)   _i=$((_i + 1)); CL_PROTECT_USER="${_raw_args[$_i]:-}" ;;
        --protect-pass)   _i=$((_i + 1)); CL_PROTECT_PASS="${_raw_args[$_i]:-}" ;;
        --allow-ip)       _i=$((_i + 1)); CL_ALLOW_IPS+=("${_raw_args[$_i]:-}") ;;
        --skip-table)     _i=$((_i + 1)); CL_SKIP_INPUT+=("${_raw_args[$_i]:-}") ;;
        --skip-tables)
            _i=$((_i + 1))
            IFS=',' read -ra _skip_list <<<"${_raw_args[$_i]:-}"
            for _t in "${_skip_list[@]}"; do
                _t="${_t// /}"
                [[ -n "$_t" ]] && CL_SKIP_INPUT+=("$_t")
            done
            ;;
        --skip-tables-file)
            _i=$((_i + 1)); CL_SKIP_TABLES_FILE="${_raw_args[$_i]:-}"
            ;;
        --skip-mode)
            _i=$((_i + 1)); CL_SKIP_MODE="${_raw_args[$_i]:-ask}"
            ;;
        --force|-f)       SRE_FORCE="true" ;;
        --resume)         CL_RESUME_MODE="yes" ;;
        --no-resume)      CL_RESUME_MODE="no"; SRE_FORCE="true" ;;
        --reset)          CL_RESET="yes" ;;
        --reset-dry-run)  CL_RESET="dry-run" ;;
        --pick-tables)    CL_PICK_TABLES="yes" ;;
    esac
    _i=$((_i + 1))
done

# Default-init optional vars so set -u doesn't trip on first reference
CL_RESUME_MODE="${CL_RESUME_MODE:-auto}"   # auto|yes|no
CL_RESET="${CL_RESET:-no}"                 # no | yes | dry-run
CL_PICK_TABLES="${CL_PICK_TABLES:-no}"     # no | yes

################################################################################
# Staging protection helpers
#
#   - Writes an HTTP basic-auth file (apache2-utils / httpd-tools)
#   - Patches the final vhost (post-Certbot) to add:
#       * X-Robots-Tag noindex (response header — authoritative for bots)
#       * auth_basic + auth_basic_user_file (Nginx) or AuthType Basic (Apache)
#       * allow <ip>/deny all with satisfy any for IP allowlist bypass
#   - Drops a robots.txt at the doc root as belt-and-suspenders
################################################################################

# Build a single Nginx snippet to insert inside every server { } block.
_build_nginx_protect_snippet() {
    local htpasswd_file="$1"
    local snippet=""

    snippet+=$'\n    # --- BEGIN sre-helpers staging protection ---\n'

    if [[ "$CL_NOINDEX" == "yes" ]]; then
        snippet+=$'    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;\n'
    fi

    if [[ "$CL_HTPASSWD" == "yes" ]]; then
        if [[ ${#CL_ALLOW_IPS[@]} -gt 0 ]]; then
            snippet+=$'    satisfy any;\n'
            local ip
            for ip in "${CL_ALLOW_IPS[@]}"; do
                [[ -n "$ip" ]] && snippet+="    allow ${ip};"$'\n'
            done
            snippet+=$'    deny all;\n'
        fi
        snippet+=$'    auth_basic           "Restricted - Clone";\n'
        snippet+="    auth_basic_user_file ${htpasswd_file};"$'\n'
    fi

    snippet+=$'    # --- END sre-helpers staging protection ---\n'
    printf '%s' "$snippet"
}

_build_apache_protect_snippet() {
    local htpasswd_file="$1"
    local snippet=""

    snippet+=$'\n    # --- BEGIN sre-helpers staging protection ---\n'

    if [[ "$CL_NOINDEX" == "yes" ]]; then
        snippet+=$'    Header always set X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"\n'
    fi

    if [[ "$CL_HTPASSWD" == "yes" ]]; then
        snippet+=$'    <Location "/">\n'
        snippet+=$'        AuthType Basic\n'
        snippet+=$'        AuthName "Restricted - Clone"\n'
        snippet+="        AuthUserFile ${htpasswd_file}"$'\n'
        if [[ ${#CL_ALLOW_IPS[@]} -gt 0 ]]; then
            snippet+=$'        <RequireAny>\n'
            snippet+=$'            Require valid-user\n'
            local ip
            for ip in "${CL_ALLOW_IPS[@]}"; do
                [[ -n "$ip" ]] && snippet+="            Require ip ${ip}"$'\n'
            done
            snippet+=$'        </RequireAny>\n'
        else
            snippet+=$'        Require valid-user\n'
        fi
        snippet+=$'    </Location>\n'
    fi

    snippet+=$'    # --- END sre-helpers staging protection ---\n'
    printf '%s' "$snippet"
}

# Patch a vhost file: insert the snippet immediately before the last `}` of every
# server block (Nginx) or before each </VirtualHost> (Apache). Idempotent: removes
# any prior BEGIN/END block first.
_inject_protection_into_vhost() {
    local vhost_file="$1" snippet="$2" ws="$3"

    [[ ! -f "$vhost_file" ]] && return 1

    # Strip any prior block (so re-runs don't stack snippets)
    sed -i '/# --- BEGIN sre-helpers staging protection ---/,/# --- END sre-helpers staging protection ---/d' "$vhost_file"

    # Write snippet to a temp file (multi-line, safer than r-flag with stdin)
    local tmp; tmp=$(mktemp)
    printf '%s' "$snippet" > "$tmp"

    case "$ws" in
        nginx)
            # Track brace depth char-by-char. Inject snippet just before the
            # closing brace of any top-level server { ... } block.
            awk -v snippet_file="$tmp" '
                BEGIN {
                    while ((getline ln < snippet_file) > 0) snippet = snippet ln "\n"
                    close(snippet_file)
                    in_server = 0
                    depth = 0
                    buf = ""
                }
                {
                    buf = $0
                    out = ""
                    n = length(buf)
                    for (i = 1; i <= n; i++) {
                        c = substr(buf, i, 1)
                        if (!in_server && c == "{") {
                            # Check the chars before this { for "server"
                            tail = substr(buf, 1, i - 1)
                            if (tail ~ /(^|[^A-Za-z_])server[[:space:]]*$/) {
                                in_server = 1
                                depth = 1
                                out = out c
                                continue
                            }
                        }
                        if (in_server) {
                            if (c == "{") depth++
                            else if (c == "}") {
                                depth--
                                if (depth == 0) {
                                    # Insert snippet before this closing brace
                                    out = out "\n" snippet
                                    in_server = 0
                                }
                            }
                        }
                        out = out c
                    }
                    print out
                }
            ' "$vhost_file" > "${vhost_file}.tmp" && mv "${vhost_file}.tmp" "$vhost_file"
            ;;
        apache)
            awk -v snippet_file="$tmp" '
                BEGIN {
                    while ((getline line < snippet_file) > 0) snippet = snippet line "\n"
                    close(snippet_file)
                }
                /<\/VirtualHost>/ { printf "%s", snippet }
                { print }
            ' "$vhost_file" > "${vhost_file}.tmp" && mv "${vhost_file}.tmp" "$vhost_file"
            ;;
    esac

    rm -f "$tmp"
    return 0
}

require_root
sre_header "Step 16: Clone Project"

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
# Clone purpose: stage vs live
#
# This decides the protection defaults, whether APP_ENV gets flipped, and
# whether we offer a default <slug>-stage. target.
################################################################################

if [[ -z "$CL_PURPOSE" ]]; then
    sre_header "Clone Purpose"
    purpose_choice=$(prompt_choice "What is this clone for?" \
        "stage  — non-public staging copy (protected, APP_ENV=staging)" \
        "live   — second public copy under a different domain (no protection)")
    case "$purpose_choice" in
        stage*) CL_PURPOSE="stage" ;;
        live*)  CL_PURPOSE="live"  ;;
    esac
fi

case "$CL_PURPOSE" in
    stage|live) ;;
    *) sre_error "Invalid purpose: $CL_PURPOSE"; exit 1 ;;
esac

sre_info "Purpose: $CL_PURPOSE"

# Resolve protection defaults based on purpose (explicit flags win)
if [[ "$CL_PURPOSE" == "stage" ]]; then
    CL_PROTECT="${_protect_explicit:-yes}"
    CL_NOINDEX="${_noindex_explicit:-yes}"
    CL_HTPASSWD="${_htpasswd_explicit:-yes}"
else
    CL_PROTECT="${_protect_explicit:-no}"
    CL_NOINDEX="${_noindex_explicit:-no}"
    CL_HTPASSWD="${_htpasswd_explicit:-no}"
fi

################################################################################
# Target URL scheme — detect BEFORE any config rewrite
#
# Probe the source vhost for an SSL listener / cert. If the source serves
# https, we'll write https URLs from the start; the SSL step at the end
# provisions a matching cert. This is load-bearing for Moodle: a wwwroot
# whose scheme doesn't match the served scheme breaks logins.
################################################################################

if [[ -z "$CL_TGT_SCHEME" || "$CL_TGT_SCHEME" == "auto" ]]; then
    case "$web_server" in
        nginx)
            if grep -qE 'listen\s+443|ssl_certificate' "$src_vhost" 2>/dev/null; then
                CL_TGT_SCHEME="https"
            else
                CL_TGT_SCHEME="http"
            fi
            ;;
        apache)
            if grep -qE 'VirtualHost\s+\*:443|SSLEngine\s+on|SSLCertificateFile' "$src_vhost" 2>/dev/null; then
                CL_TGT_SCHEME="https"
            else
                CL_TGT_SCHEME="http"
            fi
            ;;
    esac
fi

case "$CL_TGT_SCHEME" in
    http|https) ;;
    *) sre_error "Invalid scheme: $CL_TGT_SCHEME (must be http or https or auto)"; exit 1 ;;
esac

sre_info "Target scheme: $CL_TGT_SCHEME (from source vhost)"

################################################################################
# Detect source project type + root
################################################################################

# Document root from existing vhost.
#
# Tricky: SSL-enabled nginx vhosts (after step 11) have an ACME challenge
# block with its own `root /var/www/letsencrypt;` directive at the top of
# the HTTP server. A naive `grep -m1 'root '` picks that line up. We use
# awk to track brace depth and only accept top-level `root` directives,
# preferring ones inside the HTTPS server block (listen 443) when present.
src_doc_root=""
case "$web_server" in
    nginx)
        # Pull all top-level `root` directives + which server block (80/443)
        # they're in, then prefer the 443 block if multiple exist.
        src_doc_root=$(awk '
            BEGIN { depth = 0; in_server = 0; cur_listen = ""; best_443 = ""; best_80 = "" }
            {
                line = $0
                n = length(line)
                # Track listen directive
                if (line ~ /^[[:space:]]*listen[[:space:]]+443/) cur_listen = "443"
                else if (line ~ /^[[:space:]]*listen[[:space:]]+80/ && cur_listen == "") cur_listen = "80"
                # Capture top-level root (depth == 1 inside a server block)
                if (in_server && depth == 1 && line ~ /^[[:space:]]*root[[:space:]]+/) {
                    sub(/^[[:space:]]*root[[:space:]]+/, "", line)
                    sub(/;.*$/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    if (cur_listen == "443" && best_443 == "") best_443 = line
                    else if (cur_listen != "443" && best_80 == "") best_80 = line
                }
                # Track braces (after we captured root for this line)
                line2 = $0
                for (i = 1; i <= length(line2); i++) {
                    c = substr(line2, i, 1)
                    if (c == "{") {
                        if (!in_server) {
                            # Detect "server {" entering
                            tail = substr(line2, 1, i - 1)
                            if (tail ~ /(^|[^A-Za-z_])server[[:space:]]*$/) {
                                in_server = 1
                                depth = 1
                                continue
                            }
                        } else {
                            depth++
                        }
                    } else if (c == "}" && in_server) {
                        depth--
                        if (depth == 0) {
                            in_server = 0
                            cur_listen = ""
                        }
                    }
                }
            }
            END { print (best_443 != "" ? best_443 : best_80) }
        ' "$src_vhost")
        ;;
    apache) src_doc_root=$( { grep -im1 'DocumentRoot' "$src_vhost" || true; } | awk '{print $2}' | tr -d '"') ;;
esac

# Reject obvious wrong picks (ACME webroot, empty, nonexistent)
if [[ "$src_doc_root" == "/var/www/letsencrypt" || \
      "$src_doc_root" == "/var/www/html" || \
      -z "$src_doc_root" || ! -d "$src_doc_root" ]]; then
    sre_warning "Could not auto-detect doc root from vhost (got: $src_doc_root)"

    # Try a sensible default based on what exists under /var/www/<domain>
    fallback_default="/var/www/${CL_SOURCE_DOMAIN}/current"
    for cand in \
        "/var/www/${CL_SOURCE_DOMAIN}/public_html" \
        "/var/www/${CL_SOURCE_DOMAIN}/current/public" \
        "/var/www/${CL_SOURCE_DOMAIN}/current" \
        "/var/www/${CL_SOURCE_DOMAIN}"; do
        if [[ -d "$cand" ]] && find "$cand" -maxdepth 1 -name '*.php' 2>/dev/null | head -1 | grep -q .; then
            fallback_default="$cand"
            break
        fi
    done

    src_doc_root=$(prompt_input "Source document root" "$fallback_default")
fi

# Project base on disk = /var/www/<domain>
src_proj_base="/var/www/${CL_SOURCE_DOMAIN}"

# Detect type: try config files first, then vhost markers
src_type=""
src_moodle_config=""   # populated if we find Moodle's config.php (may not be in doc_root)

# Run config.php detection as root via sudo because some installs lock the
# file to 640 owned by www-data, and a bare grep would silently miss it.
_grep_root() {
    if [[ $EUID -eq 0 ]]; then
        grep -q "$@"
    else
        sudo -n grep -q "$@" 2>/dev/null
    fi
}

# Hunt for a Moodle config.php anywhere reasonable. Order:
#   1. doc_root/config.php
#   2. doc_root/../config.php             (some installs put doc root one below)
#   3. project base + first 3 levels      (find -maxdepth 3)
# A real Moodle config.php has $CFG->dbtype.
_find_moodle_config() {
    local candidates=(
        "${src_doc_root}/config.php"
        "${src_doc_root%/}/../config.php"
        "${src_proj_base}/config.php"
        "${src_proj_base}/public_html/config.php"
        "${src_proj_base}/current/config.php"
        "${src_proj_base}/html/config.php"
        "${src_proj_base}/www/config.php"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]] && _grep_root '\$CFG->dbtype' "$c"; then
            readlink -f "$c"
            return 0
        fi
    done

    # Broader fall-back: scan up to depth 3 for any config.php that has $CFG->dbtype
    local found
    found=$(find "$src_proj_base" -maxdepth 3 -type f -name config.php 2>/dev/null \
        | while IFS= read -r f; do
              _grep_root '\$CFG->dbtype' "$f" && echo "$f" && break
          done | head -1)
    [[ -n "$found" ]] && { readlink -f "$found"; return 0; }
    return 1
}

# laravel: doc_root ends in /current/public → release layout
if [[ -f "${src_proj_base}/current/artisan" ]]; then
    src_type="laravel"
elif [[ -f "${src_doc_root}/wp-config.php" ]]; then
    src_type="wordpress"
elif src_moodle_config=$(_find_moodle_config); then
    src_type="moodle"
    sre_info "Found Moodle config.php: $src_moodle_config"
elif [[ -d "${src_proj_base}/moodledata" ]] || [[ -d "/u02/appdata/${CL_SOURCE_DOMAIN}/moodledata" ]]; then
    # Couldn't read config.php but moodledata directory exists → still Moodle.
    sre_warning "moodledata/ found but config.php couldn't be read — treating as Moodle anyway."
    sre_warning "If permissions are tight on config.php (640 root or www-data), run this script as root."
    src_type="moodle"
elif grep -q 'proxy_pass.*127\.0\.0\.1' "$src_vhost" 2>/dev/null; then
    src_type="nuxt"
elif grep -q 'try_files.*index\.html' "$src_vhost" 2>/dev/null; then
    src_type="vue"
else
    src_type="static"
fi

# For Moodle, override the moodle-config path used later in the rewrite step
# so we don't assume it sits at <doc_root>/config.php.
if [[ "$src_type" == "moodle" && -n "$src_moodle_config" ]]; then
    src_moodle_config_dir=$(dirname "$src_moodle_config")
fi

sre_info "Detected type: $src_type"
sre_info "Source root:   $src_proj_base"
sre_info "Source doc:    $src_doc_root"

# Sanity check: if we ended up with "static" but the project base has lots of
# PHP / dynamic content, something is off — warn loudly so the user doesn't
# silently end up cloning nothing useful.
if [[ "$src_type" == "static" ]]; then
    php_count=$(find "$src_proj_base" -maxdepth 3 -type f -name '*.php' 2>/dev/null | head -5 | wc -l)
    if [[ "$php_count" -gt 0 ]]; then
        sre_warning "Type detected as 'static' but found PHP files under $src_proj_base."
        sre_warning "If this is actually Laravel/Moodle/WordPress, the layout doesn't match what"
        sre_warning "the detector expects. Likely causes:"
        sre_warning "  - config.php / wp-config.php is not at the doc root"
        sre_warning "  - file permissions block detection (run as root)"
        sre_warning "  - artisan / wp-config.php / Moodle config.php is named/located unusually"
        sre_warning ""
        sre_warning "Doc root:  $src_doc_root"
        sre_warning "Files at doc root:"
        ls -la "$src_doc_root" 2>/dev/null | head -10 | sed 's/^/    /'

        forced=$(prompt_choice "Force a specific type?" "laravel" "moodle" "wordpress" "keep static")
        case "$forced" in
            laravel|moodle|wordpress)
                src_type="$forced"
                sre_info "Forced type: $src_type"
                # Re-run Moodle config probe so downstream uses the right path
                if [[ "$src_type" == "moodle" ]]; then
                    src_moodle_config=$(_find_moodle_config) || src_moodle_config=""
                    if [[ -n "$src_moodle_config" ]]; then
                        src_moodle_config_dir=$(dirname "$src_moodle_config")
                        sre_info "Found Moodle config.php after force: $src_moodle_config"
                    else
                        sre_warning "Couldn't locate config.php — DB creds will be prompted."
                    fi
                fi
                ;;
            *) ;;
        esac
    fi
fi

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
    if [[ "$CL_PURPOSE" == "stage" ]]; then
        default_target="${CL_SOURCE_DOMAIN%%.*}-stage.${CL_SOURCE_DOMAIN#*.}"
        CL_TARGET_DOMAIN=$(prompt_input "Target domain for the clone" "$default_target")
    else
        # Live clone — no sensible default. Force the user to choose explicitly.
        CL_TARGET_DOMAIN=$(prompt_input "Target domain for the live clone (required)" "")
    fi
fi
[[ -z "$CL_TARGET_DOMAIN" ]] && { sre_error "Target domain required"; exit 1; }

if [[ "$CL_TARGET_DOMAIN" == "$CL_SOURCE_DOMAIN" ]]; then
    sre_error "Target must differ from source."
    exit 1
fi

tgt_vhost="${vhost_dir}/${CL_TARGET_DOMAIN}.conf"
tgt_proj_base="/var/www/${CL_TARGET_DOMAIN}"

################################################################################
# Resume detection
#
# Look for a .progress file from a prior (interrupted) clone of the same
# target. If source+target match, switch to resume mode: reuse the persisted
# tgt_db_name/user/password so we don't orphan the half-imported DB, and
# skip phases that have been marked complete.
################################################################################

CLONE_STATE_DIR="/etc/sre-helpers/clones"
mkdir -p "$CLONE_STATE_DIR"
CLONE_PROGRESS="${CLONE_STATE_DIR}/${CL_TARGET_DOMAIN}.progress"
CLONE_STATE="${CLONE_STATE_DIR}/${CL_TARGET_DOMAIN}.conf"

################################################################################
# --reset : wipe everything we know about for this target, then continue.
#
# Removes (in order):
#   1. Persisted DB + user from any prior run (read from .progress / .conf)
#   2. /var/www/<target>/  (entire project tree)
#   3. Vhost in sites-available/ + symlink in sites-enabled/ + any .bak siblings
#   4. htpasswd file at the standard per-domain path
#   5. SSL: /etc/letsencrypt/live|archive|renewal/<target>* (skipped if cert
#      is shared by a wildcard — only deletes exact-name dirs)
#   6. .progress and .conf state files
#
# Source side is never touched.
################################################################################

if [[ "$CL_RESET" == "yes" || "$CL_RESET" == "dry-run" ]]; then
    sre_header "Reset: Wiping Everything For ${CL_TARGET_DOMAIN}"

    if [[ "$CL_RESET" == "dry-run" ]]; then
        sre_warning "Dry-run — nothing will actually be deleted."
    fi

    # Try to read DB name/user from any prior state so we drop the right one.
    # `|| true` on every pipe: grep returns 1 when there's no match, which
    # would trip set -o pipefail + set -e and silently exit the script.
    _reset_db_name=""
    _reset_db_user=""
    for _sf in "$CLONE_PROGRESS" "$CLONE_STATE"; do
        if [[ -r "$_sf" ]]; then
            _v=$( { grep -m1 '^tgt_db_name=' "$_sf" || true; } | sed -E "s/^tgt_db_name=//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" )
            if [[ -n "$_v" && -z "$_reset_db_name" ]]; then _reset_db_name="$_v"; fi
            _v=$( { grep -m1 '^CL_TGT_DB_NAME=' "$_sf" || true; } | sed -E "s/^CL_TGT_DB_NAME=//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" )
            if [[ -n "$_v" && -z "$_reset_db_name" ]]; then _reset_db_name="$_v"; fi
            _v=$( { grep -m1 '^tgt_db_user=' "$_sf" || true; } | sed -E "s/^tgt_db_user=//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" )
            if [[ -n "$_v" && -z "$_reset_db_user" ]]; then _reset_db_user="$_v"; fi
            _v=$( { grep -m1 '^CL_TGT_DB_USER=' "$_sf" || true; } | sed -E "s/^CL_TGT_DB_USER=//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" )
            if [[ -n "$_v" && -z "$_reset_db_user" ]]; then _reset_db_user="$_v"; fi
        fi
    done

    # Compute the enabled-symlink path up front (used in both summary + delete)
    _enabled_link="${tgt_vhost/sites-available/sites-enabled}"

    # Disable `set -e` for the whole reset block. Every check here is "does X
    # exist?" and a missing X is the expected case on a clean target — we
    # don't want a failed `[[ -n "$x" ]]` test to kill the script under set -e.
    set +e

    sre_info "Will remove (if present):"
    if [[ -n "$_reset_db_name" ]]; then sre_info "  DB:           $_reset_db_name"; fi
    if [[ -n "$_reset_db_user" ]]; then sre_info "  DB user:      ${_reset_db_user}@localhost"; fi
    sre_info "  Project dir:  ${tgt_proj_base}/"
    sre_info "  Vhost conf:   ${tgt_vhost}"
    if [[ "$_enabled_link" != "$tgt_vhost" ]]; then
        sre_info "  Enabled link: $_enabled_link"
    fi
    for _htpd in "/etc/nginx/htpasswd-${CL_TARGET_DOMAIN}" "/etc/apache2/htpasswd-${CL_TARGET_DOMAIN}" "/etc/httpd/htpasswd-${CL_TARGET_DOMAIN}"; do
        if [[ -f "$_htpd" ]]; then sre_info "  htpasswd:     $_htpd"; fi
    done
    for _le in "/etc/letsencrypt/live/${CL_TARGET_DOMAIN}" "/etc/letsencrypt/archive/${CL_TARGET_DOMAIN}" "/etc/letsencrypt/renewal/${CL_TARGET_DOMAIN}.conf"; do
        if [[ -e "$_le" ]]; then sre_info "  Let's Encrypt: $_le"; fi
    done
    if [[ -f "$CLONE_PROGRESS" ]]; then sre_info "  Progress:     $CLONE_PROGRESS"; fi
    if [[ -f "$CLONE_STATE" ]];    then sre_info "  State:        $CLONE_STATE"; fi

    if [[ "$CL_RESET" == "dry-run" ]]; then
        sre_info "Dry-run complete. Pass --reset (without --reset-dry-run) to actually delete."
        set -e
        exit 0
    fi

    # Confirm unless --yes + --force already given
    if [[ "$SRE_YES" != "true" || "$SRE_FORCE" != "true" ]]; then
        if ! prompt_yesno "Proceed with DESTRUCTIVE reset?" "no"; then
            sre_skipped "Reset cancelled."
            set -e
            exit 4
        fi
    else
        sre_warning "--yes --force given: proceeding with destructive reset without prompt"
    fi

    # 1. Drop DB + user
    if [[ -n "$_reset_db_name" || -n "$_reset_db_user" ]]; then
        _db_root_pass=""
        if [[ -f /root/.db_root_password ]]; then
            _db_root_pass=$(cat /root/.db_root_password)
        fi
        _mysql_cmd="mysql"
        if [[ -n "$_db_root_pass" ]]; then
            _mysql_cmd="mysql -u root -p${_db_root_pass}"
        fi
        if [[ -n "$_reset_db_name" ]]; then
            if $_mysql_cmd -e "DROP DATABASE IF EXISTS \`${_reset_db_name}\`;" 2>/dev/null; then
                sre_success "Dropped DB: $_reset_db_name"
            else
                sre_warning "Could not drop DB $_reset_db_name (may not exist or auth failed)"
            fi
        fi
        if [[ -n "$_reset_db_user" ]]; then
            if $_mysql_cmd -e "DROP USER IF EXISTS '${_reset_db_user}'@'localhost';" 2>/dev/null; then
                sre_success "Dropped user: ${_reset_db_user}@localhost"
            else
                sre_warning "Could not drop user ${_reset_db_user}@localhost"
            fi
        fi
        # PostgreSQL best-effort
        if command -v psql &>/dev/null && [[ -n "$_reset_db_name" ]]; then
            if sudo -u postgres dropdb --if-exists "$_reset_db_name" 2>/dev/null; then
                sre_success "Dropped PG DB: $_reset_db_name"
            fi
            sudo -u postgres psql -c "DROP ROLE IF EXISTS ${_reset_db_user};" 2>/dev/null
        fi
    fi

    # 2. Wipe project tree (safety: only under /var/www/)
    if [[ -d "$tgt_proj_base" ]]; then
        case "$tgt_proj_base" in
            /var/www/*)
                rm -rf "$tgt_proj_base" && sre_success "Removed: $tgt_proj_base"
                ;;
            *)
                sre_error "Refusing to rm -rf '$tgt_proj_base' (not under /var/www/)"
                set -e
                exit 1
                ;;
        esac
    fi
    # Alternate moodledata location
    if [[ -d "/u02/appdata/${CL_TARGET_DOMAIN}" ]]; then
        rm -rf "/u02/appdata/${CL_TARGET_DOMAIN}" && sre_success "Removed: /u02/appdata/${CL_TARGET_DOMAIN}"
    fi

    # 3. Vhost files (+ enabled symlink + any .bak siblings)
    if [[ -f "$tgt_vhost" ]]; then
        rm -f "$tgt_vhost" && sre_success "Removed: $tgt_vhost"
    fi
    if [[ "$_enabled_link" != "$tgt_vhost" && -L "$_enabled_link" ]]; then
        rm -f "$_enabled_link" && sre_success "Removed: $_enabled_link"
    fi
    # Backup files (use nullglob so unmatched globs become no-ops, not literals)
    shopt -s nullglob
    for _bak in "${tgt_vhost}".*.bak "${tgt_vhost}.bak"; do
        if [[ -e "$_bak" ]]; then
            rm -f "$_bak" && sre_success "Removed: $_bak"
        fi
    done
    shopt -u nullglob

    # 4. htpasswd
    for _htpd in "/etc/nginx/htpasswd-${CL_TARGET_DOMAIN}" "/etc/apache2/htpasswd-${CL_TARGET_DOMAIN}" "/etc/httpd/htpasswd-${CL_TARGET_DOMAIN}"; do
        if [[ -f "$_htpd" ]]; then
            rm -f "$_htpd" && sre_success "Removed: $_htpd"
        fi
    done

    # 5. Let's Encrypt (exact-name match only; wildcards untouched)
    if command -v certbot &>/dev/null; then
        if [[ -e "/etc/letsencrypt/live/${CL_TARGET_DOMAIN}" ]]; then
            if certbot delete --non-interactive --cert-name "${CL_TARGET_DOMAIN}" 2>/dev/null; then
                sre_success "Deleted LE cert: ${CL_TARGET_DOMAIN}"
            else
                sre_warning "certbot delete failed for ${CL_TARGET_DOMAIN}"
            fi
        fi
    else
        for _le in "/etc/letsencrypt/live/${CL_TARGET_DOMAIN}" "/etc/letsencrypt/archive/${CL_TARGET_DOMAIN}" "/etc/letsencrypt/renewal/${CL_TARGET_DOMAIN}.conf"; do
            if [[ -e "$_le" ]]; then
                rm -rf "$_le" && sre_success "Removed: $_le"
            fi
        done
    fi

    # 6. State files
    if [[ -f "$CLONE_PROGRESS" ]]; then
        rm -f "$CLONE_PROGRESS" && sre_success "Removed: $CLONE_PROGRESS"
    fi
    if [[ -f "$CLONE_STATE" ]]; then
        rm -f "$CLONE_STATE" && sre_success "Removed: $CLONE_STATE"
    fi

    # Reload web server so the removed vhost stops being served
    case "$web_server" in
        nginx)
            if svc_reload nginx 2>/dev/null; then sre_info "Nginx reloaded"; fi
            ;;
        apache)
            case "$os_family" in
                debian) svc_reload apache2 2>/dev/null ;;
                rhel)   svc_reload httpd   2>/dev/null ;;
            esac
            ;;
    esac

    # Restore set -e for the rest of the script
    set -e

    sre_success "Reset complete — continuing with fresh clone"

    # Reset wipes any previous progress, so resume must not kick in
    CL_RESUME_MODE="no"
fi

CLONE_RESUMING="no"
# All phase-completion flags default to "" (= not done)
PHASE_INIT_DONE=""
PHASE_FILES_DONE=""
PHASE_DB_DONE=""
PHASE_CONFIG_DONE=""
PHASE_VHOST_DONE=""
PHASE_SSL_DONE=""
PHASE_PROTECT_DONE=""
PHASE_PERMS_DONE=""
PHASE_FINISH_DONE=""

if [[ -f "$CLONE_PROGRESS" ]]; then
    # Source the file in a subshell first so we can check it without polluting
    # our env in case it's stale / wrong target.
    saved_src=$( { grep -m1 '^CL_SOURCE_DOMAIN=' "$CLONE_PROGRESS" 2>/dev/null || true; } | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    saved_tgt=$( { grep -m1 '^CL_TARGET_DOMAIN=' "$CLONE_PROGRESS" 2>/dev/null || true; } | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

    if [[ "$saved_src" == "$CL_SOURCE_DOMAIN" && "$saved_tgt" == "$CL_TARGET_DOMAIN" ]]; then
        sre_header "Detected Previous Clone Attempt"
        sre_info "  Progress file: $CLONE_PROGRESS"
        # Show what's already done
        if grep -q '^PHASE_FILES_DONE=' "$CLONE_PROGRESS";   then sre_info "    [DONE] files copied"; fi
        if grep -q '^PHASE_DB_DONE=' "$CLONE_PROGRESS";      then sre_info "    [DONE] database imported"; fi
        if grep -q '^PHASE_CONFIG_DONE=' "$CLONE_PROGRESS";  then sre_info "    [DONE] app config rewritten"; fi
        if grep -q '^PHASE_VHOST_DONE=' "$CLONE_PROGRESS";   then sre_info "    [DONE] vhost created"; fi
        if grep -q '^PHASE_SSL_DONE=' "$CLONE_PROGRESS";     then sre_info "    [DONE] SSL configured"; fi
        if grep -q '^PHASE_PROTECT_DONE=' "$CLONE_PROGRESS"; then sre_info "    [DONE] protection applied"; fi
        if grep -q '^PHASE_PERMS_DONE=' "$CLONE_PROGRESS";   then sre_info "    [DONE] permissions fixed"; fi

        # Decide resume vs fresh
        case "$CL_RESUME_MODE" in
            yes)
                CLONE_RESUMING="yes"
                sre_info "Resume mode: explicit --resume"
                ;;
            no)
                CLONE_RESUMING="no"
                sre_warning "Resume mode disabled by --no-resume → discarding previous progress"
                rm -f "$CLONE_PROGRESS"
                ;;
            auto)
                if prompt_yesno "Resume from where it left off?" "yes"; then
                    CLONE_RESUMING="yes"
                else
                    CLONE_RESUMING="no"
                    rm -f "$CLONE_PROGRESS"
                fi
                ;;
        esac

        if [[ "$CLONE_RESUMING" == "yes" ]]; then
            # Pull persisted state into the current shell. Disable set -e while
            # sourcing — a bad line shouldn't kill us; we warn and continue.
            set +e
            source "$CLONE_PROGRESS" 2>/tmp/sre_progress_err.$$
            _rc=$?
            set -e
            if [[ $_rc -ne 0 ]]; then
                sre_warning "Could not fully parse $CLONE_PROGRESS (see /tmp/sre_progress_err.$$)"
                sre_warning "Continuing — phases will be re-run as needed."
            fi
            sre_success "Resuming clone of $CL_SOURCE_DOMAIN → $CL_TARGET_DOMAIN"
            sre_info  "  Target DB:   ${tgt_db_name:-<not yet set>}"
            sre_info  "  Target user: ${tgt_db_user:-<not yet set>}"
        fi
    else
        sre_warning "Found $CLONE_PROGRESS but it's for a DIFFERENT clone (${saved_src:-?} → ${saved_tgt:-?})."
        sre_warning "Will not auto-resume. Pass --no-resume to discard, or remove the file manually."
    fi
fi

# Progress-file writer (key=quoted-value via printf %q)
progress_set() {
    local key="$1" value="$2"
    # Strip any prior line for this key
    if [[ -f "$CLONE_PROGRESS" ]] && grep -q "^${key}=" "$CLONE_PROGRESS" 2>/dev/null; then
        sed -i "/^${key}=/d" "$CLONE_PROGRESS"
    fi
    printf '%s=%q\n' "$key" "$value" >> "$CLONE_PROGRESS"
    chmod 600 "$CLONE_PROGRESS"
}

progress_mark_phase() {
    local phase="$1"
    progress_set "PHASE_${phase}_DONE" "$(date '+%Y-%m-%d %H:%M:%S')"
    eval "PHASE_${phase}_DONE=1"
}

progress_phase_done() {
    local phase="$1"
    local var="PHASE_${phase}_DONE"
    [[ -n "${!var:-}" ]]
}

# Refuse to overwrite an existing target unless user confirms.
#
# Important: under --yes / SRE_YES, prompt_yesno returns the DEFAULT. Because
# overwrite is destructive its default is "no", so a non-interactive re-run
# previously exited silently here AFTER the "Detected type" line — leaving
# any stale vhost from a prior failed/broken clone in place. To proceed
# non-interactively, pass --force.
#
# Resume case: we skip this guard entirely — the existing target IS the
# in-progress clone we're trying to finish.
if [[ "$CLONE_RESUMING" != "yes" ]] && [[ -d "$tgt_proj_base" || -f "$tgt_vhost" ]]; then
    sre_warning "Target already exists: $tgt_proj_base (or vhost $tgt_vhost)"

    # If a stale vhost is here from a previous (wrong-type) clone, surface it
    # — it's the most common cause of the "detected as moodle but served as
    # static" report.
    if [[ -f "$tgt_vhost" ]]; then
        stale_type=""
        if grep -q 'fastcgi_pass' "$tgt_vhost" 2>/dev/null; then
            if grep -q 'moodledata\|pluginfile' "$tgt_vhost" 2>/dev/null; then
                stale_type="moodle"
            elif grep -q 'wp-config\|wp-content' "$tgt_vhost" 2>/dev/null; then
                stale_type="wordpress"
            else
                stale_type="laravel"
            fi
        elif grep -q 'proxy_pass.*127\.0\.0\.1' "$tgt_vhost" 2>/dev/null; then
            stale_type="nuxt"
        elif grep -q 'try_files.*index\.html' "$tgt_vhost" 2>/dev/null; then
            stale_type="vue"
        else
            stale_type="static"
        fi
        if [[ -n "$stale_type" && "$stale_type" != "$src_type" ]]; then
            sre_warning "Existing vhost looks like type '$stale_type' but source is '$src_type'."
            sre_warning "This is probably a stale vhost from an earlier broken clone."
            sre_warning "The new clone will regenerate it as a proper $src_type vhost."
        fi
    fi

    if [[ "$SRE_FORCE" == "true" ]]; then
        sre_warning "--force set: proceeding with destructive overwrite."
    elif ! prompt_yesno "Overwrite the existing target? (DESTRUCTIVE)" "no"; then
        sre_skipped "Clone cancelled — target exists. Pass --force to overwrite non-interactively."
        exit 4
    fi
fi

# Mirror source paths into target. For Moodle the source layout can vary
# (public_html, no subdir, current/, etc) — mirror what the source actually
# uses so target file paths line up with the rsync result.
case "$src_type" in
    laravel)   tgt_doc_root="${tgt_proj_base}/current/public" ;;
    moodle)
        if [[ "$src_doc_root" == "${src_proj_base}/"* ]]; then
            tgt_doc_root="${tgt_proj_base}/${src_doc_root#${src_proj_base}/}"
        else
            tgt_doc_root="${tgt_proj_base}/public_html"
        fi
        ;;
    wordpress) tgt_doc_root="${tgt_proj_base}/current" ;;
    nuxt)      tgt_doc_root="${tgt_proj_base}/current" ;;
    vue)       tgt_doc_root="${tgt_proj_base}/current/dist" ;;
    static)    tgt_doc_root="${tgt_proj_base}/current" ;;
esac

# Compute the target Moodle config.php path mirroring source layout
tgt_moodle_config=""
if [[ "$src_type" == "moodle" && -n "$src_moodle_config" ]]; then
    if [[ "$src_moodle_config" == "${src_proj_base}/"* ]]; then
        tgt_moodle_config="${tgt_proj_base}/${src_moodle_config#${src_proj_base}/}"
    else
        tgt_moodle_config="${tgt_doc_root}/config.php"
    fi
fi

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
                # `|| true` on every grep so a missing key returns empty
                # instead of tripping pipefail+set-e.
                # Strip surrounding quotes (matched pair) AND any stray quote
                # chars left over from malformed .env files. Also strip an
                # inline `# comment` and trailing whitespace/CR (from CRLF
                # endings on files edited on Windows). A stray quote in a DB
                # name causes mysql to fail with the unhelpful
                # "Incorrect database name 'foo\"'" error mid-pipe.
                _env_clean() {
                    sed -E '
                        s/[[:space:]]+#.*$//;       # strip inline comments
                        s/^"(.*)"[[:space:]]*$/\1/; # strip matched double-quote pair
                        s/^'\''(.*)'\''[[:space:]]*$/\1/; # strip matched single-quote pair
                        s/[\"'\''[:space:]]+$//;    # strip trailing stray quotes/whitespace
                        s/^[\"'\''[:space:]]+//;    # strip leading stray quotes/whitespace
                        s/\r$//                     # strip CR from CRLF files
                    '
                }
                src_db_name=$( { grep -m1 '^DB_DATABASE=' "$envf" || true; } | cut -d= -f2- | _env_clean)
                src_db_user=$( { grep -m1 '^DB_USERNAME=' "$envf" || true; } | cut -d= -f2- | _env_clean)
                src_db_pass=$( { grep -m1 '^DB_PASSWORD=' "$envf" || true; } | cut -d= -f2- | _env_clean)
                conn=$( { grep -m1 '^DB_CONNECTION=' "$envf" || true; } | cut -d= -f2- | _env_clean)
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
                src_db_name=$( { grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" || true; } | head -1)
                src_db_user=$( { grep -oP "define\(\s*['\"]DB_USER['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" || true; } | head -1)
                src_db_pass=$( { grep -oP "define\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]?\K[^'\")]+" "$wpc" || true; } | head -1)
                src_db_engine="mariadb"   # WP is mysql/mariadb
                pf=$( { grep -oP "^\s*\\\$table_prefix\s*=\s*['\"]?\K[^'\"]+" "$wpc" || true; } | head -1)
                wp_prefix="${pf:-wp_}"
            fi
            ;;
        moodle)
            # Use the config.php path discovered during type-detection if we
            # have it; fall back to doc_root.
            mcf="${src_moodle_config:-${src_doc_root}/config.php}"
            if [[ -f "$mcf" ]]; then
                src_db_name=$( { grep -oP "\\\$CFG->dbname\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" || true; } | head -1)
                src_db_user=$( { grep -oP "\\\$CFG->dbuser\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" || true; } | head -1)
                src_db_pass=$( { grep -oP "\\\$CFG->dbpass\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" || true; } | head -1)
                pf=$( { grep -oP "\\\$CFG->prefix\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" || true; } | head -1)
                moodle_prefix="${pf:-mdl_}"
                dbt=$( { grep -oP "\\\$CFG->dbtype\s*=\s*['\"]?\K[^'\";\s]+" "$mcf" || true; } | head -1)
                case "$dbt" in
                    mariadb|mysqli|mysql) src_db_engine="mariadb" ;;
                    pgsql)                src_db_engine="postgresql" ;;
                    *)                    src_db_engine="mariadb" ;;
                esac
            else
                sre_warning "Moodle config.php not found at $mcf — DB creds will be prompted."
            fi
            ;;
    esac

    if [[ -z "$src_db_name" ]]; then
        sre_warning "Could not auto-detect source DB credentials."
        src_db_name=$(prompt_input "Source DB name" "")
        src_db_user=$(prompt_input "Source DB user" "")
        src_db_pass=$(prompt_input "Source DB password" "")
    fi

    # Engine fallback runs INDEPENDENTLY of the name guard above. The detection
    # branches above may populate src_db_name from .env / config.php but leave
    # src_db_engine empty (e.g. Laravel with DB_CONNECTION=sqlite, or src_type
    # of static/nuxt/vue/unknown that has no detection branch). Without this
    # the script would later hit the "Unsupported source DB engine:" trap.
    if [[ -z "$src_db_engine" ]]; then
        if [[ "$SRE_YES" == "true" ]]; then
            sre_warning "Source DB engine could not be detected; defaulting to mariadb (--yes mode)."
            src_db_engine="mariadb"
        else
            src_db_engine=$(prompt_choice "Source DB engine:" "mariadb" "mysql" "postgresql")
        fi
    fi

    sre_info "Source DB:     ${src_db_name} (${src_db_engine})"
fi

################################################################################
# Build mysql_cmd / mysqldump_cmd ONCE up front (not inside the DB phase).
#
# The CONFIG and other later phases need to talk to MySQL too (Moodle DB
# wwwroot update, WP search-replace, etc.). On a resume where the DB phase
# was already marked done, those references would otherwise hit an unset
# variable and trip set -u.
################################################################################

mysql_cmd="mysql"
mysqldump_cmd="mysqldump"
db_root_pass="${db_root_pass:-}"
if [[ -z "$db_root_pass" && -f /root/.db_root_password ]]; then
    db_root_pass=$(cat /root/.db_root_password)
fi
if [[ -n "$db_root_pass" ]]; then
    mysql_cmd="mysql -u root -p${db_root_pass}"
    mysqldump_cmd="mysqldump -u root -p${db_root_pass}"
fi

################################################################################
# Target DB plan
#
# CRITICAL: generated values are persisted to $CLONE_PROGRESS the moment they
# exist. On resume we reload them instead of regenerating — otherwise a
# resumed run would create a SECOND DB with new credentials while the
# already-written .env / config.php point at the FIRST DB.
################################################################################

if [[ "$CLONE_RESUMING" == "yes" ]] && [[ -n "${tgt_db_name:-}" && -n "${tgt_db_user:-}" && -n "${tgt_db_pass:-}" ]]; then
    sre_info "Resuming with persisted target DB creds: $tgt_db_name / $tgt_db_user"
    # ts is informational only after this point; keep whatever was persisted
    ts="${ts:-$(date +%y%m%d%H%M)}"
else
    # Build a new DB name + user (truncate at 32 chars for mysql limits)
    ts=$(date +%y%m%d%H%M)
    _san() { echo "$1" | tr '.-' '_' | tr '[:upper:]' '[:lower:]'; }
    tgt_db_base="$(_san "${CL_TARGET_DOMAIN%%.*}")"
    tgt_db_name="${tgt_db_base}_clone_${ts}"
    tgt_db_name="${tgt_db_name:0:60}"
    tgt_db_user="${tgt_db_base}_c${ts: -6}"
    tgt_db_user="${tgt_db_user:0:32}"
    tgt_db_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

    ############################################################################
    # Prompt for DB name + user (only if --do_db). Auto-generated values are
    # shown as defaults — press Enter to accept.
    #
    # Skipped when SRE_YES=true AND SRE_FORCE=true (matches the script's
    # established "non-interactive override" rule).
    ############################################################################

    _db_name_ok() {
        local v="$1"
        [[ -n "$v" && ${#v} -le 64 && "$v" =~ ^[a-zA-Z0-9_]+$ ]]
    }
    _db_user_ok() {
        local v="$1"
        [[ -n "$v" && ${#v} -le 32 && "$v" =~ ^[a-zA-Z0-9_]+$ ]]
    }
    _mysql_has_db() {
        local v="$1"
        $mysql_cmd -N -B -e \
            "SELECT 1 FROM information_schema.schemata WHERE schema_name='${v}' LIMIT 1;" 2>/dev/null \
            | grep -q '^1$'
    }
    _mysql_has_user() {
        local v="$1"
        $mysql_cmd -N -B -e \
            "SELECT 1 FROM mysql.user WHERE user='${v}' AND host='localhost' LIMIT 1;" 2>/dev/null \
            | grep -q '^1$'
    }

    _skip_db_prompts="no"
    if [[ "$do_db" != "true" ]]; then
        _skip_db_prompts="yes"
    elif [[ "$SRE_YES" == "true" && "$SRE_FORCE" == "true" ]]; then
        _skip_db_prompts="yes"
    fi

    if [[ "$_skip_db_prompts" == "no" ]]; then
        sre_header "Target Database Credentials"
        sre_info "Press Enter to accept the auto-generated value, or type your own."

        # --- DB name ---
        while true; do
            _user_db_name=$(prompt_input "Target DB name" "$tgt_db_name")
            if ! _db_name_ok "$_user_db_name"; then
                sre_warning "Invalid DB name. Must be 1-64 chars, [a-zA-Z0-9_] only."
                continue
            fi
            if _mysql_has_db "$_user_db_name"; then
                # Allow if it's the auto-generated value (which is timestamp+random,
                # so a collision means a leftover from this same script — safe to
                # reuse). Reject anything else to avoid clobbering an unrelated DB.
                if [[ "$_user_db_name" == "$tgt_db_name" ]]; then
                    sre_warning "DB '$_user_db_name' already exists — will DROP and recreate (auto-generated name, safe)."
                    break
                fi
                sre_warning "DB '$_user_db_name' already exists in MySQL — refusing to clobber it."
                sre_warning "Pick a different name, or drop the existing DB manually first:"
                sre_warning "  mysql -u root -e \"DROP DATABASE \\\`${_user_db_name}\\\`;\""
                continue
            fi
            tgt_db_name="$_user_db_name"
            break
        done

        # --- DB user ---
        while true; do
            _user_db_user=$(prompt_input "Target DB user" "$tgt_db_user")
            if ! _db_user_ok "$_user_db_user"; then
                sre_warning "Invalid DB user. Must be 1-32 chars, [a-zA-Z0-9_] only."
                continue
            fi
            if _mysql_has_user "$_user_db_user"; then
                if [[ "$_user_db_user" == "$tgt_db_user" ]]; then
                    sre_warning "User '$_user_db_user'@'localhost' already exists — will ALTER its password (auto-generated name, safe)."
                    break
                fi
                sre_warning "User '$_user_db_user'@'localhost' already exists in MySQL — refusing to overwrite its password."
                sre_warning "Pick a different name, or drop the existing user manually first:"
                sre_warning "  mysql -u root -e \"DROP USER '${_user_db_user}'@'localhost';\""
                continue
            fi
            tgt_db_user="$_user_db_user"
            break
        done

        sre_success "Will use: DB=${tgt_db_name}, user=${tgt_db_user}"
    fi

    # Persist immediately so an interrupt before the DB phase still preserves
    # the names/credentials for a clean resume.
    progress_set "CL_SOURCE_DOMAIN" "$CL_SOURCE_DOMAIN"
    progress_set "CL_TARGET_DOMAIN" "$CL_TARGET_DOMAIN"
    progress_set "ts"               "$ts"
    progress_set "tgt_db_name"      "$tgt_db_name"
    progress_set "tgt_db_user"      "$tgt_db_user"
    progress_set "tgt_db_pass"      "$tgt_db_pass"
    progress_set "src_type"         "$src_type"
    progress_set "tgt_doc_root"     "$tgt_doc_root"
    progress_set "CL_TGT_SCHEME"    "$CL_TGT_SCHEME"
    progress_set "CL_PURPOSE"       "$CL_PURPOSE"
fi

if [[ "$do_db" == "true" ]]; then
    sre_info "Target DB:     ${tgt_db_name}"
    sre_info "Target DB user:${tgt_db_user}"
fi

################################################################################
# Summary + confirm
################################################################################

sre_header "Clone Plan"
sre_info "  Purpose:       $CL_PURPOSE"
sre_info "  Source domain: $CL_SOURCE_DOMAIN"
sre_info "  Target domain: $CL_TARGET_DOMAIN"
sre_info "  Target scheme: $CL_TGT_SCHEME"
sre_info "  Type:          $src_type"
sre_info "  Mode:          $CL_MODE"
if [[ "$do_files" == "true" ]]; then
    sre_info "  Files: $src_proj_base  →  $tgt_proj_base"
fi
if [[ "$do_db" == "true" ]]; then
    sre_info "  DB:    $src_db_name  →  $tgt_db_name"
fi

if [[ "$CL_PROTECT" == "yes" ]] && [[ "$CL_NOINDEX" == "yes" || "$CL_HTPASSWD" == "yes" ]]; then
    protect_bits=()
    [[ "$CL_NOINDEX"  == "yes" ]] && protect_bits+=("noindex")
    [[ "$CL_HTPASSWD" == "yes" ]] && protect_bits+=("htpasswd")
    [[ ${#CL_ALLOW_IPS[@]} -gt 0 ]] && protect_bits+=("allow:${CL_ALLOW_IPS[*]}")
    sre_info "  Protect: ${protect_bits[*]}"
else
    sre_warning "  Protect: DISABLED — clone will be publicly reachable"
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
# Phase counter for progress display
################################################################################

CLONE_TOTAL_PHASES=7   # files, db, config, vhost, ssl, protect, perms
CLONE_PHASE_NUM=0

phase_header() {
    local label="$1"
    CLONE_PHASE_NUM=$((CLONE_PHASE_NUM + 1))
    sre_header "[${CLONE_PHASE_NUM}/${CLONE_TOTAL_PHASES}] ${label}"
}

phase_skipped() {
    local label="$1"
    CLONE_PHASE_NUM=$((CLONE_PHASE_NUM + 1))
    sre_info "[${CLONE_PHASE_NUM}/${CLONE_TOTAL_PHASES}] ${label} — already done, skipping"
}

################################################################################
# COPY FILES
#
# rsync is idempotent: re-running skips already-transferred files.
# --partial keeps a partially-transferred file's bytes on disk and resumes
# from that offset on the next run (instead of restarting from zero).
# So this whole phase is safe to re-run unconditionally — we still mark it
# done so resumes that get past it can skip the (still-fast) re-traversal.
################################################################################

if [[ "$do_files" == "true" ]] && ! progress_phase_done FILES; then
    phase_header "Copying Files"

    mkdir -p "$tgt_proj_base"

    case "$src_type" in
        laravel)
            # Source uses release-based layout: copy releases/* + shared, rebuild current symlink
            mkdir -p "${tgt_proj_base}/shared"

            # Resolve actual source files (current -> releases/X)
            src_release_actual=$(readlink -f "${src_proj_base}/current" 2>/dev/null || echo "${src_proj_base}/current")
            # Reuse the same target release dir across resumes (persisted)
            if [[ -z "${tgt_release_dir:-}" || ! -d "${tgt_release_dir:-/nonexistent}" ]]; then
                tgt_release_dir="${tgt_proj_base}/releases/$(date +%Y%m%d%H%M%S)"
                progress_set "tgt_release_dir" "$tgt_release_dir"
            fi
            mkdir -p "$tgt_release_dir"
            sre_info "Copying release content: ${src_release_actual}/ → ${tgt_release_dir}/"
            rsync -aH --partial --info=progress2 "${src_release_actual}/" "${tgt_release_dir}/"

            # Copy shared (mostly .env + storage)
            if [[ -d "${src_proj_base}/shared" ]]; then
                sre_info "Copying shared/ → ${tgt_proj_base}/shared/"
                rsync -aH --partial "${src_proj_base}/shared/" "${tgt_proj_base}/shared/"
            fi

            # current symlink
            ln -sfn "$tgt_release_dir" "${tgt_proj_base}/current"
            sre_success "Laravel release copied + symlinked"
            ;;

        moodle)
            sre_info "Copying ${src_proj_base}/ → ${tgt_proj_base}/ (excluding moodledata)"
            # Don't copy moodledata directly — find its actual location from config
            mdldata=""
            mcf_for_dataroot="${src_moodle_config:-${src_doc_root}/config.php}"
            if [[ -f "$mcf_for_dataroot" ]]; then
                mdldata=$( { grep -oP "\\\$CFG->dataroot\s*=\s*['\"]?\K[^'\";\s]+" "$mcf_for_dataroot" || true; } | head -1)
            fi
            # Fall back to well-known locations if config.php was unreadable
            [[ -z "$mdldata" && -d "${src_proj_base}/moodledata" ]] && mdldata="${src_proj_base}/moodledata"
            [[ -z "$mdldata" && -d "/u02/appdata/${CL_SOURCE_DOMAIN}/moodledata" ]] && mdldata="/u02/appdata/${CL_SOURCE_DOMAIN}/moodledata"
            rsync_excludes=()
            if [[ -n "$mdldata" && "$mdldata" == "${src_proj_base}/"* ]]; then
                rel_mdldata="${mdldata#${src_proj_base}/}"
                rsync_excludes+=("--exclude=${rel_mdldata}")
                sre_info "Excluding internal moodledata: $rel_mdldata"
            fi
            rsync -aH --partial --info=progress2 "${rsync_excludes[@]}" "${src_proj_base}/" "${tgt_proj_base}/"

            # Copy moodledata separately (it can be huge — ask)
            tgt_mdldata="${tgt_proj_base}/moodledata"
            if findmnt -n "/u02/appdata" &>/dev/null; then
                tgt_mdldata="/u02/appdata/${CL_TARGET_DOMAIN}/moodledata"
            fi
            if [[ -n "$mdldata" && -d "$mdldata" ]]; then
                if prompt_yesno "Copy moodledata ($(du -sh "$mdldata" 2>/dev/null | cut -f1)) to ${tgt_mdldata}?" "yes"; then
                    mkdir -p "$tgt_mdldata"
                    rsync -aH --partial --info=progress2 "${mdldata}/" "${tgt_mdldata}/"
                    sre_success "Moodledata copied"
                else
                    mkdir -p "$tgt_mdldata"
                    sre_warning "Empty moodledata at $tgt_mdldata — clone will not have user files"
                fi
            else
                mkdir -p "$tgt_mdldata"
            fi
            # Stash for later config rewrite — persist for resume
            CL_TGT_MOODLEDATA="$tgt_mdldata"
            progress_set "CL_TGT_MOODLEDATA" "$CL_TGT_MOODLEDATA"
            progress_set "mdldata"           "${mdldata:-}"
            ;;

        wordpress|nuxt|vue|static)
            # Same release layout as deploy/migrate scripts when available
            if [[ -d "${src_proj_base}/current" && ! -L "${src_proj_base}/current" ]]; then
                # Edge case: current is a real dir not a symlink — copy as-is
                sre_info "Copying ${src_proj_base}/ → ${tgt_proj_base}/ (flat layout)"
                rsync -aH --partial --info=progress2 "${src_proj_base}/" "${tgt_proj_base}/"
            elif [[ -L "${src_proj_base}/current" ]]; then
                src_release_actual=$(readlink -f "${src_proj_base}/current")
                if [[ -z "${tgt_release_dir:-}" || ! -d "${tgt_release_dir:-/nonexistent}" ]]; then
                    tgt_release_dir="${tgt_proj_base}/releases/$(date +%Y%m%d%H%M%S)"
                    progress_set "tgt_release_dir" "$tgt_release_dir"
                fi
                mkdir -p "$tgt_release_dir"
                sre_info "Copying ${src_release_actual}/ → ${tgt_release_dir}/"
                rsync -aH --partial --info=progress2 "${src_release_actual}/" "${tgt_release_dir}/"
                ln -sfn "$tgt_release_dir" "${tgt_proj_base}/current"
            else
                # No release layout — copy doc_root contents
                mkdir -p "${tgt_proj_base}/current"
                sre_info "Copying ${src_doc_root}/ → ${tgt_proj_base}/current/"
                rsync -aH --partial --info=progress2 "${src_doc_root}/" "${tgt_proj_base}/current/"
            fi
            ;;
    esac

    chown -R www-data:www-data "$tgt_proj_base"
    sre_success "Files copied to $tgt_proj_base"

    # Persist the moodledata path so resume can rewrite config.php correctly
    [[ -n "${CL_TGT_MOODLEDATA:-}" ]] && progress_set "CL_TGT_MOODLEDATA" "$CL_TGT_MOODLEDATA"

    progress_mark_phase FILES
elif [[ "$do_files" == "true" ]]; then
    phase_skipped "Copying Files"
fi

################################################################################
# COPY DATABASE
#
# Not mid-stream resumable: mysqldump|mysql doesn't have an offset. On resume
# we DROP DATABASE first (the name is timestamp+random so it can't collide
# with anything real), recreate, and re-import. Atomic per-phase: marked
# done only after import returns 0.
################################################################################

if [[ "$do_db" == "true" ]] && ! progress_phase_done DB; then
    phase_header "Copying Database"

    # mysql_cmd / mysqldump_cmd / db_root_pass are already hoisted up top so
    # later phases can use them on resume. Nothing to (re-)set here.

    ############################################################################
    # Resolve table-skip plan
    #
    # Inputs: CL_SKIP_INPUT (from --skip-table[s]), CL_SKIP_TABLES_FILE.
    # Outputs (de-duped, validated against source DB):
    #   CL_SKIP_SCHEMA_ONLY[]  → dump CREATE TABLE only, drop rows
    #   CL_SKIP_FULL[]         → no CREATE, no rows
    ############################################################################

    # Validate --skip-mode
    case "$CL_SKIP_MODE" in
        ask|schema-only|skip-entirely) ;;
        *) sre_error "Invalid --skip-mode: $CL_SKIP_MODE (expected: ask | schema-only | skip-entirely)"; exit 1 ;;
    esac

    # On resume, prefer the persisted plan over re-prompting. CL_SKIP_SCHEMA_ONLY
    # and CL_SKIP_FULL are written as space-joined strings via `progress_set`
    # earlier in this same phase; on resume they came back into the env via
    # `source $CLONE_PROGRESS` at startup. Split them back into arrays.
    if [[ "$CLONE_RESUMING" == "yes" ]]; then
        # Detect the case where we have persisted plan data (string form) but
        # current-shell arrays are empty.
        if [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -eq 0 ]] && [[ -n "${CL_SKIP_SCHEMA_ONLY_STR:-}" ]]; then
            read -ra CL_SKIP_SCHEMA_ONLY <<<"$CL_SKIP_SCHEMA_ONLY_STR"
        fi
        if [[ ${#CL_SKIP_FULL[@]} -eq 0 ]] && [[ -n "${CL_SKIP_FULL_STR:-}" ]]; then
            read -ra CL_SKIP_FULL <<<"$CL_SKIP_FULL_STR"
        fi
        if [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 || ${#CL_SKIP_FULL[@]} -gt 0 ]]; then
            sre_info "Resuming with persisted skip plan:"
            [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 ]] && sre_info "  schema-only: ${CL_SKIP_SCHEMA_ONLY[*]}"
            [[ ${#CL_SKIP_FULL[@]} -gt 0 ]] && sre_info "  skip-entirely: ${CL_SKIP_FULL[*]}"
            # Mark "already resolved" so the per-table prompt block skips
            CL_SKIP_INPUT=()
        fi
    fi

    # Load tables from file
    if [[ -n "$CL_SKIP_TABLES_FILE" ]]; then
        if [[ ! -r "$CL_SKIP_TABLES_FILE" ]]; then
            sre_error "Cannot read --skip-tables-file: $CL_SKIP_TABLES_FILE"
            exit 1
        fi
        while IFS= read -r _line; do
            _line="${_line%%#*}"            # strip comments
            _line="${_line//$'\t'/}"
            _line="${_line//$'\r'/}"
            _line="${_line// /}"
            [[ -z "$_line" ]] && continue
            CL_SKIP_INPUT+=("$_line")
        done <"$CL_SKIP_TABLES_FILE"
    fi

    # De-duplicate input
    if [[ ${#CL_SKIP_INPUT[@]} -gt 0 ]]; then
        declare -A _seen_assoc=()
        _dedup=()
        for _t in "${CL_SKIP_INPUT[@]}"; do
            [[ -z "$_t" ]] && continue
            if [[ -z "${_seen_assoc[$_t]:-}" ]]; then
                _seen_assoc[$_t]=1
                _dedup+=("$_t")
            fi
        done
        CL_SKIP_INPUT=("${_dedup[@]}")
        unset _seen_assoc _dedup
    fi

    if [[ ${#CL_SKIP_INPUT[@]} -gt 0 ]]; then
        sre_info "Skip-table input (${#CL_SKIP_INPUT[@]}): ${CL_SKIP_INPUT[*]}"
        sre_info "Skip mode: $CL_SKIP_MODE"
    fi

    case "$src_db_engine" in
        mariadb|mysql)
            # mysql_cmd / mysqldump_cmd were hoisted earlier (so CONFIG phase
            # on resume can use them too). No re-setup needed here.

            ####################################################################
            # --pick-tables : interactive size-sorted picker
            #
            # Queries information_schema for the source DB's tables ordered by
            # size, shows them with human-readable sizes, prompts to mark which
            # to skip and what mode to use. Names selected here get appended to
            # CL_SKIP_INPUT and flow through the normal mode-resolution path.
            ####################################################################
            if [[ "$CL_PICK_TABLES" == "yes" ]]; then
                sre_header "Interactive table picker"
                sre_info "Querying source DB sizes..."

                # Pull NAME, BYTES, ROWS for all base tables, largest first
                _tbl_data=$($mysql_cmd -N -B -e "
                    SELECT
                        table_name,
                        COALESCE(data_length + index_length, 0) AS bytes,
                        COALESCE(table_rows, 0) AS rows_est
                    FROM information_schema.tables
                    WHERE table_schema = '${src_db_name}'
                      AND table_type = 'BASE TABLE'
                    ORDER BY bytes DESC;
                " 2>/dev/null)

                if [[ -z "$_tbl_data" ]]; then
                    sre_warning "Could not list tables in ${src_db_name} — skipping picker."
                else
                    # Convert into parallel arrays
                    _pick_names=()
                    _pick_bytes=()
                    _pick_rows=()
                    while IFS=$'\t' read -r _n _b _r; do
                        [[ -z "$_n" ]] && continue
                        _pick_names+=("$_n")
                        _pick_bytes+=("$_b")
                        _pick_rows+=("$_r")
                    done <<<"$_tbl_data"

                    sre_info "Source tables (largest first):"
                    printf '\n  %3s  %-50s  %10s  %12s\n' '#' 'Table' 'Size' 'Rows' >&2
                    printf '  %3s  %-50s  %10s  %12s\n' '---' '-----' '----' '----' >&2
                    for _i in "${!_pick_names[@]}"; do
                        _hsize=$(numfmt --to=iec --suffix=B "${_pick_bytes[$_i]}" 2>/dev/null || echo "${_pick_bytes[$_i]}B")
                        printf '  %3d  %-50s  %10s  %12s\n' \
                            $((_i + 1)) "${_pick_names[$_i]}" "$_hsize" "${_pick_rows[$_i]}" >&2
                    done
                    echo "" >&2

                    sre_info "Enter table NUMBERS to skip, comma-separated (e.g. 1,3,5)."
                    sre_info "Or enter ranges like 1-5,8. Empty input = skip nothing."
                    read -r -p "Tables to skip: " _pick_choice
                    _pick_choice="${_pick_choice// /}"

                    if [[ -n "$_pick_choice" ]]; then
                        # Expand ranges
                        _picked_idx=()
                        IFS=',' read -ra _parts <<<"$_pick_choice"
                        for _part in "${_parts[@]}"; do
                            if [[ "$_part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                                _from=${BASH_REMATCH[1]}
                                _to=${BASH_REMATCH[2]}
                                for _j in $(seq "$_from" "$_to"); do _picked_idx+=("$_j"); done
                            elif [[ "$_part" =~ ^[0-9]+$ ]]; then
                                _picked_idx+=("$_part")
                            else
                                sre_warning "Ignoring invalid token: $_part"
                            fi
                        done

                        # Per-selected-table: ask schema-only vs skip-entirely
                        # (use --skip-mode if it's set to a non-ask value, else ask)
                        for _idx in "${_picked_idx[@]}"; do
                            if (( _idx < 1 || _idx > ${#_pick_names[@]} )); then
                                sre_warning "Out of range: $_idx"
                                continue
                            fi
                            _name="${_pick_names[$((_idx - 1))]}"
                            _hsize=$(numfmt --to=iec --suffix=B "${_pick_bytes[$((_idx - 1))]}" 2>/dev/null || echo "?")

                            case "$CL_SKIP_MODE" in
                                schema-only)   CL_SKIP_SCHEMA_ONLY+=("$_name") ; sre_info "  $_name ($_hsize) → schema-only" ;;
                                skip-entirely) CL_SKIP_FULL+=("$_name")        ; sre_info "  $_name ($_hsize) → skip-entirely" ;;
                                ask)
                                    _mode=$(prompt_choice "How to skip '$_name' ($_hsize)?" \
                                        "schema-only (keep CREATE TABLE, drop rows)" \
                                        "skip-entirely (no CREATE, no rows)" \
                                        "cancel (don't skip this one)")
                                    case "$_mode" in
                                        schema-only*)   CL_SKIP_SCHEMA_ONLY+=("$_name") ;;
                                        skip-entirely*) CL_SKIP_FULL+=("$_name") ;;
                                        cancel*)        sre_info "  $_name: not skipping" ;;
                                    esac
                                    ;;
                            esac
                        done

                        # Set mode to a non-ask sentinel so the later resolution
                        # loop doesn't double-prompt for these
                        if [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 || ${#CL_SKIP_FULL[@]} -gt 0 ]]; then
                            sre_success "Picked $((${#CL_SKIP_SCHEMA_ONLY[@]} + ${#CL_SKIP_FULL[@]})) table(s) to skip"
                        fi
                    else
                        sre_info "No tables picked — proceeding with full clone."
                    fi
                fi
            fi

            # Validate user-supplied tables against the source DB; warn (don't
            # fail) on unknowns — user may have typoed, but mysqldump --ignore-table
            # on a missing name is harmless.
            if [[ ${#CL_SKIP_INPUT[@]} -gt 0 ]]; then
                _src_tables=$($mysql_cmd -N -B -e \
                    "SELECT table_name FROM information_schema.tables WHERE table_schema='${src_db_name}' AND table_type='BASE TABLE';" 2>/dev/null)
                if [[ -n "$_src_tables" ]]; then
                    _missing=()
                    for _t in "${CL_SKIP_INPUT[@]}"; do
                        if ! grep -qx -- "$_t" <<<"$_src_tables"; then
                            _missing+=("$_t")
                        fi
                    done
                    if [[ ${#_missing[@]} -gt 0 ]]; then
                        sre_warning "These skip-table entries don't exist in ${src_db_name}: ${_missing[*]}"
                        sre_warning "(They'll be passed to mysqldump anyway; will be no-ops.)"
                    fi
                fi
            fi

            # Per-table mode resolution
            for _t in "${CL_SKIP_INPUT[@]}"; do
                case "$CL_SKIP_MODE" in
                    schema-only)   CL_SKIP_SCHEMA_ONLY+=("$_t") ;;
                    skip-entirely) CL_SKIP_FULL+=("$_t") ;;
                    ask)
                        _decision=$(prompt_choice "Skip table '$_t' — how?" \
                            "schema-only (keep CREATE TABLE, drop rows)" \
                            "skip-entirely (no CREATE, no rows)" \
                            "include (don't skip)")
                        case "$_decision" in
                            schema-only*)   CL_SKIP_SCHEMA_ONLY+=("$_t") ;;
                            skip-entirely*) CL_SKIP_FULL+=("$_t") ;;
                            include*)       sre_info "  including '$_t' (no skip)" ;;
                        esac
                        ;;
                esac
            done

            # Persist for resume
            progress_set "CL_SKIP_SCHEMA_ONLY_STR" "${CL_SKIP_SCHEMA_ONLY[*]:-}"
            progress_set "CL_SKIP_FULL_STR"        "${CL_SKIP_FULL[*]:-}"

            if [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 ]]; then
                sre_info "Will dump schema only (no rows) for: ${CL_SKIP_SCHEMA_ONLY[*]}"
            fi
            if [[ ${#CL_SKIP_FULL[@]} -gt 0 ]]; then
                sre_info "Will skip entirely (no CREATE, no rows): ${CL_SKIP_FULL[*]}"
            fi

            # On resume, DROP first so we don't get duplicate-key errors from
            # a half-imported DB. Target name is timestamp+random — can't
            # collide with anything real.
            if $mysql_cmd -e "SHOW DATABASES LIKE '${tgt_db_name}';" 2>/dev/null | grep -q "$tgt_db_name"; then
                sre_warning "Target DB ${tgt_db_name} already exists — dropping for clean re-import"
                $mysql_cmd -e "DROP DATABASE \`${tgt_db_name}\`;" 2>/dev/null || true
            fi

            # Create target DB + user (idempotent)
            $mysql_cmd -e "CREATE DATABASE \`${tgt_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
                || { sre_error "Failed creating database ${tgt_db_name}"; exit 1; }
            $mysql_cmd -e "CREATE USER IF NOT EXISTS '${tgt_db_user}'@'localhost' IDENTIFIED BY '${tgt_db_pass}';" 2>/dev/null
            $mysql_cmd -e "ALTER USER '${tgt_db_user}'@'localhost' IDENTIFIED BY '${tgt_db_pass}';" 2>/dev/null
            $mysql_cmd -e "GRANT ALL PRIVILEGES ON \`${tgt_db_name}\`.* TO '${tgt_db_user}'@'localhost';" 2>/dev/null
            $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null
            sre_success "Target DB + user created: ${tgt_db_name} / ${tgt_db_user}"

            # Estimate source DB size for the live progress meter
            src_db_bytes=$($mysql_cmd -N -B -e \
                "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema='${src_db_name}';" 2>/dev/null || echo 0)
            if [[ "$src_db_bytes" =~ ^[0-9]+$ ]] && [[ "$src_db_bytes" -gt 0 ]]; then
                sre_info "Source DB size (approx): $(numfmt --to=iec --suffix=B $src_db_bytes 2>/dev/null || echo "${src_db_bytes}B")"
            fi

            # Build dump arg vector. --ignore-table applies to BOTH skip lists
            # during the main dump (no rows, no CREATE). For schema-only tables
            # we then run a SECOND dump with --no-data so the CREATE TABLEs are
            # restored but rows stay out.
            _dump_base=( --single-transaction --quick --routines --triggers )
            _dump_ignore=()
            for _t in "${CL_SKIP_SCHEMA_ONLY[@]}" "${CL_SKIP_FULL[@]}"; do
                _dump_ignore+=( "--ignore-table=${src_db_name}.${_t}" )
            done

            # Preflight: verify source DB actually exists. Catches the common
            # failure mode where .env was edited badly and src_db_name has
            # stray quotes / wrong case — would otherwise fail mid-pipe with
            # an unreadable jumbled error.
            if ! $mysql_cmd -N -B -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name='${src_db_name}' LIMIT 1;" 2>/dev/null | grep -q .; then
                sre_error "Source DB '${src_db_name}' does not exist (or root can't see it)."
                sre_error "Check the source project's config — DB name may have stray quotes."
                sre_error "Available DBs:"
                $mysql_cmd -N -B -e "SHOW DATABASES;" 2>/dev/null | sed 's/^/    /' | head -30
                exit 1
            fi

            # Dump source → import target. If pv is installed, pipe through
            # it for a live progress meter. We check PIPESTATUS afterwards
            # because mysql happily eats malformed input and exits 0, so
            # set -o pipefail alone doesn't catch a failed mysqldump.
            sre_info "Dumping ${src_db_name} → importing into ${tgt_db_name}..."

            # Stream stderr to a tempfile so we can show it on failure.
            _dump_err=$(mktemp)
            _import_err=$(mktemp)
            # shellcheck disable=SC2064
            trap "rm -f '$_dump_err' '$_import_err'" RETURN

            set +e
            if command -v pv &>/dev/null; then
                if [[ "$src_db_bytes" -gt 0 ]]; then
                    $mysqldump_cmd "${_dump_base[@]}" "${_dump_ignore[@]}" \
                        "$src_db_name" 2>"$_dump_err" \
                        | pv -s "$src_db_bytes" -N "DB stream" \
                        | $mysql_cmd "$tgt_db_name" 2>"$_import_err"
                else
                    $mysqldump_cmd "${_dump_base[@]}" "${_dump_ignore[@]}" \
                        "$src_db_name" 2>"$_dump_err" \
                        | pv -N "DB stream" \
                        | $mysql_cmd "$tgt_db_name" 2>"$_import_err"
                fi
                # Snapshot PIPESTATUS into a local array in ONE expansion.
                # Subsequent assignments reset PIPESTATUS, so reading
                # PIPESTATUS[1] after `_dump_rc="${PIPESTATUS[0]}"` would
                # be an unbound-array-index under set -u.
                _ps=( "${PIPESTATUS[@]}" )
                _dump_rc="${_ps[0]:-0}"
                _pv_rc="${_ps[1]:-0}"
                _import_rc="${_ps[2]:-0}"
            else
                $mysqldump_cmd "${_dump_base[@]}" "${_dump_ignore[@]}" \
                    "$src_db_name" 2>"$_dump_err" \
                    | $mysql_cmd "$tgt_db_name" 2>"$_import_err"
                _ps=( "${PIPESTATUS[@]}" )
                _dump_rc="${_ps[0]:-0}"
                _pv_rc=0
                _import_rc="${_ps[1]:-0}"
            fi
            set -e

            if [[ "$_dump_rc" != "0" || "$_import_rc" != "0" || "$_pv_rc" != "0" ]]; then
                sre_error "Database copy failed (mysqldump=$_dump_rc pv=$_pv_rc mysql=$_import_rc)"
                if [[ -s "$_dump_err" ]]; then
                    sre_error "mysqldump stderr:"
                    sed 's/^/    /' "$_dump_err" | head -20
                fi
                if [[ -s "$_import_err" ]]; then
                    sre_error "mysql import stderr:"
                    sed 's/^/    /' "$_import_err" | head -20
                fi
                exit 1
            fi
            rm -f "$_dump_err" "$_import_err"

            # Second pass: re-add CREATE TABLE for the schema-only set (no rows)
            if [[ ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 ]]; then
                sre_info "Adding empty schema for: ${CL_SKIP_SCHEMA_ONLY[*]}"
                $mysqldump_cmd --no-data --skip-triggers --skip-add-drop-table \
                    "$src_db_name" "${CL_SKIP_SCHEMA_ONLY[@]}" | $mysql_cmd "$tgt_db_name" \
                    && sre_success "Schemas re-imported (empty)" \
                    || sre_warning "Schema re-import had issues — some tables may be missing"
            fi

            sre_success "Database copied"
            ;;

        postgresql)
            # Drop on resume — same rationale as mysql branch
            if sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$tgt_db_name"; then
                sre_warning "Target DB ${tgt_db_name} already exists — dropping for clean re-import"
                sudo -u postgres dropdb "$tgt_db_name" 2>/dev/null || true
            fi

            sudo -u postgres psql -c "DO \$\$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${tgt_db_user}') THEN
                    CREATE ROLE ${tgt_db_user} WITH LOGIN PASSWORD '${tgt_db_pass}';
                ELSE
                    ALTER ROLE ${tgt_db_user} WITH LOGIN PASSWORD '${tgt_db_pass}';
                END IF;
            END \$\$;" 2>/dev/null
            sudo -u postgres createdb -O "$tgt_db_user" "$tgt_db_name"
            sre_success "Target role/db created: ${tgt_db_name} / ${tgt_db_user}"

            # Resolve table-skip plan for PostgreSQL
            for _t in "${CL_SKIP_INPUT[@]}"; do
                case "$CL_SKIP_MODE" in
                    schema-only)   CL_SKIP_SCHEMA_ONLY+=("$_t") ;;
                    skip-entirely) CL_SKIP_FULL+=("$_t") ;;
                    ask)
                        _decision=$(prompt_choice "Skip table '$_t' — how?" \
                            "schema-only (keep CREATE TABLE, drop rows)" \
                            "skip-entirely (no CREATE, no rows)" \
                            "include (don't skip)")
                        case "$_decision" in
                            schema-only*)   CL_SKIP_SCHEMA_ONLY+=("$_t") ;;
                            skip-entirely*) CL_SKIP_FULL+=("$_t") ;;
                        esac
                        ;;
                esac
            done
            progress_set "CL_SKIP_SCHEMA_ONLY_STR" "${CL_SKIP_SCHEMA_ONLY[*]:-}"
            progress_set "CL_SKIP_FULL_STR"        "${CL_SKIP_FULL[*]:-}"

            _pg_dump_extra=()
            for _t in "${CL_SKIP_SCHEMA_ONLY[@]}"; do
                _pg_dump_extra+=( "--exclude-table-data=${_t}" )
            done
            for _t in "${CL_SKIP_FULL[@]}"; do
                _pg_dump_extra+=( "--exclude-table=${_t}" )
            done

            sre_info "Dumping ${src_db_name} → importing into ${tgt_db_name}..."
            if command -v pv &>/dev/null; then
                sudo -u postgres pg_dump "${_pg_dump_extra[@]}" "$src_db_name" | pv -N "DB stream" | sudo -u postgres psql "$tgt_db_name" >/dev/null
            else
                sudo -u postgres pg_dump "${_pg_dump_extra[@]}" "$src_db_name" | sudo -u postgres psql "$tgt_db_name" >/dev/null
            fi
            sre_success "Database copied"
            ;;

        "")
            sre_error "Source DB engine is empty — auto-detection failed and no fallback fired."
            sre_error "This is a bug: report the source project type ($src_type) and how the script was invoked."
            sre_error "Workaround: re-run with --resume after exporting CL_SOURCE_DB_ENGINE=mariadb (or postgresql)."
            exit 1
            ;;
        *)
            sre_error "Unsupported source DB engine: '$src_db_engine' (expected: mariadb, mysql, postgresql)"
            exit 1
            ;;
    esac

    progress_mark_phase DB
elif [[ "$do_db" == "true" ]]; then
    phase_skipped "Copying Database"
fi

################################################################################
# Rewrite app config for new domain + DB
#
# Idempotent: sed patterns replace whatever's currently there. The .preclone.bak
# files are guarded — a re-run won't overwrite the original-source backup with
# an already-rewritten version.
################################################################################

if ! progress_phase_done CONFIG && [[ "$do_files" == "true" || "$do_db" == "true" ]]; then
    phase_header "Rewriting App Config"

    case "$src_type" in
        laravel)
            tgt_env="${tgt_proj_base}/current/.env"
            # Prefer shared/.env if present (release layout)
            [[ -f "${tgt_proj_base}/shared/.env" ]] && tgt_env="${tgt_proj_base}/shared/.env"
            if [[ -f "$tgt_env" ]]; then
                [[ -f "${tgt_env}.preclone.bak" ]] || cp "$tgt_env" "${tgt_env}.preclone.bak"
                if [[ "$do_db" == "true" ]]; then
                    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${tgt_db_name}|" "$tgt_env"
                    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${tgt_db_user}|" "$tgt_env"
                    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${tgt_db_pass}|" "$tgt_env"
                    sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "$tgt_env"
                fi
                sed -i "s|^APP_URL=.*|APP_URL=${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}|" "$tgt_env"
                # Only flip APP_ENV for staging clones — a live clone keeps the
                # source's env (typically "production").
                if [[ "$CL_PURPOSE" == "stage" ]]; then
                    if grep -q '^APP_ENV=' "$tgt_env"; then
                        sed -i "s|^APP_ENV=.*|APP_ENV=staging|" "$tgt_env"
                    else
                        echo "APP_ENV=staging" >> "$tgt_env"
                    fi
                fi
                sre_success ".env rewritten: $tgt_env (APP_URL=${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN})"

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
                [[ -f "${tgt_wpc}.preclone.bak" ]] || cp "$tgt_wpc" "${tgt_wpc}.preclone.bak"
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
                        "UPDATE \`${wp_prefix}options\` SET option_value='${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}' WHERE option_name IN ('siteurl','home');" 2>/dev/null \
                        && sre_success "WP siteurl/home → ${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}" \
                        || sre_warning "Could not update WP siteurl (run wp-cli search-replace manually)"

                    # Full content rewrite (post bodies, serialized options, etc.).
                    # Without this, a live clone keeps old-domain URLs in posts
                    # — visible to end users. Stage clones benefit too.
                    src_scheme="http"
                    grep -qE 'listen\s+443|ssl_certificate' "$src_vhost" 2>/dev/null && src_scheme="https"

                    if command -v wp &>/dev/null; then
                        sre_info "Running wp search-replace (full content + serialized data)..."
                        ( cd "${tgt_proj_base}/current" && \
                          sudo -u www-data wp --skip-themes --skip-plugins \
                            search-replace \
                            "${src_scheme}://${CL_SOURCE_DOMAIN}" \
                            "${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}" \
                            --all-tables --precise --report-changed-only 2>&1 | tail -20 ) \
                            && sre_success "wp search-replace complete" \
                            || sre_warning "wp search-replace had issues — review manually"
                        ( cd "${tgt_proj_base}/current" && \
                          sudo -u www-data wp --skip-themes --skip-plugins cache flush 2>/dev/null || true )
                    else
                        sre_warning "wp-cli not installed — post bodies still contain old domain URLs."
                        sre_warning "Install wp-cli and run:"
                        sre_warning "  cd ${tgt_proj_base}/current && sudo -u www-data wp search-replace \\"
                        sre_warning "    '${src_scheme}://${CL_SOURCE_DOMAIN}' '${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}' --all-tables"
                    fi
                fi
            fi
            ;;

        moodle)
            # Use the mirrored target config path computed earlier; fall back
            # to the legacy public_html/ location if unknown.
            tgt_mcf="${tgt_moodle_config:-${tgt_proj_base}/public_html/config.php}"
            if [[ -f "$tgt_mcf" ]]; then
                [[ -f "${tgt_mcf}.preclone.bak" ]] || cp "$tgt_mcf" "${tgt_mcf}.preclone.bak"
                if [[ "$do_db" == "true" ]]; then
                    # Update dbname/dbuser/dbpass — keep dbtype/prefix
                    sed -i "s|\(\$CFG->dbname\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_name}'|" "$tgt_mcf"
                    sed -i "s|\(\$CFG->dbuser\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_user}'|" "$tgt_mcf"
                    sed -i "s|\(\$CFG->dbpass\s*=\s*\)['\"][^'\"]*['\"]|\1'${tgt_db_pass}'|" "$tgt_mcf"
                fi

                # wwwroot — uses the resolved scheme. THIS is the load-bearing
                # fix: Moodle requires wwwroot's scheme to match the served URL.
                sed -i "s|\(\$CFG->wwwroot\s*=\s*\)['\"][^'\"]*['\"]|\1'${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}'|" "$tgt_mcf"

                # dataroot
                if [[ -n "${CL_TGT_MOODLEDATA:-}" ]]; then
                    sed -i "s|\(\$CFG->dataroot\s*=\s*\)['\"][^'\"]*['\"]|\1'${CL_TGT_MOODLEDATA}'|" "$tgt_mcf"
                fi

                # tempdir / cachedir / localcachedir / backuptempdir — if the
                # source config sets them as absolute paths under the source
                # tree, they still point at the source after the file copy.
                # Rewrite to the matching path under the target tree.
                for setting in tempdir cachedir localcachedir backuptempdir; do
                    # `|| true` is load-bearing: most config.php files don't set
                    # these explicitly (Moodle uses defaults). Without it, grep
                    # returns 1, pipefail propagates, set -e kills the script
                    # silently right here on the first loop iteration.
                    old_val=$( { grep -oE "\\\$CFG->${setting}\s*=\s*['\"][^'\"]+" "$tgt_mcf" || true; } | head -1 | sed "s|.*['\"]||" )
                    if [[ -z "$old_val" ]]; then continue; fi

                    new_val=""
                    if [[ "$old_val" == "${src_proj_base}"* ]]; then
                        # Path is under the source project tree → rewrite to target tree
                        new_val="${tgt_proj_base}${old_val#${src_proj_base}}"
                    elif [[ -n "${CL_TGT_MOODLEDATA:-}" ]]; then
                        # See if it's under source moodledata
                        if [[ -n "${mdldata:-}" && "$old_val" == "${mdldata}"* ]]; then
                            new_val="${CL_TGT_MOODLEDATA}${old_val#${mdldata}}"
                        fi
                    fi

                    if [[ -n "$new_val" ]]; then
                        sed -i "s|\(\$CFG->${setting}\s*=\s*\)['\"][^'\"]*['\"]|\1'${new_val}'|" "$tgt_mcf"
                        sre_info "  rewrote \$CFG->${setting}: ${old_val} → ${new_val}"
                        # Make sure target dir exists
                        mkdir -p "$new_val"
                        chown -R www-data:www-data "$new_val"
                    fi
                done

                sre_success "Moodle config.php rewritten (wwwroot=${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN})"

                # The DB-side wwwroot update is mostly a no-op (Moodle reads
                # wwwroot from config.php, not the DB), but harmless on the
                # rare installs that mirror it.
                if [[ "$do_db" == "true" ]]; then
                    $mysql_cmd "$tgt_db_name" -e \
                        "UPDATE \`${moodle_prefix}config\` SET value='${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}' WHERE name='wwwroot';" 2>/dev/null || true

                    # Wipe stale version markers so first request rebuilds caches
                    $mysql_cmd "$tgt_db_name" -e "DELETE FROM \`${moodle_prefix}config_plugins\` WHERE name='version' AND plugin LIKE 'cache%';" 2>/dev/null || true
                fi

                # Hard purge via Moodle's own CLI — clears localcache + DB caches.
                # Skips silently if the CLI doesn't load (e.g. DB not reachable yet).
                # Walk up from config.php to find the Moodle root (admin/ should sit beside config.php).
                moodle_root=$(dirname "$tgt_mcf")
                if command -v php &>/dev/null && [[ -f "${moodle_root}/admin/cli/purge_caches.php" ]]; then
                    sre_info "Purging Moodle caches via admin/cli/purge_caches.php..."
                    ( cd "$moodle_root" && \
                      sudo -u www-data php admin/cli/purge_caches.php 2>&1 | tail -5 ) \
                        && sre_success "Moodle caches purged" \
                        || sre_warning "Moodle cache purge had warnings — run manually after install"
                fi
            fi
            ;;

        nuxt|vue|static)
            sre_info "$src_type: no app config rewrite needed (static/HTML)"
            ;;
    esac
    progress_mark_phase CONFIG
elif progress_phase_done CONFIG; then
    phase_skipped "Rewriting App Config"
fi

################################################################################
# Create new vhost via step 8
################################################################################

if progress_phase_done VHOST; then
    phase_skipped "Creating Vhost for Target Domain"
    # Restore CL_TGT_PORT for downstream PM2/finishing logic if it was persisted
    : "${CL_TGT_PORT:=}"
else
    phase_header "Creating Vhost for Target Domain"

# Pick a unique Nuxt port if needed
vhost_args=( --domain "$CL_TARGET_DOMAIN" --type "$src_type" --yes )

if [[ "$src_type" == "nuxt" ]]; then
    # Source port from source vhost; pick next free
    src_port=$( { grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "$src_vhost" || true; } | head -1)
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

sre_info "Calling step 8 with: --type $src_type --domain $CL_TARGET_DOMAIN --root $tgt_doc_root"
sre_info "Expected template: ${web_server}-${src_type}.conf"

# If a stale vhost from a wrong-type clone is in place, remove it FIRST so
# step 8 doesn't preserve any non-template directives via the overwrite path.
if [[ -f "$tgt_vhost" ]]; then
    cur_type=""
    if grep -q 'fastcgi_pass' "$tgt_vhost" 2>/dev/null; then
        if grep -q 'moodledata\|pluginfile' "$tgt_vhost" 2>/dev/null; then
            cur_type="moodle"
        elif grep -q 'wp-config\|wp-content' "$tgt_vhost" 2>/dev/null; then
            cur_type="wordpress"
        else
            cur_type="laravel"
        fi
    elif grep -q 'proxy_pass.*127\.0\.0\.1' "$tgt_vhost" 2>/dev/null; then
        cur_type="nuxt"
    elif grep -q 'try_files.*index\.html' "$tgt_vhost" 2>/dev/null; then
        cur_type="vue"
    else
        cur_type="static"
    fi
    if [[ "$cur_type" != "$src_type" ]]; then
        sre_warning "Removing stale '$cur_type' vhost before generating fresh '$src_type' vhost: $tgt_vhost"
        # backup_config saves a timestamped .bak and removes the symlink in
        # sites-enabled/. Step 8 will then create both fresh from the template.
        backup_config "$tgt_vhost"
        rm -f "$tgt_vhost"
        # Also drop the sites-enabled symlink (Debian layout)
        enabled_link="${tgt_vhost/sites-available/sites-enabled}"
        [[ -L "$enabled_link" ]] && rm -f "$enabled_link"
    fi
fi

bash "${SRE_SCRIPTS_DIR}/vhost/08-vhost.sh" "${vhost_args[@]}" \
    || { sre_error "Vhost creation failed"; exit 1; }

# Verify the resulting vhost actually has the expected type's markers
if [[ -f "$tgt_vhost" ]]; then
    case "$src_type" in
        moodle|laravel|wordpress|phpmyadmin)
            if ! grep -q 'fastcgi_pass' "$tgt_vhost" 2>/dev/null; then
                sre_error "Generated vhost is missing fastcgi_pass — it doesn't look like a $src_type vhost!"
                sre_error "Check: $tgt_vhost"
                sre_error "Template that should have been used: ${SRE_SCRIPTS_DIR}/vhost/templates/${web_server}-${src_type}.conf"
                exit 1
            fi
            ;;
    esac
    sre_success "Vhost written: $tgt_vhost (type=$src_type)"
fi

    # Persist port (for nuxt) so resumed finishing-touches PM2 start uses the same port
    [[ -n "${CL_TGT_PORT:-}" ]] && progress_set "CL_TGT_PORT" "$CL_TGT_PORT"
    progress_mark_phase VHOST
fi   # end VHOST phase guard

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

if ! progress_phase_done PERMS; then
    phase_header "Fix Permissions"

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
            # Lock down target Moodle config.php (mirrored path; falls back to public_html)
            for _mcf_path in "${tgt_moodle_config:-}" "${tgt_proj_base}/public_html/config.php" "${tgt_doc_root}/config.php"; do
                [[ -n "$_mcf_path" && -f "$_mcf_path" ]] && chmod 640 "$_mcf_path" && break
            done
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
    progress_mark_phase PERMS
else
    phase_skipped "Fix Permissions"
fi

################################################################################
# Save clone state
################################################################################

mkdir -p /etc/sre-helpers/clones
clone_state="/etc/sre-helpers/clones/${CL_TARGET_DOMAIN}.conf"
{
    printf '# Clone created %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'CL_SOURCE_DOMAIN=%q\n'  "$CL_SOURCE_DOMAIN"
    printf 'CL_TARGET_DOMAIN=%q\n'  "$CL_TARGET_DOMAIN"
    printf 'CL_PURPOSE=%q\n'        "$CL_PURPOSE"
    printf 'CL_TGT_SCHEME=%q\n'     "$CL_TGT_SCHEME"
    printf 'CL_PROJECT_TYPE=%q\n'   "$src_type"
    printf 'CL_MODE=%q\n'           "$CL_MODE"
    printf 'CL_TGT_DB_NAME=%q\n'    "${tgt_db_name:-}"
    printf 'CL_TGT_DB_USER=%q\n'    "${tgt_db_user:-}"
    printf 'CL_TGT_DB_PASS=%q\n'    "${tgt_db_pass:-}"
    printf 'CL_TGT_PORT=%q\n'       "${CL_TGT_PORT:-}"
    printf 'CL_TGT_MOODLEDATA=%q\n' "${CL_TGT_MOODLEDATA:-}"
    printf 'CL_SKIP_SCHEMA_ONLY=%q\n' "${CL_SKIP_SCHEMA_ONLY[*]:-}"
    printf 'CL_SKIP_FULL=%q\n'        "${CL_SKIP_FULL[*]:-}"
} > "$clone_state"
chmod 600 "$clone_state"
sre_info "Clone state: $clone_state"

################################################################################
# Offer SSL  (run BEFORE protection injection — certbot may rewrite the vhost)
#
# If the target scheme was resolved as https, SSL is mandatory: app config was
# already written with https URLs, so without a cert the site will return mixed
# content / TLS errors. We strongly default to yes; explicitly warn if declined.
################################################################################

if ! progress_phase_done SSL; then
    phase_header "SSL Setup"

    ssl_prompt="Setup SSL for $CL_TARGET_DOMAIN now?"
    if [[ "$CL_TGT_SCHEME" == "https" ]]; then
        ssl_prompt="App config was written with https URLs. Provision SSL for $CL_TARGET_DOMAIN now? (strongly recommended)"
    fi

    if prompt_yesno "$ssl_prompt" "yes"; then
        bash "${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh" --domain "$CL_TARGET_DOMAIN" --yes \
            || sre_warning "SSL setup didn't complete — re-run manually if needed"
    elif [[ "$CL_TGT_SCHEME" == "https" ]]; then
        sre_warning "App config has https URLs but no cert was provisioned."
        sre_warning "The clone will not load until you run:"
        sre_warning "  sudo bash ${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh --domain $CL_TARGET_DOMAIN"
    fi

    progress_mark_phase SSL
else
    phase_skipped "SSL Setup"
fi

################################################################################
# Staging protection (noindex + htpasswd + IP allowlist)
#
# Applied AFTER SSL so we patch the final cert-aware vhost. Inserts into every
# server { } block (HTTP + HTTPS), so the clone stays protected even if
# certbot added a fresh SSL server block.
################################################################################

if progress_phase_done PROTECT; then
    phase_skipped "Clone Protection"
elif [[ "$CL_PROTECT" == "yes" ]] && [[ "$CL_NOINDEX" == "yes" || "$CL_HTPASSWD" == "yes" ]]; then
    phase_header "Clone Protection"

    htpasswd_file=""

    # --- htpasswd file ---
    if [[ "$CL_HTPASSWD" == "yes" ]]; then
        # Ensure htpasswd binary
        if ! command -v htpasswd &>/dev/null; then
            case "$os_family" in
                debian) pkg_install apache2-utils ;;
                rhel)   pkg_install httpd-tools ;;
            esac
        fi

        if ! command -v htpasswd &>/dev/null; then
            sre_warning "htpasswd not available — disabling basic auth"
            CL_HTPASSWD="no"
        else
            [[ -z "$CL_PROTECT_USER" ]] && CL_PROTECT_USER="staging"
            if [[ -z "$CL_PROTECT_PASS" ]]; then
                CL_PROTECT_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)
            fi

            # Per-domain htpasswd file (Nginx-friendly path; Apache reads it too)
            htpasswd_file="/etc/nginx/htpasswd-${CL_TARGET_DOMAIN}"
            [[ "$web_server" == "apache" ]] && htpasswd_file="/etc/apache2/htpasswd-${CL_TARGET_DOMAIN}"
            [[ "$os_family" == "rhel" && "$web_server" == "apache" ]] && htpasswd_file="/etc/httpd/htpasswd-${CL_TARGET_DOMAIN}"

            htpasswd -bc "$htpasswd_file" "$CL_PROTECT_USER" "$CL_PROTECT_PASS" >/dev/null
            chmod 640 "$htpasswd_file"
            chown root:www-data "$htpasswd_file" 2>/dev/null || true
            sre_success "Basic auth credentials written: $htpasswd_file"
        fi
    fi

    # --- Build + inject snippet ---
    case "$web_server" in
        nginx)  snippet=$(_build_nginx_protect_snippet  "$htpasswd_file") ;;
        apache) snippet=$(_build_apache_protect_snippet "$htpasswd_file") ;;
    esac

    if _inject_protection_into_vhost "$tgt_vhost" "$snippet" "$web_server"; then
        sre_success "Protection directives injected into $tgt_vhost"
    else
        sre_warning "Could not patch vhost — apply manually"
    fi

    # --- robots.txt (belt-and-suspenders, survives if header gets stripped) ---
    if [[ "$CL_NOINDEX" == "yes" ]]; then
        # Write into the target doc root (or current/public for Laravel)
        robots_target="${tgt_doc_root}/robots.txt"
        if [[ -d "$tgt_doc_root" ]]; then
            cat > "$robots_target" <<ROBOTS
# Staging clone — do not index
User-agent: *
Disallow: /
ROBOTS
            chown www-data:www-data "$robots_target" 2>/dev/null || true
            chmod 644 "$robots_target"
            sre_success "robots.txt written: $robots_target"
        else
            sre_warning "Doc root missing — robots.txt skipped"
        fi
    fi

    # --- Test config + reload ---
    case "$web_server" in
        nginx)
            if nginx -t 2>&1 | tail -2; then
                svc_reload nginx && sre_success "Nginx reloaded with protection"
            else
                sre_error "Nginx config test failed after injection — review $tgt_vhost"
            fi
            ;;
        apache)
            test_cmd="apachectl configtest"
            [[ "$os_family" == "rhel" ]] && test_cmd="httpd -t"
            if $test_cmd 2>&1 | tail -2; then
                case "$os_family" in
                    debian) svc_reload apache2 ;;
                    rhel)   svc_reload httpd ;;
                esac
                sre_success "Apache reloaded with protection"
            else
                sre_error "Apache config test failed after injection — review $tgt_vhost"
            fi
            ;;
    esac

    # --- Append creds to clone state file ---
    if [[ -f "$clone_state" ]]; then
        {
            printf 'CL_PROTECT=%q\n'        "yes"
            printf 'CL_PROTECT_USER=%q\n'   "${CL_PROTECT_USER:-}"
            printf 'CL_PROTECT_PASS=%q\n'   "${CL_PROTECT_PASS:-}"
            printf 'CL_HTPASSWD_FILE=%q\n'  "${htpasswd_file:-}"
            printf 'CL_ALLOW_IPS=%q\n'      "${CL_ALLOW_IPS[*]:-}"
        } >> "$clone_state"
        chmod 600 "$clone_state"
    fi

    progress_mark_phase PROTECT
else
    # Protection wasn't requested for this purpose — still mark complete so
    # resume doesn't pause on it.
    progress_mark_phase PROTECT
fi

################################################################################
# All phases done — clear the progress file. The durable record lives in
# $clone_state ($CLONE_STATE_DIR/<target>.conf).
################################################################################

progress_mark_phase FINISH
rm -f "$CLONE_PROGRESS"

################################################################################
# Summary
################################################################################

sre_header "Clone Complete"

sre_success "$CL_SOURCE_DOMAIN  →  $CL_TARGET_DOMAIN"
echo ""
sre_info "  Purpose:       $CL_PURPOSE"
sre_info "  Type:          $src_type"
sre_info "  Mode:          $CL_MODE"
sre_info "  Target URL:    ${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}"
sre_info "  Target root:   $tgt_proj_base"
sre_info "  Target doc:    $tgt_doc_root"
if [[ "$do_db" == "true" ]]; then
    sre_info "  Target DB:     $tgt_db_name"
    sre_info "  Target DB user:$tgt_db_user"
    sre_info "  Target DB pass:$tgt_db_pass"
    # `${#array[@]:-0}` is NOT valid bash syntax — the :- default operator
    # only works on scalar expansions. Use ${array[@]+1} to test if the
    # array exists, then read the length normally.
    if [[ -n "${CL_SKIP_SCHEMA_ONLY[*]+1}" && ${#CL_SKIP_SCHEMA_ONLY[@]} -gt 0 ]]; then
        sre_info "  Skipped (schema only):  ${CL_SKIP_SCHEMA_ONLY[*]}"
    fi
    if [[ -n "${CL_SKIP_FULL[*]+1}" && ${#CL_SKIP_FULL[@]} -gt 0 ]]; then
        sre_info "  Skipped (entirely):     ${CL_SKIP_FULL[*]}"
    fi
fi
[[ "$src_type" == "nuxt" ]] && sre_info "  Nuxt port:     ${CL_TGT_PORT:-?}"
echo ""
sre_warning "Save the DB password!"
echo ""

if [[ "$CL_PROTECT" == "yes" ]] && [[ "$CL_NOINDEX" == "yes" || "$CL_HTPASSWD" == "yes" ]]; then
    sre_header "Clone Protection Active"
    [[ "$CL_NOINDEX"  == "yes" ]] && sre_info "  noindex:  X-Robots-Tag header + robots.txt (Disallow: /)"
    if [[ "$CL_HTPASSWD" == "yes" ]]; then
        sre_info "  Basic auth user: $CL_PROTECT_USER"
        sre_info "  Basic auth pass: $CL_PROTECT_PASS"
        sre_warning "  Save the basic-auth password!"
    fi
    if [[ ${#CL_ALLOW_IPS[@]} -gt 0 ]]; then
        sre_info "  IP allowlist (no auth needed): ${CL_ALLOW_IPS[*]}"
    fi
    echo ""
fi

sre_info "Next steps:"
sre_info "  1. Point ${CL_TARGET_DOMAIN} DNS at this server (or rely on wildcard)"
sre_info "  2. Visit ${CL_TGT_SCHEME}://${CL_TARGET_DOMAIN}"
if [[ "$CL_HTPASSWD" == "yes" ]]; then
    sre_info "  3. Browser will prompt for basic auth — use the creds above"
    sre_info "  4. Verify app loads cleanly"
else
    sre_info "  3. Verify app loads cleanly"
fi
if [[ "$CL_PURPOSE" == "live" ]]; then
    echo ""
    sre_info "  This is a LIVE clone. The source and target are independent —"
    sre_info "  changes on one will NOT propagate to the other."
fi

recommend_next_step "$CURRENT_STEP"
