#!/bin/bash
################################################################################
# SRE Helpers - Step 21: Claude Code (agents, skills, MCPs)
# Installs the Claude Code CLI and plants the sre-helpers-vendored bundle
# (agents, skills, settings, MCP server list) into a target user's ~/.claude/.
#
# Modes:
#   --mode server       Install via OS package manager (dnf/apt). Default user: root.
#                       Suits headless server use (SSH into the box + `claude`).
#   --mode workstation  Install Node.js via nvm under the target user, then
#                       npm i -g @anthropic-ai/claude-code. Default user: $SUDO_USER
#                       or $USER. Suits Mac/Linux dev machines.
#
# Auth: `claude login` (OAuth). Installer NEVER touches API keys.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=21

CLAUDE_MODE=""
CLAUDE_USER=""
CLAUDE_ASSETS_DIR=""
CLAUDE_ADD_MCPS="true"

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 21: Claude Code (agents, skills, MCPs)
  Installs the Claude Code CLI and copies the sre-helpers bundle
  (agents, skills, settings.json, MCP server list) into a target
  user's ~/.claude/ directory.

  Authentication is handled separately: after this script finishes,
  run \`claude login\` as the target user (OAuth in the browser).

Options:
  --mode <server|workstation>   Install target profile (required)
                                  server      => Node.js via dnf/apt, target=root by default
                                  workstation => Node.js via nvm, target=\$SUDO_USER by default
  --user <username>             Target user to configure (defaults per --mode above)
  --no-mcp                      Skip planting the MCP servers.json reference
  --assets <path>               Override the assets/claude source dir
                                  (default: <repo>/assets/claude)
  --dry-run                     Print planned actions without executing
  --yes                         Accept defaults without prompting
  --config                      Override sre-helpers config file path
  --log                         Override sre-helpers log file path
  --help                        Show this help

Examples:
  # Rocky/Ubuntu server, configure root
  sudo bash $0 --mode server --yes

  # Rocky/Ubuntu server, configure a project user
  sudo bash $0 --mode server --user deploy

  # Developer laptop, configure the current user
  sudo bash $0 --mode workstation

  # Preview without changes
  sudo bash $0 --mode server --dry-run
EOF
}

################################################################################
# Argument parsing (script-specific)
################################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                shift
                CLAUDE_MODE="${1:?'--mode requires server|workstation'}"
                ;;
            --user)
                shift
                CLAUDE_USER="${1:?'--user requires a username'}"
                ;;
            --no-mcp)
                CLAUDE_ADD_MCPS="false"
                ;;
            --assets)
                shift
                CLAUDE_ASSETS_DIR="${1:?'--assets requires a path'}"
                ;;
            --dry-run) SRE_DRY_RUN="true" ;;
            --yes|-y)  SRE_YES="true" ;;
            --config)  shift; SRE_CONFIG_FILE="${1:?}" ;;
            --log)     shift; SRE_LOG_FILE="${1:?}" ;;
            --help|-h) sre_show_help; exit 0 ;;
            *)
                sre_error "Unknown option: $1"
                sre_error "Run with --help for usage"
                exit 2
                ;;
        esac
        shift
    done
}

################################################################################
# Resolve defaults
################################################################################

resolve_defaults() {
    if [[ -z "$CLAUDE_MODE" ]]; then
        if [[ "$SRE_YES" == "true" ]]; then
            CLAUDE_MODE="server"
            sre_info "No --mode given, defaulting to 'server' (--yes was set)"
        else
            CLAUDE_MODE=$(prompt_choice "Which mode?" "server" "workstation")
        fi
    fi

    case "$CLAUDE_MODE" in
        server|workstation) ;;
        *)
            sre_error "Invalid --mode: '$CLAUDE_MODE' (expected server|workstation)"
            exit 2
            ;;
    esac

    if [[ -z "$CLAUDE_USER" ]]; then
        case "$CLAUDE_MODE" in
            server)
                CLAUDE_USER="root"
                ;;
            workstation)
                CLAUDE_USER="${SUDO_USER:-${USER:-root}}"
                ;;
        esac
    fi

    if ! id -u "$CLAUDE_USER" &>/dev/null; then
        sre_error "User '$CLAUDE_USER' does not exist on this system"
        exit 2
    fi

    if [[ -z "$CLAUDE_ASSETS_DIR" ]]; then
        CLAUDE_ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/assets/claude"
    fi

    if [[ ! -d "$CLAUDE_ASSETS_DIR" ]]; then
        sre_error "Assets directory not found: $CLAUDE_ASSETS_DIR"
        sre_error "Pull latest sre-helpers or pass --assets <path>"
        exit 2
    fi

    sre_info "Mode:   $CLAUDE_MODE"
    sre_info "User:   $CLAUDE_USER"
    sre_info "Assets: $CLAUDE_ASSETS_DIR"
}

################################################################################
# Resolve the target user's home + shell rc
################################################################################

user_home_of() {
    getent passwd "$1" | cut -d: -f6
}

user_shell_of() {
    getent passwd "$1" | cut -d: -f7
}

user_rc_of() {
    local user="$1"
    local shell
    shell=$(user_shell_of "$user")
    local home
    home=$(user_home_of "$user")
    case "$(basename "$shell")" in
        zsh)  echo "$home/.zshrc" ;;
        bash) echo "$home/.bashrc" ;;
        *)    echo "$home/.profile" ;;
    esac
}

run_as_user() {
    local user="$1"
    shift
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would run as $user: $*"
        return 0
    fi
    if [[ "$user" == "root" ]]; then
        bash -lc "$*"
    else
        sudo -u "$user" -H bash -lc "$*"
    fi
}

################################################################################
# Node.js installation
################################################################################

install_node_server() {
    if command -v node &>/dev/null; then
        local nv
        nv=$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)
        if [[ "$nv" -ge 18 ]]; then
            sre_info "Node.js $(node -v) already installed"
            return 0
        fi
        sre_warning "Node.js $(node -v) is older than v18; upgrading"
    fi

    sre_info "Installing Node.js via OS package manager"

    case "$SRE_OS_FAMILY" in
        debian)
            if [[ "$SRE_DRY_RUN" == "true" ]]; then
                sre_info "[DRY-RUN] Would run NodeSource setup + apt install nodejs"
                return 0
            fi
            # NodeSource LTS
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
            ;;
        rhel)
            if [[ "$SRE_DRY_RUN" == "true" ]]; then
                sre_info "[DRY-RUN] Would run dnf module + dnf install nodejs"
                return 0
            fi
            dnf module reset -y nodejs || true
            dnf module enable -y nodejs:20
            dnf install -y nodejs
            ;;
        *)
            sre_error "Unsupported OS family for server mode: $SRE_OS_FAMILY"
            exit 3
            ;;
    esac

    sre_success "Node.js $(node -v 2>/dev/null || echo installed)"
}

install_node_workstation() {
    local home
    home=$(user_home_of "$CLAUDE_USER")
    local nvm_dir="$home/.nvm"

    if [[ -d "$nvm_dir" ]] && run_as_user "$CLAUDE_USER" "source '$nvm_dir/nvm.sh' && command -v node" &>/dev/null; then
        sre_info "nvm already installed for $CLAUDE_USER"
    else
        sre_info "Installing nvm for user $CLAUDE_USER"
        if [[ "$SRE_DRY_RUN" == "true" ]]; then
            sre_info "[DRY-RUN] Would install nvm + node 20 for $CLAUDE_USER"
            return 0
        fi
        run_as_user "$CLAUDE_USER" 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
    fi

    sre_info "Installing Node 20 LTS via nvm"
    run_as_user "$CLAUDE_USER" \
        "export NVM_DIR=\"$nvm_dir\" && source \"\$NVM_DIR/nvm.sh\" && nvm install --lts && nvm alias default 'lts/*'"

    sre_success "Node installed for $CLAUDE_USER via nvm"
}

################################################################################
# Claude Code CLI installation
################################################################################

install_claude_cli_server() {
    if command -v claude &>/dev/null; then
        sre_info "claude already installed: $(claude --version 2>/dev/null || echo present)"
        return 0
    fi
    sre_info "Installing @anthropic-ai/claude-code globally via npm"
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would: npm install -g @anthropic-ai/claude-code"
        return 0
    fi
    npm install -g @anthropic-ai/claude-code
    sre_success "claude CLI installed: $(claude --version 2>/dev/null || echo present)"
}

install_claude_cli_workstation() {
    local home
    home=$(user_home_of "$CLAUDE_USER")
    sre_info "Installing @anthropic-ai/claude-code for user $CLAUDE_USER via nvm's npm"
    run_as_user "$CLAUDE_USER" \
        "export NVM_DIR=\"$home/.nvm\" && source \"\$NVM_DIR/nvm.sh\" && npm install -g @anthropic-ai/claude-code"
    sre_success "claude CLI installed for $CLAUDE_USER"
}

################################################################################
# Plant the bundle
################################################################################

plant_bundle() {
    local home
    home=$(user_home_of "$CLAUDE_USER")
    local claude_dir="$home/.claude"

    sre_info "Planting bundle into $claude_dir"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would create $claude_dir/{agents,skills,mcp}"
        sre_info "[DRY-RUN] Would copy $CLAUDE_ASSETS_DIR/agents/*.md -> $claude_dir/agents/"
        sre_info "[DRY-RUN] Would copy $CLAUDE_ASSETS_DIR/skills/* -> $claude_dir/skills/"
        sre_info "[DRY-RUN] Would copy $CLAUDE_ASSETS_DIR/mcp/servers.json -> $claude_dir/mcp/"
        sre_info "[DRY-RUN] Would plant settings.json (or .example if already present)"
        return 0
    fi

    install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$claude_dir"
    install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$claude_dir/agents"
    install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$claude_dir/skills"
    install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$claude_dir/mcp"

    # Agents
    local a
    for a in "$CLAUDE_ASSETS_DIR"/agents/*.md; do
        [[ -e "$a" ]] || continue
        install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$a" "$claude_dir/agents/$(basename "$a")"
    done
    sre_success "Agents installed: $(ls "$claude_dir/agents" | wc -l) files"

    # Skills (each skill is a directory with SKILL.md)
    local s
    for s in "$CLAUDE_ASSETS_DIR"/skills/*/; do
        [[ -d "$s" ]] || continue
        local name
        name=$(basename "$s")
        install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$claude_dir/skills/$name"
        local f
        for f in "$s"*; do
            [[ -f "$f" ]] || continue
            install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$f" "$claude_dir/skills/$name/$(basename "$f")"
        done
    done
    sre_success "Skills installed: $(ls -d "$claude_dir"/skills/*/ 2>/dev/null | wc -l) dirs"

    # settings.json — don't overwrite an existing one
    if [[ -f "$claude_dir/settings.json" ]]; then
        install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" \
            "$CLAUDE_ASSETS_DIR/settings.json" "$claude_dir/settings.json.sre-helpers.example"
        sre_warning "Existing settings.json left in place. Reference: settings.json.sre-helpers.example"
    else
        install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" \
            "$CLAUDE_ASSETS_DIR/settings.json" "$claude_dir/settings.json"
        sre_success "Planted settings.json"
    fi

    # MCP reference list
    if [[ "$CLAUDE_ADD_MCPS" == "true" ]]; then
        install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" \
            "$CLAUDE_ASSETS_DIR/mcp/servers.json" "$claude_dir/mcp/servers.json"
        sre_success "Planted MCP reference: $claude_dir/mcp/servers.json"
    fi
}

################################################################################
# Wire the ANTHROPIC_ env var hint into the user's shell rc (informational only)
################################################################################

nudge_shell_rc() {
    local rc
    rc=$(user_rc_of "$CLAUDE_USER")
    local marker="# sre-helpers: claude code"

    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would add shell rc marker to $rc"
        return 0
    fi

    if [[ -f "$rc" ]] && grep -qF "$marker" "$rc" 2>/dev/null; then
        sre_info "Shell rc already has claude marker: $rc"
        return 0
    fi

    # Append (create rc if missing) — informational, does NOT set an API key
    {
        echo ""
        echo "$marker"
        echo "# Installed by sre-helpers step 21. Run 'claude login' once to authenticate (OAuth)."
        echo "# Bundle: ~/.claude/{agents,skills,mcp,settings.json}"
    } >> "$rc"

    chown "$CLAUDE_USER:$CLAUDE_USER" "$rc" 2>/dev/null || true
    sre_success "Added claude marker to $rc"
}

################################################################################
# Persist step-21 result in sre-helpers config
################################################################################

save_state() {
    if [[ "$SRE_DRY_RUN" == "true" ]]; then
        sre_info "[DRY-RUN] Would save state to $SRE_CONFIG_FILE"
        return 0
    fi
    config_init
    config_set "SRE_CLAUDE_INSTALLED" "true"
    config_set "SRE_CLAUDE_MODE" "$CLAUDE_MODE"
    config_set "SRE_CLAUDE_USER" "$CLAUDE_USER"
    config_set "SRE_CLAUDE_INSTALLED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
}

################################################################################
# Post-install next steps banner
################################################################################

print_next_steps() {
    local home
    home=$(user_home_of "$CLAUDE_USER")
    echo ""
    sre_header "Next steps"
    cat <<EOF
1. Authenticate (OAuth in browser):
     $( [[ "$CLAUDE_USER" == "root" ]] && echo "claude login" || echo "sudo -iu $CLAUDE_USER claude login" )

2. Verify the bundle:
     ls $home/.claude/agents/
     ls $home/.claude/skills/
     cat $home/.claude/mcp/servers.json

3. Wire the MCP servers you actually use. \`claude mcp add\` takes the full spec:

     # filesystem — no secrets, grants access to your \$HOME
     claude mcp add filesystem -- npx -y @modelcontextprotocol/server-filesystem "\$HOME"

     # github — requires a Personal Access Token (repo + read:org)
     claude mcp add github --env GITHUB_PERSONAL_ACCESS_TOKEN=<PAT> \\
         -- npx -y @modelcontextprotocol/server-github

     # clickup — requires personal API token + numeric team id
     claude mcp add clickup \\
         --env CLICKUP_API_KEY=<key> --env CLICKUP_TEAM_ID=<id> \\
         -- npx -y @hauptsache.net/clickup-mcp

     # microsoft 365 — requires an Azure app-registration client id
     claude mcp add microsoft365 --env MS365_MCP_CLIENT_ID=<client-id> \\
         -- npx -y @softeria/ms-365-mcp-server

   Reference: $home/.claude/mcp/servers.json

4. Try it:
     cd /some/project && claude

5. To re-run this installer for another user later:
     sudo bash $0 --mode $CLAUDE_MODE --user <other-user>
EOF
}

################################################################################
# Main
################################################################################

main() {
    sre_parse_args "21-claude-code.sh" "$@"
    parse_args "${SRE_EXTRA_ARGS[@]}"
    require_root
    detect_os
    resolve_defaults

    sre_header "Step 21: Claude Code — mode=$CLAUDE_MODE user=$CLAUDE_USER"

    if ! prompt_yesno "Proceed with install?" "yes"; then
        sre_warning "Aborted by user"
        exit 0
    fi

    case "$CLAUDE_MODE" in
        server)
            install_node_server
            install_claude_cli_server
            ;;
        workstation)
            install_node_workstation
            install_claude_cli_workstation
            ;;
    esac

    plant_bundle
    nudge_shell_rc
    save_state

    sre_success "Claude Code installed and bundle planted for $CLAUDE_USER"
    print_next_steps
    recommend_next_step "$CURRENT_STEP"
}

main "$@"
