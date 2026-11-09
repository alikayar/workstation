# MCP integrations

MCP configuration lives in `dotfiles/codex/config.toml` and is installed as `~/.codex/config.toml` by the `codex` Ansible role, together with the pinned marketplace registration from the role defaults. Local MCP package versions are pinned; the existing `uvx` and `npx` runtimes launch them as subprocesses on demand. Context7 is a hosted endpoint. Model defaults, instruction ownership and command rules are covered by [Codex configuration](codex.md).

| MCP | Default | Intended use | Prerequisites |
| --- | --- | --- | --- |
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

For authorized VM-local web verification, use the session-scoped agent-browser CLI and cleanup helper from the `agent_tools` role. Browser automation does not require an MCP server. See [browser automation](agent-environment.md#browser-automation).

## draw.io skill plugin

Diagram authoring uses the separate draw.io skill plugin, not an MCP server. Installation, capabilities and marketplace-conflict recovery are maintained in the [Codex plugin guide](codex.md#drawio-plugin).

## Context7

Context7 uses the remote Streamable HTTP endpoint for public, version-specific library documentation; no local server or API key is required for anonymous access. Confirm the active project's installed versions before querying, and prefer official sources where results disagree.

Anonymous access may have lower limits. If authentication is needed, use the provider's documented OAuth/API-key procedure and keep credentials outside tracked files. Do not paste tokens into the managed configuration, which Ansible replaces. Workstation does not provision a Context7 account.

## Serena

Serena runs `serena-agent==2.1.0` through `uvx` with `--context=codex --project-from-cwd`. Start Codex in the active project's Git checkout. For Go, make `gopls` available in the project environment. The first invocation may need to download the pinned package and language-server dependencies.

## Chrome DevTools

Enable this MCP explicitly when browser performance and memory profiling are requested. The `1.12.0` server launches an isolated, headless Chrome process using the executable path rendered from the managed Chrome directory. A Windows installation of Chrome does not automatically make Chrome available inside Ubuntu WSL.

Native flags disable usage statistics and automatic CrUX URL lookups. Diagnostics use the selected local browser; retrieving field data remains a separate requested action.

After installing the managed browser in Ubuntu, activate it for the session:

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
