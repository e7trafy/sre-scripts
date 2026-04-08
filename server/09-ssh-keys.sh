#!/bin/bash
################################################################################
# SRE Helpers - Step 9: SSH Key Setup (Optional)
# Generates or imports SSH key pairs and copies public keys to remote servers.
# Useful before running migration (step 9) to enable passwordless SSH.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=9

SSH_USER=""
SSH_KEY_TYPE="ed25519"
SSH_KEY_BITS=""
SSH_KEY_COMMENT=""
SSH_KEY_PATH=""
SSH_REMOTE_HOST=""
SSH_REMOTE_USER=""
SSH_REMOTE_PORT="22"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 9: SSH Key Setup (Optional)
  Generate or import SSH key pairs for this server and optionally
  copy the public key to remote servers for passwordless access.

  Modes:
    generate    - Create a new SSH key pair
    import      - Import an existing private key
    copy        - Copy public key to a remote server
    show        - Display the current public key
    list        - List all SSH keys for a user

Options:
  --user <user>          Local user for the key (default: current user)
  --type <type>          Key type: ed25519, rsa (default: ed25519)
  --bits <bits>          Key bits for RSA (default: 4096)
  --remote-host <host>   Remote server to copy key to
  --remote-user <user>   User on remote server (default: root)
  --remote-port <port>   SSH port on remote server (default: 22)
  --dry-run              Print planned actions without executing
  --yes                  Accept defaults without prompting
  --help                 Show this help

Examples:
  sudo bash $0
  sudo bash $0 --user www-data
  sudo bash $0 --remote-host 1.2.3.4 --remote-user root
  sudo bash $0 --user root --type rsa --bits 4096
EOF
}

# Parse script-specific args
_raw_args=("$@")
sre_parse_args "09-ssh-keys.sh" "${_raw_args[@]}"

_i=0
while [[ $_i -lt ${#_raw_args[@]} ]]; do
    case "${_raw_args[$_i]}" in
        --user)         ((_i++)); SSH_USER="${_raw_args[$_i]:-}" ;;
        --type)         ((_i++)); SSH_KEY_TYPE="${_raw_args[$_i]:-ed25519}" ;;
        --bits)         ((_i++)); SSH_KEY_BITS="${_raw_args[$_i]:-}" ;;
        --remote-host)  ((_i++)); SSH_REMOTE_HOST="${_raw_args[$_i]:-}" ;;
        --remote-user)  ((_i++)); SSH_REMOTE_USER="${_raw_args[$_i]:-}" ;;
        --remote-port)  ((_i++)); SSH_REMOTE_PORT="${_raw_args[$_i]:-22}" ;;
    esac
    ((_i++))
done

require_root

sre_header "Step 9: SSH Key Setup"

################################################################################
# Select mode
################################################################################

mode=$(prompt_choice "What would you like to do?" "generate" "import" "copy" "show" "list")

################################################################################
# Select user
################################################################################

if [[ -z "$SSH_USER" ]]; then
    SSH_USER=$(prompt_input "Local user for SSH key" "root")
fi

# Determine home directory for the user (getent is reliable, eval is not)
user_home=$(getent passwd "$SSH_USER" 2>/dev/null | cut -d: -f6 || true)
if [[ -z "$user_home" ]]; then
    # Fallback for users not in /etc/passwd (e.g. LDAP) or www-data with non-standard home
    user_home=$(eval echo "~${SSH_USER}" 2>/dev/null || echo "/root")
fi
# www-data on Debian/Ubuntu has home /var/www but .ssh should still be there
[[ "$SSH_USER" == "www-data" && "$user_home" == "/var/www" ]] && user_home="/var/www"

ssh_dir="${user_home}/.ssh"
sre_info "User: $SSH_USER"
sre_info "SSH directory: $ssh_dir"

################################################################################
# Ensure .ssh directory exists
################################################################################

if [[ ! -d "$ssh_dir" ]]; then
    if [[ "$SRE_DRY_RUN" != "true" ]]; then
        mkdir -p "$ssh_dir"
        chown "${SSH_USER}:$(id -gn "$SSH_USER" 2>/dev/null || echo "$SSH_USER")" "$ssh_dir"
        chmod 700 "$ssh_dir"
        sre_success "Created $ssh_dir"
    else
        sre_info "[DRY-RUN] Would create $ssh_dir"
    fi
