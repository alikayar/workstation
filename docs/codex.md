# Codex

Codex is managed as a user-level CLI with repository-owned configuration and rules.

- **Official docs:** https://developers.openai.com/codex/
- **Source repository:** https://github.com/openai/codex
- **Managed by:** `codex`
- **Binary:** `~/.local/bin/codex`
- **Configuration source:** `dotfiles/codex/config.toml`
- **Rules source:** `dotfiles/codex/rules/default.rules`
- **Instructions source:** `dotfiles/codex/AGENTS.md`

The role installs a missing CLI but does not upgrade or downgrade an existing executable. See [version policy](agent-environment.md#version-policy).

## Design decisions

> **Security warning:** This configuration intentionally gives Codex full
> access inside the development VM. Do not copy it to a host environment or a
> machine containing sensitive data without reviewing the sandbox and approval
> policy first.

- `config.toml` is rendered into `~/.codex/config.toml`, with the managed Chrome executable path and pinned marketplace registration.
- `AGENTS.md` is copied to `~/.codex/AGENTS.md`.
- Command rules are copied to `~/.codex/rules/default.rules`.
- Credentials and authentication state remain outside the repository.
- Context7 uses the remote Streamable HTTP endpoint for version-specific, public library documentation; it requires no additional local server. A free API key can increase rate limits but is not stored in this repository.
- Only query Context7 for relevant library/framework API facts; confirm installed versions in the current project first and prioritize official sources where results disagree.
- Serena is enabled for semantic navigation; Chrome DevTools, Grafana and PostgreSQL are configured as opt-in MCPs. Credentials are not stored here. See [MCP integrations](mcp.md).
- MCP actions requiring approval remain subject to the configured approval policy.

The rules file is a safety policy for potentially destructive operations. It is reviewed as configuration, not treated as a replacement for checking the working tree and reviewing diffs.

## MCP integrations

See the [MCP integrations guide](mcp.md) for runtime requirements, optional activation and credential handling. Use the native CLI and Docker tooling for routine operations rather than duplicating those capabilities through MCP.

## draw.io plugin

The Codex role installs the official `drawio@drawio` plugin in the workstation user's `~/.codex/` directory. Its marketplace commit and plugin version are pinned in the role defaults. The plugin adds the `drawio` skill. The managed configuration also enables the separate official `@drawio/mcp@1.10.1` Tool Server for references, shape lookup and browser editor operations. Neither requires an API key. Start a new Codex session after installing them.

To apply only the plugin installation without replacing other Codex settings:

```sh
ansible-playbook ansible/site.yml --tags codex_plugins
codex plugin list --marketplace drawio --json
```

Ask for an editable `.drawio` source or a browser URL. PNG/SVG/PDF export through the plugin requires draw.io Desktop inside the Ubuntu environment; this role does not install it. The online editor can export images manually. Keep project-owned `.drawio` sources alongside exported images even when the upstream skill suggests removing intermediate sources. Project instructions own the palette, fonts and spacing; the file format alone does not establish a design system.

On a pin upgrade, review the marketplace revision and version together. The role refuses an existing marketplace at a different commit rather than silently replacing it. Use Codex's marketplace management commands to reconcile it deliberately.

Upstream: [official draw.io Codex plugin](https://github.com/jgraph/drawio-mcp/tree/main/plugins/codex/drawio), [draw.io integrations](https://www.drawio.com/mcp/).

## Context7 authentication

The remote endpoint is usable without storing credentials in Git. Anonymous access may have lower limits. If authenticated access is needed, use the provider's documented OAuth/API-key procedure and keep credentials in a user-local secret store or environment, never in a tracked file. The managed `config.toml` is replaced when Ansible runs; do not manually paste long-lived tokens into that managed file. This workstation does not automatically provision an authenticated Context7 account.

## Browser runtime

The `agent_tools` role provides the native agent-browser CLI and managed Chrome for task-scoped browser work. See [browser automation](agent-environment.md#browser-automation) for session ownership and cleanup. Application repositories own any Playwright Test dependency, browser versions and CI setup they require; Workstation does not provision a Playwright MCP server or a shared E2E test runner.

## Development policy

The managed AGENTS.md prohibits creating or modifying test files and running validation commands without an explicit user request. This covers lint, format, tests, type checking, builds, syntax checks, browser verification, benchmarks and security scans, including indirect aggregate commands and hooks. During development, continue implementation through source inspection without repeatedly offering or requesting checks.

A commit/push request authorizes the Git action, not validation. Briefly identify relevant checks that have not been run, then carry out the authorized action. Existing CI stays in place. If a hook requires checks, explain the blocker and request direction instead of silently executing or bypassing it.
