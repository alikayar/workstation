# Codex

Codex is managed as a user-level CLI with repository-owned configuration and rules.

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
- Codex starts Playwright MCP over stdio using `~/.local/bin/workstation-playwright`; the launcher runs the pinned upstream Docker image on demand.
- MCP actions requiring approval remain subject to the configured approval policy.

The rules file is a safety policy for potentially destructive operations. It is reviewed as configuration, not treated as a replacement for checking the working tree and reviewing diffs.

## Browser runtime

The Codex role installs the launcher and creates `~/.local/share/playwright-mcp` for screenshots and other artifacts. The image digest is maintained once in the role defaults and pins the upstream v0.0.83 multi-architecture manifest. First use downloads the image; later sessions reuse the local image. Docker access must already work for the workstation user, including refreshed group membership after installing native Docker. Docker Desktop WSL integration can supply the same Docker CLI when the native Docker role is skipped.

The container uses headless Chromium, an isolated browser session and the host network so applications running in the same Ubuntu/WSL environment remain reachable through localhost. Only the artifact directory is mounted, with the invoking user's UID/GID; projects and credentials are not mounted. Host files needed for a browser upload must be deliberately placed in that artifact directory first. Browser state is disposable while exported artifacts remain on the host.

No persistent HTTP listener on port 8931 or additional systemd service is needed. Connecting the tool does not authorize browser verification: use it only when the user explicitly asks under the managed development policy.

## Development policy

The managed AGENTS.md prohibits creating or modifying test files and running validation commands without an explicit user request. This covers lint, format, tests, type checking, builds, syntax checks, browser verification, benchmarks and security scans, including indirect aggregate commands and hooks. During development, continue implementation through source inspection without repeatedly offering or requesting checks.

A commit/push request authorizes the Git action, not validation. Briefly identify relevant checks that have not been run, then carry out the authorized action. Existing CI stays in place. If a hook requires checks, explain the blocker and request direction instead of silently executing or bypassing it.
