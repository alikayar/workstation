# MCP integrations

MCP configuration lives in `dotfiles/codex/config.toml` and is installed as `~/.codex/config.toml` by the `codex` Ansible role, together with the pinned marketplace registration from the role defaults. Package versions are pinned; the existing `uvx` and `npx` runtimes launch the tools as subprocesses on demand.

| MCP | Default | Intended use | Prerequisites |
| --- | --- | --- | --- |
| Playwright | Enabled | Browser interaction and screenshots | Docker with the existing pinned Chromium image |
| Context7 | Enabled | Public, version-specific library documentation | Internet; API key not necessary for anonymous access |
| Serena | Enabled | Symbol and reference navigation | `uvx`; a Git checkout; applicable language servers |
| Chrome DevTools | Disabled | Performance traces, network and browser debugging | `npx` and Chrome installed **inside Ubuntu** |
| Grafana | Disabled | Log, metric and dashboard queries | Grafana endpoint and service-account token |
| PostgreSQL | Disabled | Database schema, restricted SQL and query plans | PostgreSQL connection URI, preferably read-only user |

## Apply and inspect

```sh
ansible-playbook ansible/site.yml --tags codex --ask-become-pass
codex mcp list
```

Restart Codex after updating the configuration. Listing an MCP does not verify its startup, connectivity or credentials. Check `/mcp` in a Codex session before relying on it. The Ansible role copies the managed configuration on subsequent runs; do not manually store credentials in that tracked file.

When using the desktop app with an SSH-connected VM, this repository manages the VM-side files. The CLI opt-in examples below start a new CLI session; they do not enable tools in an already running desktop chat. Treat the current chat's exposed tools as the available set and distinguish them from the configured server list.

The Playwright launcher creates a separate private `run-*` directory under `~/.local/share/playwright-mcp/` for each invocation. It prints the host path to stderr and mounts only that directory at `/output`; stdout remains the MCP transport. Keep the printed path with the task to locate screenshots and reports. Files remain after exit and require deliberate cleanup. This separates artifacts, not host-network ports or other application services.

For authorized VM-local web verification, the `agent_tools` role also provides the session-scoped agent-browser CLI and cleanup helper. It does not add another MCP server or replace the existing Playwright configuration. See [browser automation](agent-environment.md#browser-automation).

## Agent defaults

The managed default is `gpt-6.1-sol` with `medium` reasoning and low verbosity. The [model documentation](https://developers.openai.com/api/docs/models/gpt-6.1-sol) confirms that reasoning level is supported. This sets the VM configuration default; desktop model selection and existing conversations may override it. No context-window override is needed.

Global preferences live in `dotfiles/codex/AGENTS.md`; this repository's `AGENTS.md` explains workstation ownership and onboarding. Command safeguards live in `dotfiles/codex/rules/default.rules`. Keep these layers separate; repository instructions and the relevant Workstation tool guides provide the execution workflow. See the official [AGENTS.md guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md) and [command rules](https://learn.chatgpt.com/docs/agent-configuration/rules).

## draw.io skill plugin

The separate `drawio@drawio` skill plugin remains enabled for authoring diagram files. The draw.io MCP server is not installed or configured: the reviewed `@drawio/mcp@1.10.1` release downloads mutable CDN JavaScript and evaluates it without a pinned hash or signature. MCP shape lookup, routing and layout tools are unavailable. Keep editable sources in the project and apply its diagram style rules.

The full `codex` role manages the marketplace source and revision in the configuration; it refuses to update an existing marketplace checkout at a different revision. A plugin-only apply can report `already added from a different source` when another source is registered. After authorizing replacement, run `codex plugin marketplace remove drawio --json`, then reapply the `codex` role to register the source and revision pinned in its defaults. The `marketplace list` command can omit a conflicting registration, so an empty list is not proof that registration is absent. Do not delete the plugin cache to resolve this error.

## Serena

Serena runs `serena-agent==2.1.0` through `uvx` with `--context=codex --project-from-cwd`. Start Codex in the active project's Git checkout. For Go, make `gopls` available in the project environment. The first invocation may need to download the pinned package and language-server dependencies.

## Chrome DevTools

This is an explicit opt-in alternative to Playwright when browser performance and memory profiling are requested. The `1.12.0` server launches an isolated, headless Chrome process. A Windows installation of Chrome does not automatically make Chrome available inside Ubuntu WSL.

After providing Chrome in Ubuntu, activate it for the session:

```sh
codex -c 'mcp_servers.chrome_devtools.enabled=true'
```

This repo intentionally does not install a second browser by default.

## Grafana

Provide `GRAFANA_URL` and `GRAFANA_SERVICE_ACCOUNT_TOKEN` in the launching shell from a private credential manager. These values are forwarded by Codex via `env_vars`, **not** committed to Git. Use a least-privilege Viewer service account and private network/VPN for internal endpoints.

```sh
# Load GRAFANA_URL and GRAFANA_SERVICE_ACCOUNT_TOKEN privately first.
codex -c 'mcp_servers.grafana.enabled=true'
```

Grafana MCP runs `mcp-grafana==2.1.1` with `--disable-write`.

## PostgreSQL

Supply `DATABASE_URI` in the launching shell without committing or echoing it. Use a project-specific reader role restricted to `CONNECT`, `USAGE`, and appropriate `SELECT` permissions; prefer disposable/synthetic data and avoid exposing customer records.

```sh
# Load DATABASE_URI privately first.
codex -c 'mcp_servers.postgres.enabled=true'
```

`postgres-mcp==0.3.0` runs with `--access-mode=restricted` (read-only transactions, resource-limited). Read-only at MCP level is **not** a replacement for Postgres role-level privileges. Use the project's standard migration/SQL tooling for database writes, not this MCP.

## Policy and maintenance

- Existing project/user restrictions on browser verification, queries, validations, and remote operations still apply. A configured MCP is not permission to inspect customer or production data.
- Grafana/PostgreSQL remain disabled for ordinary sessions to avoid unnecessary startup and access to sensitive environments.
- Prefer existing `rg`, `ast-grep`, `gh`, Docker CLI and shell over redundant filesystem, GitHub or Docker MCP servers.
- Review pinned package upgrades deliberately instead of using floating `latest` tags.

Upstream sources: [Serena](https://oraios.github.io/serena/02-usage/030_clients), [Chrome DevTools](https://github.com/ChromeDevTools/chrome-devtools-mcp), [Grafana](https://grafana.com/docs/grafana/latest/developer-resources/mcp/), [Postgres MCP Pro](https://github.com/crystaldba/postgres-mcp), [Codex configuration](https://developers.openai.com/codex/config-reference).
