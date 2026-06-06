#!/bin/bash
################################################################################
# SRE Helpers - Step 18: Install Custom SSL Certificate
#
# Installs a user-supplied SSL certificate (wildcard OR single-domain) and
# applies it to every matching vhost on the server.
#
# What it does:
#   1. Takes a cert + private key (paths, or interactive paste).
#   2. Validates the pair (cert/key modulus must match).
#   3. Parses the cert's SANs to know what domains it covers.
#   4. Parks the cert under /etc/ssl/wildcards/<base>/{fullchain.pem,privkey.pem}
#      using the LE-style layout that step 11 already scans.
#   5. Scans every vhost on the server. For each domain the cert covers:
#        - backs up the current vhost
#        - delegates to step 11 with --no-wildcard=false (it will auto-find the
#          cert via /etc/ssl/wildcards and skip Certbot)
#   6. Saves install state under /etc/sre-helpers/custom-ssl/<base>.conf.
#
# Typical inputs:
#   - Wildcard *.example.com → applies to all *.example.com vhosts on this box
#   - Single-domain cert     → applies only to that one domain (still useful
#     for replacing an LE cert with a paid CA cert)
#
# What it does NOT do:
#   - Touch DNS or order new certs (this step is for certs you already own).
#   - Rewrite SSL configs from scratch — it leans on step 11.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=18

CSSL_CERT_PATH=""
CSSL_KEY_PATH=""
CSSL_CHAIN_PATH=""       # optional intermediate chain (concat'd into fullchain)
CSSL_PARK_DIR="/etc/ssl/wildcards"
CSSL_AUTO_APPLY="ask"    # ask|yes|no
CSSL_DOMAINS_FILTER=()   # only apply to these vhosts (else: all matched)
CSSL_INPUT_MODE="ask"    # ask|paths|paste

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 18: Install Custom SSL Certificate

  Installs a user-supplied wildcard or single-domain certificate and applies
  it to every matching vhost on this server. The cert is parked at
  ${CSSL_PARK_DIR}/<base>/ so step 11 can also find it for future vhosts.

Options:
  --cert <path>         Path to PEM certificate (fullchain or leaf)
  --key  <path>         Path to PEM private key
  --chain <path>        Optional intermediate chain (concat'd with --cert)
  --park-dir <path>     Where to store the cert (default: ${CSSL_PARK_DIR})
  --paste               Read cert + key interactively from stdin
  --apply               Auto-apply to all matched vhosts (no prompt)
  --no-apply            Park the cert only; don't touch any vhost
  --domain <name>       Limit application to this vhost only (repeatable)

  --dry-run             Print planned actions only
  --yes                 Accept defaults without prompting
  --help                Show this help

Examples:
  # From files
  sudo bash $0 --cert /tmp/wild.example.com.fullchain.pem \\
               --key  /tmp/wild.example.com.privkey.pem

  # From files, with separate intermediate chain
  sudo bash $0 --cert leaf.pem --chain chain.pem --key key.pem

  # Paste into terminal
  sudo bash $0 --paste

  # Park only — review match list, then re-run step 11 per domain manually
  sudo bash $0 --cert wild.pem --key wild.key --no-apply

  # Park + apply only to one vhost
  sudo bash $0 --cert wild.pem --key wild.key --domain app.example.com
EOF
}

_raw_args=("$@")
sre_parse_args "18-custom-ssl.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --cert)      _i=$((_i + 1)); CSSL_CERT_PATH="${_raw_args[$_i]:-}"; CSSL_INPUT_MODE="paths" ;;
        --key)       _i=$((_i + 1)); CSSL_KEY_PATH="${_raw_args[$_i]:-}";  CSSL_INPUT_MODE="paths" ;;
        --chain)     _i=$((_i + 1)); CSSL_CHAIN_PATH="${_raw_args[$_i]:-}" ;;
        --park-dir)  _i=$((_i + 1)); CSSL_PARK_DIR="${_raw_args[$_i]:-/etc/ssl/wildcards}" ;;
        --paste)     CSSL_INPUT_MODE="paste" ;;
        --apply)     CSSL_AUTO_APPLY="yes" ;;
        --no-apply)  CSSL_AUTO_APPLY="no" ;;
        --domain)    _i=$((_i + 1)); CSSL_DOMAINS_FILTER+=("${_raw_args[$_i]:-}") ;;
    esac
    _i=$((_i + 1))
