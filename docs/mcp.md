# MCP integrations

MCP configuration lives in `dotfiles/codex/config.toml` and is installed as `~/.codex/config.toml` by the `codex` Ansible role, together with the pinned marketplace registration from the role defaults. Chrome DevTools MCP uses a pinned npm package launched through `npx` on demand. Context7 is a hosted endpoint. Model defaults, instruction ownership and command rules are covered by [Codex configuration](codex.md).

| MCP | Default | Intended use | Prerequisites |
| --- | --- | --- | --- |
| Context7 | Enabled | Public, version-specific library documentation | Internet; API key not necessary for anonymous access |
| Chrome DevTools | Enabled with managed browser | Performance traces, network and browser debugging | `npx` and Chrome installed **inside Ubuntu** |

## Apply and inspect

```sh
ansible-playbook ansible/site.yml --tags codex --ask-become-pass
codex mcp list
```

Restart Codex after updating the configuration. Listing an MCP does not verify its startup, connectivity or credentials. Check `/mcp` in a Codex session before relying on it. The Ansible role copies the managed configuration on subsequent runs; do not manually store credentials in that tracked file.

When using the desktop app with an SSH-connected VM, this repository manages the VM-side files. Treat the current chat's exposed tools as the available set and distinguish them from the configured server list.

For authorized VM-local web verification, use Chrome DevTools MCP. The [browser guide](browser.md) owns the browser setup, task isolation, supported audits and cleanup.

## draw.io skill plugin

Diagram authoring uses the separate draw.io skill plugin, not an MCP server. Installation, capabilities and marketplace-conflict recovery are maintained in the [Codex plugin guide](codex.md#drawio-plugin).

## Context7

Context7 uses the remote Streamable HTTP endpoint for public, version-specific library documentation; no local server or API key is required for anonymous access. Confirm the active project's installed versions before querying, and prefer official sources where results disagree.

Anonymous access may have lower limits. If authentication is needed, use the provider's documented OAuth/API-key procedure and keep credentials outside tracked files. Do not paste tokens into the managed configuration, which Ansible replaces. Workstation does not provision a Context7 account.

## Chrome DevTools

Enabled with the managed browser. See the [browser guide](browser.md) for the exact configuration, prerequisites, supported tools and task lifecycle. It uses the managed Chrome inside Ubuntu and does not attach to a personal/host browser.

## Project-specific integrations

Workstation manages Context7 and Chrome DevTools only. Database and observability integrations belong to the consuming project's own configuration and access policy. A project that needs another MCP owns its package/version, endpoint, least-privilege credentials and activation scope. Do not add environment-specific connections to the global workstation template. Managed Codex configuration replaces the user config on apply, so keep project-owned settings in their project's supported configuration layer rather than appending them to the generated file.

## Startup and availability problems

| Observation | Meaning and next step |
| --- | --- |
| Entry exists in config, tool absent from chat | The current client/session may not expose it. Inspect exposed tools and restart/reconnect rather than claiming it is usable |
| Local server executable missing | Check project-local command resolution and mise setup inside Ubuntu; a host-installed binary does not satisfy the VM prerequisite |
| `npx` cannot resolve the pinned package | The first launch can need package downloads. Review the package/runtime error; offline caches and package installation are separate from service connectivity |
| Authentication or endpoint failure | Check the private credential-loading mechanism and approved network scope without printing variables or reading authentication stores |

All managed server entries are non-required, so the agent/client can remain usable when a server fails. That does not convert a failed tool operation into a successful verification. Preserve a safe startup error and report which capability is unavailable.

## Policy and maintenance

Code discovery uses the local Graphify CLI and direct source search; see the [decision and measurements](code-discovery.md).

- Existing project/user restrictions on browser verification, queries, validations, and remote operations still apply. A configured MCP is not permission to inspect customer or production data.
- Prefer existing `rg`, `ast-grep`, `gh`, Docker CLI and shell over redundant filesystem, GitHub or Docker MCP servers.
- Review pinned package upgrades deliberately instead of using floating `latest` tags.

Upstream sources: [Chrome DevTools](https://github.com/ChromeDevTools/chrome-devtools-mcp), [Codex configuration](https://developers.openai.com/codex/config-reference).
