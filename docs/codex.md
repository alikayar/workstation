# Codex

Codex is managed as a user-level CLI with repository-owned configuration and
rules.

- **Official docs:** https://developers.openai.com/codex/
- **Source repository:** https://github.com/openai/codex
- **Managed by:** `codex`
- **Binary:** `~/.local/bin/codex`
- **Configuration source:** `dotfiles/codex/config.toml`
- **Rules source:** `dotfiles/codex/rules/default.rules`
- **Instructions source:** `dotfiles/codex/AGENTS.md`

## Design decisions

> **Security warning:** This configuration intentionally gives Codex full
> access inside the development VM. Do not copy it to a host environment or a
> machine containing sensitive data without reviewing the sandbox and approval
> policy first.

- `config.toml` is copied to `~/.codex/config.toml`.
- `AGENTS.md` is copied to `~/.codex/AGENTS.md`.
- Command rules are copied to `~/.codex/rules/default.rules`.
- Credentials and authentication state remain outside the repository.
- The Playwright MCP endpoint is configured as a local server at
  `http://localhost:8931/mcp`; Codex configuration does not start that server.
- MCP actions requiring approval remain subject to the configured approval
  policy.

The rules file is a safety policy for potentially destructive operations. It
is reviewed as configuration, not treated as a replacement for checking the
working tree and reviewing diffs.
