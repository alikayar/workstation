<h1 align="center"><img src="docs/assets/workstation-logo.png" alt="Workstation" width="680"></h1>

<p align="center"><strong>A rebuildable Ubuntu environment for development.</strong></p>

<p align="center">
  <a href="https://github.com/alikayar/workstation/actions/workflows/ci.yml"><img src="https://github.com/alikayar/workstation/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT license"></a>
  <a href="docs/getting-started.md"><img src="https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&amp;logoColor=white" alt="Ubuntu 24.04 and 26.04"></a>
  <a href="docs/windows.md"><img src="https://img.shields.io/badge/Windows%2011%20Pro-Hyper--V-0078D4" alt="Windows 11 Pro with Hyper-V"></a>
  <a href="docs/getting-started.md"><img src="https://img.shields.io/badge/Provisioning-Ansible-EE0000?logo=ansible&amp;logoColor=white" alt="Ansible provisioning"></a>
</p>

Run project code, dependencies and coding agents inside a dedicated Ubuntu environment. Connect from the host over SSH, and use Ansible to recreate the development setup. Optional Windows tooling builds reusable Hyper-V images and manages independent guest clones.

**[Documentation home](docs/index.md)** · [Architecture](docs/architecture.md) · [Security boundaries](docs/security.md) · [Verification](docs/verification.md)

## Choose a setup path

| Starting point | Guide |
| --- | --- |
| Existing Ubuntu VM or physical Ubuntu system | [Install the Ubuntu environment](docs/getting-started.md) |
| Windows 11 Pro with Hyper-V | [Install wvm and create a VM](docs/windows.md#the-wvm-command) |
| WSL 2 Ubuntu | [Choose systemd/Docker integration](docs/getting-started.md#wsl-2) |
| Environment already installed | [Connect Codex or VS Code over SSH and preview an app](docs/host.md) |

Use a non-root development account. Run Ansible inside Ubuntu; run wvm on Windows. Direct untagged Ansible applies install the default baseline without per-package questions. The Windows Ubuntu workflow asks for language, development-tool and helper-tool selections, accepts `hepsi`, and requires final scope confirmation. See [installation scope](docs/getting-started.md#choose-the-installation-scope).

## What is included

The baseline provides common installer prerequisites and native dependency build tools for selected languages; key-only SSH/UFW/AppArmor/security updates; Zsh/Starship and navigation tools; mise-managed Node.js, Python, Go, Bun and PHP; Git and shared CLIs; read-only Ubuntu doctor and UUID-owned systemd task services; Docker Engine; Codex configuration; Graphify; and x86_64 Chrome with Chrome DevTools MCP. Project manifests own application dependencies and runtime overrides. Shared engineering skills are managed separately.

The [tool inventory](docs/tools.md) maps tools to their provisioning owners. [Ubuntu operations](docs/operations.md) covers diagnosis, service RAM/CPU/runtime limits, logs and exact cleanup. The [browser guide](docs/browser.md) owns interaction, screenshots, audits and cleanup. The [maintenance guide](docs/maintenance.md) explains version pins, Renovate proposals and rollout.

## Permissions and isolation

The default Ubuntu Codex configuration gives full filesystem access inside the environment. Default Docker-group membership grants root-equivalent guest authority. Managed Hyper-V Ubuntu guests receive host-side IP filtering with documented limits; other installation paths need their own network isolation. Host applications and remote extension bridges retain their own permissions. Read [security boundaries](docs/security.md) before running unfamiliar code or applying the baseline to a sensitive machine.

## Compatibility and evidence

Ubuntu 24.04/26.04 LTS are the CI targets; x86_64 and aarch64 pass platform validation, with the managed browser available only on x86_64. Source checks and isolated Linux regressions run on relevant PRs/pushes. Manual CI is configured for full Ubuntu installs/idempotency, optional browser smoke/battle, and Windows PowerShell 5.1/7 contracts. Choose `scope=windows` for the Windows matrix alone. Configured jobs are distinct from completed verification; Windows contracts and current clean-install evidence remain pending. See [actual results and limits](docs/verification.md).

## License

[MIT](LICENSE).
