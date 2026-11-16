# Workstation documentation

Workstation prepares an Ubuntu development environment and, optionally, a Windows Hyper-V host. Repositories, application processes and agent commands belong in Ubuntu; host applications connect over SSH. Read [architecture and ownership](architecture.md) for how the pieces fit together and [security boundaries](security.md) before choosing installation scope.

## Start here

| Starting point | Next action | Completion evidence |
| --- | --- | --- |
| Existing Ubuntu VM | [Prepare SSH](host.md#prepare-access-to-ubuntu), then [apply Ubuntu setup](getting-started.md) inside the VM | Ansible finishes; a new SSH session uses the intended user and shell |
| Windows 11 Pro, no VM yet | [Install wvm](windows.md#the-wvm-command), then [create Ubuntu](hyperv.md#create-a-vm) | Account setup completes, the host SSH alias works, and the selected development setup finishes |
| WSL 2 | Read [WSL prerequisites](getting-started.md#wsl-2), then choose native Docker or Desktop integration | The selected roles finish inside the intended distribution |
| Configured workstation | [Connect the app and open a VM project](host.md#prepare-the-vm-and-connect-the-app) | The selected project path and command execution are inside Ubuntu |
| Existing checkout needing an update | [Review and apply the changed scope](maintenance.md#update-an-existing-workstation) | The intended configuration is applied; separately authorized checks supply verification |

## Daily workflows

| Task | Maintained guide |
| --- | --- |
| SSH, remote projects, application tunnels and connection failures | [Host connections](host.md) |
| Diagnose the VM or manage a task-owned development server | [Ubuntu operations](operations.md) |
| Shell activation, navigation shortcuts and persistent terminals | [Shell](shell.md) |
| Project runtime versions, PHP and Composer | [Runtime management](mise.md) |
| Tool availability and provisioning owners | [Tool inventory](tools.md) |
| Graphify indexing and freshness | [Agent environment](agent-environment.md) |
| Chrome interaction, screenshots, audits, tracing and cleanup | [Browser workflow](browser.md) |
| Codex configuration ownership, instructions and draw.io plugin | [Codex](codex.md) |
| Managed MCP integrations and project-specific integration ownership | [MCP](mcp.md) |
| Host/remote editor settings and bundled static appearance | [VS Code](vscode.md) |
| Windows applications and wvm launcher | [Windows host setup](windows.md) |
| Hyper-V VM lifecycle, network policy, image stores and recovery | [Hyper-V management](hyperv.md) |

## Maintain and assess the system

| Question | Maintained guide |
| --- | --- |
| Which source owns a setting, and what will an apply replace? | [Architecture and ownership](architecture.md) |
| What protects the host, and what remains exposed? | [Security boundaries](security.md) |
| How are pins updated, reviewed and rolled out? | [Maintenance](maintenance.md) |
| Which tests exist, where do they run, and what has actually passed? | [Verification and evidence](verification.md) |
| Why Graphify plus source search instead of a default language server? | [Code-discovery decision](code-discovery.md) |
| How can the discovery comparison be reproduced? | [Benchmark runner](../benchmarks/code-discovery/README.md) |

Project repositories own their application dependencies, service commands and tests; shared engineering skills are managed separately.