done

require_root
sre_header "Step 18: Install Custom SSL Certificate"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

web_server=$(config_get "SRE_WEB_SERVER" "")
os_family=$(config_get "SRE_OS_FAMILY" "debian")

if [[ -z "$web_server" ]]; then
    sre_error "Web server not configured. Run step 3 first."
    exit 2
fi

command -v openssl &>/dev/null || { sre_error "openssl required"; exit 2; }

################################################################################
# Input: paths vs paste
################################################################################

if [[ "$CSSL_INPUT_MODE" == "ask" ]]; then
    mode=$(prompt_choice "How do you want to provide the cert?" "Paths to files" "Paste into terminal")
    case "$mode" in
        "Paste into terminal") CSSL_INPUT_MODE="paste" ;;
        *)                     CSSL_INPUT_MODE="paths" ;;
    esac
fi

if [[ "$CSSL_INPUT_MODE" == "paste" ]]; then
    sre_header "Paste Certificate + Key"

    echo "Paste the FULL certificate chain (BEGIN CERTIFICATE...END CERTIFICATE)."
    echo "End with a line containing only:  EOF"
    cert_paste=$(awk '/^EOF$/{exit} {print}')
    CSSL_CERT_PATH=$(mktemp /tmp/cssl-cert.XXXXXX.pem)
    printf '%s\n' "$cert_paste" > "$CSSL_CERT_PATH"

    echo ""
    echo "Paste the PRIVATE KEY (BEGIN PRIVATE KEY...END PRIVATE KEY)."
    echo "End with a line containing only:  EOF"
    key_paste=$(awk '/^EOF$/{exit} {print}')
    CSSL_KEY_PATH=$(mktemp /tmp/cssl-key.XXXXXX.pem)
    printf '%s\n' "$key_paste" > "$CSSL_KEY_PATH"
    chmod 600 "$CSSL_KEY_PATH"
fi

[[ -z "$CSSL_CERT_PATH" ]] && CSSL_CERT_PATH=$(prompt_input "Path to certificate PEM" "")
[[ -z "$CSSL_KEY_PATH"  ]] && CSSL_KEY_PATH=$(prompt_input "Path to private key PEM" "")

[[ -f "$CSSL_CERT_PATH" ]] || { sre_error "Certificate not found: $CSSL_CERT_PATH"; exit 1; }
[[ -f "$CSSL_KEY_PATH"  ]] || { sre_error "Key not found: $CSSL_KEY_PATH"; exit 1; }
[[ -n "$CSSL_CHAIN_PATH" && ! -f "$CSSL_CHAIN_PATH" ]] && { sre_error "Chain not found: $CSSL_CHAIN_PATH"; exit 1; }

################################################################################
# Validate cert + key
################################################################################

sre_header "Validating Certificate"

