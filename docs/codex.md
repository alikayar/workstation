# Codex configuration

The `codex` role installs a missing user-level CLI and manages its Ubuntu configuration, global instructions, command rules and draw.io plugin. It leaves existing CLI versions unchanged; see the [version policy](agent-environment.md#version-policy). Windows host configuration has a separate [setup procedure](windows.md#codex-host-setup).

> **Security warning:** The Ubuntu configuration gives Codex full filesystem access inside the development VM. Review its sandbox and approval policy before applying it to a host or a machine containing sensitive data.

## Managed files and ownership

| Source | Installed destination | Purpose |
| --- | --- | --- |
| [config.toml](../dotfiles/codex/config.toml) | `~/.codex/config.toml` | Model defaults, execution permissions, enabled plugins and MCP configuration; rendered with the managed Chrome path and marketplace registration. |
| [AGENTS.md](../dotfiles/codex/AGENTS.md) | `~/.codex/AGENTS.md` | Portable development instructions and tool entry points. |
| [default.rules](../dotfiles/codex/rules/default.rules) | `~/.codex/rules/default.rules` | Command safeguards for potentially destructive operations. |

The role owns these complete files. Review [configuration ownership and source overrides](getting-started.md#configuration-ownership) before applying over personal settings. Credentials and authentication state are not provisioned. Workstation does not install or update personal/shared engineering skills.

Model and reasoning defaults live in the configuration source. Desktop selections, existing conversations and project configuration can override them. Command rules complement working-tree and diff review; they do not replace it. The installed instructions require explicit authorization for validation and external actions; see [verification levels](verification.md) for Workstation's checks.

## Apply configuration

From the repository root inside Ubuntu:

```sh
ansible-playbook ansible/site.yml --tags codex --ask-become-pass
```

Use `--tags codex_config` for configuration only. The full `codex` tag also manages the CLI bootstrap, global instructions, rules and plugin. Start a new Codex session afterward. Applying configuration does not sign in, verify MCP connectivity or run application checks.

See [MCP integrations](mcp.md) for the server catalog, optional activation and credential handling. Use [browser automation](agent-environment.md#browser-automation) for the native browser lifecycle. Application repositories own any Playwright Test dependency and E2E runner they need.

## draw.io plugin

The role installs the official `drawio@drawio` skill plugin. Its marketplace revision and plugin version are pinned in the [role defaults](../ansible/roles/codex/defaults/main.yml). No draw.io MCP server is configured: the reviewed `@drawio/mcp@1.10.1` release downloads mutable CDN JavaScript and evaluates it without a pinned hash or signature. MCP shape lookup, routing and layout tools are unavailable.

To apply only the plugin installation without replacing other Codex settings:

```sh
ansible-playbook ansible/site.yml --tags codex_plugins
codex plugin list --marketplace drawio --json
```

Start a new session after installation. Request an editable `.drawio` source or browser URL. Plugin PNG/SVG/PDF export requires draw.io Desktop inside Ubuntu, which this role does not install; the online editor can export manually. Keep editable project sources alongside exports and follow the project's palette, typography and spacing rules.

### Recover a marketplace conflict

On upgrades, review the marketplace revision and plugin version together. The role refuses an existing checkout at a different revision. A plugin-only apply can also report `already added from a different source`; an empty `marketplace list` result does not prove that the registration is absent.

After reviewing and authorizing replacement of the conflicting registration:

```sh
codex plugin marketplace remove drawio --json
ansible-playbook ansible/site.yml --tags codex --ask-become-pass
```

The full role restores the configured source and revision. Do not delete the plugin cache as a recovery shortcut.

Upstream: [Codex documentation](https://developers.openai.com/codex/), [source](https://github.com/openai/codex), [official draw.io plugin](https://github.com/jgraph/drawio-mcp/tree/main/plugins/codex/drawio).
