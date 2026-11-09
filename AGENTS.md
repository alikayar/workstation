# Workstation maintenance

This repository provisions an Ubuntu VM/WSL development environment. Run Ansible inside Ubuntu; Windows scripts run on the Windows host. Applying provisioning is an environment change, not a prerequisite for ordinary coding. Use the existing VM: preserve ownership records, disks and recovery payloads; never turn a resume failure into a rebuild or generalize a development VM into an image.

## Make a change

- Read Git status/diff, affected sources and project instructions. Preserve unrelated work. Follow existing defaults/tasks/templates and trace changes through installed entry points and docs; prefer the smallest complete solution.
- Keep provisioning repeatable and preserve unrelated user configuration. Inspect command resolution before installing a supposedly missing tool. Never inspect credentials, authentication state or shell history.
- Managed Zsh loads mise shims noninteractively. In another shell/service, use `~/.local/bin/mise exec -- COMMAND` from the project directory; do not source `.zshrc` to fix PATH.
- Run only explicitly authorized checks and provisioning scope. Do not add/edit tests, run aggregate checks or bypass hooks without authorization. Commit, push and publication require authorization. Report source review, applied provisioning and executed verification separately.

## Owners and guides

| Area | Source and guide |
| --- | --- |
| Ubuntu provisioning | `ansible/`; [setup](docs/getting-started.md) |
| Installed agent defaults | `dotfiles/codex/`; [Codex](docs/codex.md), [MCP](docs/mcp.md) |
| Shell and runtimes | `dotfiles/`, Ansible roles; [shell](docs/shell.md), [tools](docs/tools.md) |
| Windows setup and VM lifecycle | `host/windows/`; [source ownership](docs/windows.md#source-layout), [recovery](docs/windows.md#recovery-compatibility-and-validation) |
| Connections and process lifetime | [Host guide](docs/host.md); record owned services, ports, logs and stop commands |
| Browser, conversion and repository indexing | `agent_tools` role; [agent environment](docs/agent-environment.md) |

Keep this file to maintenance rules and routing. `dotfiles/codex/AGENTS.md` supplies portable VM instructions; existing `docs/` pages own detailed procedures. Keep one maintained guide per topic. Model defaults belong in config, command safeguards in rules; neither configuration nor an installed MCP proves a tool is exposed in the current chat. Do not add blanket approval rules or assume changed defaults affect an existing session.