# Verify cert+key match by comparing their public keys (works for RSA + EC).
cert_pub_sha=$(openssl x509 -in "$CSSL_CERT_PATH" -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
key_pub_sha=$(openssl pkey -in "$CSSL_KEY_PATH" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')

if [[ -z "$cert_pub_sha" || -z "$key_pub_sha" ]]; then
    sre_error "Could not extract public key from cert or key — file format invalid?"
    exit 1
fi

if [[ "$cert_pub_sha" != "$key_pub_sha" ]]; then
    sre_error "Certificate and private key DO NOT match!"
    sre_error "  cert pubkey SHA-256: $cert_pub_sha"
    sre_error "  key  pubkey SHA-256: $key_pub_sha"
    exit 1
fi

sre_success "Certificate + key match (pubkey SHA-256: ${cert_pub_sha:0:16}...)"

# Expiry check
if ! openssl x509 -in "$CSSL_CERT_PATH" -noout -checkend 0 &>/dev/null; then
    sre_error "Certificate is EXPIRED."
    exit 1
fi

enddate=$(openssl x509 -in "$CSSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
issuer=$(openssl  x509 -in "$CSSL_CERT_PATH" -noout -issuer  2>/dev/null | sed 's/issuer=//')
subject=$(openssl x509 -in "$CSSL_CERT_PATH" -noout -subject 2>/dev/null | sed 's/subject=//')

sre_info "  Subject:  $subject"
sre_info "  Issuer:   $issuer"
sre_info "  Expires:  $enddate"

# Warn if leaf-only (no chain) — browsers often need intermediates
chain_count=$(grep -c 'BEGIN CERTIFICATE' "$CSSL_CERT_PATH" 2>/dev/null || echo 0)
if [[ "$chain_count" -le 1 && -z "$CSSL_CHAIN_PATH" ]]; then
    sre_warning "Cert file contains only the leaf certificate (no intermediates)."
    sre_warning "Browsers/clients may report an incomplete chain."
    sre_warning "Pass --chain <intermediate.pem> to concat, or provide a full chain."
fi

################################################################################
# Parse SANs to figure out what this cert covers
################################################################################

cert_sans=$(openssl x509 -in "$CSSL_CERT_PATH" -noout -ext subjectAltName 2>/dev/null \
    | grep -oP 'DNS:\K[^,\s]+' | sort -u)

if [[ -z "$cert_sans" ]]; then
    # Fall back to CN
    cn=$(echo "$subject" | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | tr -d ' ')
    [[ -n "$cn" ]] && cert_sans="$cn"
fi

if [[ -z "$cert_sans" ]]; then
    sre_error "Certificate has no SANs and no CN — cannot determine coverage."
    exit 1
fi

sre_info "  Covers (SANs):"
while IFS= read -r san; do
    [[ -n "$san" ]] && sre_info "    - $san"
done <<<"$cert_sans"

# Pick a friendly "base" name for parking
# - prefer first *.xxx SAN (wildcard) → base = xxx
# - else first SAN → base = that
base=""
while IFS= read -r san; do
    if [[ "$san" == \*.* ]]; then
        base="${san#*.}"
        break
    fi
done <<<"$cert_sans"
if [[ -z "$base" ]]; then
    base=$(echo "$cert_sans" | head -1)
fi
sre_info "  Park base: $base"

################################################################################
# Park the cert
################################################################################

sre_header "Parking Certificate"

park_target="${CSSL_PARK_DIR}/${base}"

if [[ -d "$park_target" ]]; then
    sre_warning "Park target already exists: $park_target"
    if ! prompt_yesno "Overwrite existing cert at $park_target?" "yes"; then
        sre_skipped "Install cancelled."
        exit 4
    fi
fi

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    mkdir -p "$park_target"
    chmod 750 "$park_target"

    # Build fullchain: cert + optional chain
    if [[ -n "$CSSL_CHAIN_PATH" ]]; then
        cat "$CSSL_CERT_PATH" "$CSSL_CHAIN_PATH" > "${park_target}/fullchain.pem"
    else
        cp "$CSSL_CERT_PATH" "${park_target}/fullchain.pem"
    fi
    cp "$CSSL_KEY_PATH" "${park_target}/privkey.pem"

    # Also drop a cert.pem (leaf only) and chain.pem (intermediates) for tools that want them split
    openssl x509 -in "$CSSL_CERT_PATH" -out "${park_target}/cert.pem" 2>/dev/null
    if [[ -n "$CSSL_CHAIN_PATH" ]]; then
        cp "$CSSL_CHAIN_PATH" "${park_target}/chain.pem"
    fi

    chown root:root "${park_target}"/*.pem
    chmod 644 "${park_target}/fullchain.pem" "${park_target}/cert.pem"
    [[ -f "${park_target}/chain.pem" ]] && chmod 644 "${park_target}/chain.pem"
    chmod 600 "${park_target}/privkey.pem"

    sre_success "Parked: $park_target"
else
    sre_info "[DRY-RUN] Would park cert at: $park_target"
fi

################################################################################
# Scan vhosts and figure out which domains this cert covers
################################################################################

sre_header "Scanning Vhosts"

vhost_dir=$(get_vhost_dir "$web_server")
all_vhosts=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    d=$(basename "$f" .conf)
    [[ "$d" == "default" || "$d" == "000-default" || "$d" == "security" ]] && continue
    all_vhosts+=("$d")
done < <(ls -1 "$vhost_dir"/*.conf 2>/dev/null | sort)

if [[ ${#all_vhosts[@]} -eq 0 ]]; then
    sre_warning "No vhosts found in $vhost_dir"
    sre_info "Cert parked. Step 11 will find it when you set up SSL for a vhost."
    exit 0
fi

# Inline SAN-match (same logic as step 11)
_cert_covers() {
    local domain="$1"
    while IFS= read -r san; do
        [[ -z "$san" ]] && continue
        if [[ "$san" == "$domain" ]]; then
            echo "$san"; return 0
        fi
        if [[ "$san" == \*.* ]]; then
            local parent="${san#*.}"
            if [[ "$domain" == *.${parent} ]]; then
                local prefix="${domain%.${parent}}"
                if [[ -n "$prefix" && "$prefix" != *.* ]]; then
                    echo "$san"; return 0
                fi
            fi
        fi
    done <<<"$cert_sans"
    return 1
}

matched=()
unmatched=()
for d in "${all_vhosts[@]}"; do
    # Honor --domain filter
    if [[ ${#CSSL_DOMAINS_FILTER[@]} -gt 0 ]]; then
        found=0
        for f in "${CSSL_DOMAINS_FILTER[@]}"; do
            [[ "$f" == "$d" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && continue
    fi

    if san=$(_cert_covers "$d"); then
        matched+=("${d}|${san}")
    else
        unmatched+=("$d")
    fi
done

sre_info "Vhosts matched by this cert (${#matched[@]}):"
if [[ ${#matched[@]} -eq 0 ]]; then
    sre_warning "  (none)"
else
    for m in "${matched[@]}"; do
        sre_info "  ${_GREEN:-}✓${_NC:-} ${m%%|*}  ← SAN: ${m##*|}"
    done
fi
if [[ ${#unmatched[@]} -gt 0 ]] && [[ ${#CSSL_DOMAINS_FILTER[@]} -eq 0 ]]; then
    sre_info "Vhosts NOT covered by this cert (${#unmatched[@]}):"
    for d in "${unmatched[@]}"; do
        sre_info "  - $d"
    done
fi

################################################################################
# Apply to each matched vhost via step 11
################################################################################

if [[ ${#matched[@]} -eq 0 ]]; then
    sre_warning "Nothing to apply. Cert is parked at $park_target."
    exit 0
fi

if [[ "$CSSL_AUTO_APPLY" == "ask" ]]; then
    if prompt_yesno "Apply this cert to all ${#matched[@]} matched vhost(s)?" "yes"; then
        CSSL_AUTO_APPLY="yes"
    else
        CSSL_AUTO_APPLY="no"
    fi
fi

if [[ "$CSSL_AUTO_APPLY" != "yes" ]]; then
    sre_info "Skipping vhost updates. Cert parked at $park_target."
    sre_info "Apply later per domain:  sudo bash ssl/11-ssl.sh --domain <d> --wildcard-dir ${CSSL_PARK_DIR}"
    exit 0
fi

if [[ "$SRE_DRY_RUN" == "true" ]]; then
    sre_info "[DRY-RUN] Would apply cert to ${#matched[@]} vhost(s) via step 11."
    exit 0
fi

sre_header "Applying to Matched Vhosts"

applied=0
failed=()
for m in "${matched[@]}"; do
    d="${m%%|*}"
    san="${m##*|}"
    sre_header "  → $d  (matched via $san)"

    # Delegate to step 11 — it will find the parked cert via SSL_WILDCARD_DIR
    # and skip Certbot. --yes for non-interactive run.
    if bash "${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh" \
        --domain "$d" \
        --wildcard-dir "$CSSL_PARK_DIR" \
        --yes; then
        sre_success "  $d updated"
        applied=$((applied + 1))
    else
        sre_error "  $d FAILED (step 11 returned non-zero)"
        failed+=("$d")
    fi
done

################################################################################
# Save install state
################################################################################

mkdir -p /etc/sre-helpers/custom-ssl
state_file="/etc/sre-helpers/custom-ssl/${base}.conf"
{
    printf '# Custom SSL installed %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'CSSL_BASE=%q\n'        "$base"
    printf 'CSSL_PARK_TARGET=%q\n' "$park_target"
    printf 'CSSL_SUBJECT=%q\n'     "$subject"
    printf 'CSSL_ISSUER=%q\n'      "$issuer"
    printf 'CSSL_EXPIRES=%q\n'     "$enddate"
    printf 'CSSL_APPLIED_COUNT=%q\n' "$applied"
    printf 'CSSL_APPLIED_DOMAINS=%q\n' "$(printf '%s\n' "${matched[@]%%|*}" | tr '\n' ' ')"
    printf 'CSSL_FAILED_DOMAINS=%q\n' "${failed[*]:-}"
    printf 'CSSL_SANS=%q\n'        "$(echo "$cert_sans" | tr '\n' ' ')"
} > "$state_file"
chmod 600 "$state_file"

# Clean up temp paste files if used
if [[ "$CSSL_INPUT_MODE" == "paste" ]]; then
    [[ -f "$CSSL_CERT_PATH" && "$CSSL_CERT_PATH" == /tmp/cssl-cert.* ]] && shred -u "$CSSL_CERT_PATH" 2>/dev/null
    [[ -f "$CSSL_KEY_PATH"  && "$CSSL_KEY_PATH"  == /tmp/cssl-key.*  ]] && shred -u "$CSSL_KEY_PATH"  2>/dev/null
fi

################################################################################
# Summary
################################################################################

sre_header "Custom SSL Install Complete"

sre_success "Parked at:   $park_target"
sre_info    "Coverage:    $(echo "$cert_sans" | tr '\n' ' ')"
sre_info    "Expires:     $enddate"
echo ""

if [[ "$applied" -gt 0 ]]; then
    sre_success "Applied to $applied vhost(s):"
    for m in "${matched[@]}"; do
        d="${m%%|*}"
        # Skip ones that failed
        skip=0
        for f in "${failed[@]}"; do
            [[ "$f" == "$d" ]] && { skip=1; break; }
        done
        [[ "$skip" -eq 0 ]] && sre_info "  ✓ https://$d"
    done
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    sre_error "Failed (${#failed[@]}):"
    for d in "${failed[@]}"; do
        sre_error "  ✗ $d"
    done
    sre_error "Check logs and re-run:"
    sre_error "  sudo bash ${SRE_SCRIPTS_DIR}/ssl/11-ssl.sh --domain <d> --wildcard-dir ${CSSL_PARK_DIR}"
fi

echo ""
sre_info "State file:  $state_file"
sre_info ""
sre_info "Future vhosts in step 11 will auto-detect this cert via ${CSSL_PARK_DIR}/."

recommend_next_step "$CURRENT_STEP"