fi

################################################################################
# Execute selected mode
################################################################################

case "$mode" in

    ########################################################################
    generate)
    ########################################################################
        sre_header "Generate SSH Key Pair"

        # Key type
        if [[ "$SSH_KEY_TYPE" != "ed25519" && "$SSH_KEY_TYPE" != "rsa" ]]; then
            SSH_KEY_TYPE=$(prompt_choice "Key type:" "ed25519" "rsa")
        fi

        # Key path
        case "$SSH_KEY_TYPE" in
            ed25519) default_key_file="${ssh_dir}/id_ed25519" ;;
            rsa)     default_key_file="${ssh_dir}/id_rsa" ;;
        esac

        SSH_KEY_PATH=$(prompt_input "Key file path" "$default_key_file")

        # Check if key already exists
        if [[ -f "$SSH_KEY_PATH" ]]; then
            sre_warning "Key already exists: $SSH_KEY_PATH"
            if ! prompt_yesno "Overwrite existing key?" "no"; then
                sre_skipped "Key generation cancelled"

                # Offer to copy existing key instead
                if prompt_yesno "Copy existing public key to a remote server?" "yes"; then
                    mode="copy"
                else
                    recommend_next_step "$CURRENT_STEP"
                    exit 0
                fi
            fi
        fi

        if [[ "$mode" == "generate" ]]; then
            # Comment
            SSH_KEY_COMMENT=$(prompt_input "Key comment" "${SSH_USER}@$(hostname)")

            # Generate
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                key_args=(-t "$SSH_KEY_TYPE" -C "$SSH_KEY_COMMENT" -f "$SSH_KEY_PATH" -N "")
                if [[ "$SSH_KEY_TYPE" == "rsa" ]]; then
                    SSH_KEY_BITS=$(prompt_input "RSA key bits" "4096")
                    key_args+=(-b "$SSH_KEY_BITS")
                fi

                ssh-keygen "${key_args[@]}"

                # Fix ownership
                chown "${SSH_USER}:$(id -gn "$SSH_USER" 2>/dev/null || echo "$SSH_USER")" "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
                chmod 600 "$SSH_KEY_PATH"
                chmod 644 "${SSH_KEY_PATH}.pub"

                sre_success "Key pair generated:"
                sre_info "  Private: $SSH_KEY_PATH"
                sre_info "  Public:  ${SSH_KEY_PATH}.pub"
                echo ""
                sre_info "Public key:"
                cat "${SSH_KEY_PATH}.pub"
                echo ""
            else
                sre_info "[DRY-RUN] Would generate $SSH_KEY_TYPE key at $SSH_KEY_PATH"
            fi

            # Offer to copy to remote
            if prompt_yesno "Copy public key to a remote server now?" "yes"; then
                mode="copy"
            fi
        fi
        ;;&  # Fall through to copy if mode was changed

    ########################################################################
    import)
    ########################################################################
        sre_header "Import SSH Private Key"

        sre_info "Paste your private key below."
        sre_info "When done, type 'EOF' on a new line and press Enter."
        echo ""

        key_content=""
        while IFS= read -r line; do
            [[ "$line" == "EOF" ]] && break
            key_content+="${line}"$'\n'
        done

        if [[ -z "$key_content" ]]; then
            sre_error "No key content provided."
            exit 1
        fi

        # Detect key type from content
        if echo "$key_content" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
            detected_type="ed25519/openssh"
            default_file="${ssh_dir}/id_ed25519"
        elif echo "$key_content" | grep -q "BEGIN RSA PRIVATE KEY"; then
            detected_type="rsa"
            default_file="${ssh_dir}/id_rsa"
        else
            detected_type="unknown"
            default_file="${ssh_dir}/id_imported"
        fi

        sre_info "Detected key type: $detected_type"
        SSH_KEY_PATH=$(prompt_input "Save private key to" "$default_file")

        if [[ -f "$SSH_KEY_PATH" ]]; then
            sre_warning "File already exists: $SSH_KEY_PATH"
            if ! prompt_yesno "Overwrite?" "no"; then
                sre_skipped "Import cancelled"
                recommend_next_step "$CURRENT_STEP"
                exit 0
            fi
            backup_config "$SSH_KEY_PATH"
        fi

        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            echo "$key_content" > "$SSH_KEY_PATH"
            chmod 600 "$SSH_KEY_PATH"
            chown "${SSH_USER}:$(id -gn "$SSH_USER" 2>/dev/null || echo "$SSH_USER")" "$SSH_KEY_PATH"
            sre_success "Private key saved: $SSH_KEY_PATH"

            # Generate public key from private
            if ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub" 2>/dev/null; then
                chmod 644 "${SSH_KEY_PATH}.pub"
                chown "${SSH_USER}:$(id -gn "$SSH_USER" 2>/dev/null || echo "$SSH_USER")" "${SSH_KEY_PATH}.pub"
                sre_success "Public key extracted: ${SSH_KEY_PATH}.pub"
                echo ""
                sre_info "Public key:"
                cat "${SSH_KEY_PATH}.pub"
                echo ""
            else
                sre_warning "Could not extract public key. The private key may be encrypted."
            fi
        else
            sre_info "[DRY-RUN] Would save private key to $SSH_KEY_PATH"
        fi

        if prompt_yesno "Copy public key to a remote server now?" "yes"; then
            mode="copy"
        fi
        ;;&  # Fall through to copy if mode was changed

    ########################################################################
    copy)
    ########################################################################
        sre_header "Copy Public Key to Remote Server"

        # Find public key
        if [[ -z "$SSH_KEY_PATH" ]]; then
            # Auto-detect existing keys
            pub_keys=()
            for kf in "${ssh_dir}"/id_*.pub; do
                [[ -f "$kf" ]] && pub_keys+=("$kf")
            done

            if [[ ${#pub_keys[@]} -eq 0 ]]; then
                sre_error "No public keys found in $ssh_dir"
                sre_error "Generate a key first: sudo bash $0 --user $SSH_USER"
                exit 1
            elif [[ ${#pub_keys[@]} -eq 1 ]]; then
                SSH_KEY_PATH="${pub_keys[0]%.pub}"
                sre_info "Using key: ${SSH_KEY_PATH}.pub"
            else
                sre_info "Multiple keys found:"
                selected_pub=$(prompt_choice "Select public key:" "${pub_keys[@]}")
                SSH_KEY_PATH="${selected_pub%.pub}"
            fi
        fi

        pub_key_file="${SSH_KEY_PATH}.pub"
        if [[ ! -f "$pub_key_file" ]]; then
            sre_error "Public key not found: $pub_key_file"
            exit 1
        fi

        # Remote server details
        if [[ -z "$SSH_REMOTE_HOST" ]]; then
            SSH_REMOTE_HOST=$(prompt_input "Remote server IP or hostname" "")
            [[ -z "$SSH_REMOTE_HOST" ]] && { sre_error "Remote host is required."; exit 1; }
        fi
        if [[ -z "$SSH_REMOTE_USER" ]]; then
            SSH_REMOTE_USER=$(prompt_input "Remote user" "root")
        fi
        SSH_REMOTE_PORT=$(prompt_input "Remote SSH port" "$SSH_REMOTE_PORT")

        sre_info "Copying public key to ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}:${SSH_REMOTE_PORT}"
        sre_info "Key: $pub_key_file"

        if [[ "$SRE_DRY_RUN" != "true" ]]; then
            # Use ssh-copy-id, running as the target user
            if sudo -u "$SSH_USER" ssh-copy-id \
                -i "$pub_key_file" \
                -p "$SSH_REMOTE_PORT" \
                -o StrictHostKeyChecking=accept-new \
                "${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}" 2>&1; then
                sre_success "Public key copied to ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}"
            else
                sre_warning "ssh-copy-id failed. Trying manual method..."

                # Manual fallback: append to authorized_keys
                pub_key_content=$(cat "$pub_key_file")
                ssh -p "$SSH_REMOTE_PORT" "${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}" \
                    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pub_key_content}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

                if [[ $? -eq 0 ]]; then
                    sre_success "Public key copied (manual method)"
                else
                    sre_error "Failed to copy key. You may need to enter the password for the remote server."
                    sre_error "Try manually: ssh-copy-id -p ${SSH_REMOTE_PORT} ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}"
                    exit 1
                fi
            fi

            # Test the connection
            sre_info "Testing passwordless connection..."
            if sudo -u "$SSH_USER" ssh -o PasswordAuthentication=no -o BatchMode=yes \
                -p "$SSH_REMOTE_PORT" "${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}" "echo OK" &>/dev/null; then
                sre_success "Passwordless SSH connection verified!"
            else
                sre_warning "Passwordless connection test failed."
                sre_warning "The key was copied but the remote server may require additional config."
                sre_info "Check: /etc/ssh/sshd_config on the remote server"
                sre_info "  PubkeyAuthentication yes"
                sre_info "  AuthorizedKeysFile .ssh/authorized_keys"
            fi

            # Offer to copy to another server
            while prompt_yesno "Copy this key to another remote server?" "no"; do
                SSH_REMOTE_HOST=$(prompt_input "Remote server IP or hostname" "")
                [[ -z "$SSH_REMOTE_HOST" ]] && break
                SSH_REMOTE_USER=$(prompt_input "Remote user" "root")
                SSH_REMOTE_PORT=$(prompt_input "Remote SSH port" "22")

                sudo -u "$SSH_USER" ssh-copy-id \
                    -i "$pub_key_file" \
                    -p "$SSH_REMOTE_PORT" \
                    -o StrictHostKeyChecking=accept-new \
                    "${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}" 2>&1 \
                    && sre_success "Key copied to ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}" \
                    || sre_warning "Failed to copy to ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}"
            done
        else
            sre_info "[DRY-RUN] Would copy $pub_key_file to ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST}:${SSH_REMOTE_PORT}"
        fi
        ;;

    ########################################################################
    show)
    ########################################################################
        sre_header "Show Public Key"

        pub_keys=()
        for kf in "${ssh_dir}"/id_*.pub; do
            [[ -f "$kf" ]] && pub_keys+=("$kf")
        done

        if [[ ${#pub_keys[@]} -eq 0 ]]; then
            sre_error "No public keys found in $ssh_dir"
            sre_error "Generate one first: sudo bash $0 --user $SSH_USER"
            exit 1
        fi

        for kf in "${pub_keys[@]}"; do
            echo ""
            sre_info "Key: $kf"
            sre_info "Type: $(awk '{print $1}' "$kf")"
            sre_info "Comment: $(awk '{print $3}' "$kf")"
            echo ""
            cat "$kf"
            echo ""
        done
        ;;

    ########################################################################
    list)
    ########################################################################
        sre_header "List SSH Keys for $SSH_USER"

        if [[ ! -d "$ssh_dir" ]]; then
            sre_info "No .ssh directory found for $SSH_USER"
            exit 0
        fi

        echo ""
        printf "%-40s %-10s %-6s %s\n" "FILE" "TYPE" "BITS" "COMMENT"
        printf "%-40s %-10s %-6s %s\n" "----" "----" "----" "-------"

        for kf in "${ssh_dir}"/id_*; do
            [[ -f "$kf" ]] || continue
            [[ "$kf" == *.pub ]] && continue  # Skip pub files, show private

            key_info=$(ssh-keygen -l -f "$kf" 2>/dev/null || echo "? ? ?")
            bits=$(echo "$key_info" | awk '{print $1}')
            type=$(echo "$key_info" | awk '{print $NF}' | tr -d '()')
            comment=$(echo "$key_info" | awk '{print $3}')
            has_pub="no"
            [[ -f "${kf}.pub" ]] && has_pub="yes"

            printf "%-40s %-10s %-6s %s\n" "$(basename "$kf")" "$type" "$bits" "$comment"
        done

        echo ""

        if [[ -f "${ssh_dir}/authorized_keys" ]]; then
            auth_count=$(grep -c "^ssh-" "${ssh_dir}/authorized_keys" 2>/dev/null || echo "0")
            sre_info "authorized_keys: $auth_count entries"
        fi

        if [[ -f "${ssh_dir}/known_hosts" ]]; then
            known_count=$(wc -l < "${ssh_dir}/known_hosts" 2>/dev/null || echo "0")
            sre_info "known_hosts: $known_count entries"
        fi
        ;;
esac

echo ""
recommend_next_step "$CURRENT_STEP"
