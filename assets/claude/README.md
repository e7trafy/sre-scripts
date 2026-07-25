# sre-helpers — Claude Code bundle

Files under this directory are copied verbatim into a target user's
`~/.claude/` directory by `scripts/setup/21-claude-code.sh`.

Layout after install (target user's home):

```
~/.claude/
├── agents/           # copied from assets/claude/agents/*.md
├── skills/           # copied from assets/claude/skills/*
├── settings.json     # merged from assets/claude/settings.json (not overwritten if exists)
└── mcp/servers.json  # reference list of MCP servers to add via `claude mcp add`
```

### Bundles included

1. **Code review** — `code-reviewer`, `refactoring-specialist`, `debugging-specialist`
2. **Security & cybersecurity** — `security-specialist`, `server-hardening-specialist`,
   `ssh-security-expert`, `firewall-specialist`, `certificate-manager`
3. **Development stack** — `laravel-expert`, `moodle-expert`, `web-server-specialist`,
   `database-admin`, `redis-memcached-expert`
4. **MCP servers** — GitHub, filesystem, ClickUp, MS365 (added via `claude mcp add`
   after `claude login`)

### Auth model

`claude login` (OAuth) — the installer does not touch API keys.
Run `claude login` once as the target user after the installer finishes.

### Modes

- `--mode server` — installs Node.js via the OS package manager (dnf/apt),
  installs `@anthropic-ai/claude-code` globally, provisions per-user config.
  Default user: `root`.
- `--mode workstation` — installs Node.js via nvm under the target user,
  installs `@anthropic-ai/claude-code` for that user, provisions config.
  Default user: the invoking user.
