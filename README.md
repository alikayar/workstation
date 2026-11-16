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

## Get started

| Starting point | Guide |
| --- | --- |
| Existing Ubuntu VM or physical Ubuntu system | [Install the Ubuntu environment](docs/getting-started.md) |
| Windows 11 Pro with Hyper-V | [Install wvm](docs/windows.md#the-wvm-command), then [create a VM](docs/hyperv.md#create-a-vm) |
| WSL 2 Ubuntu | [Prepare WSL and choose Docker integration](docs/getting-started.md#wsl-2) |
| Environment already installed | [Connect Codex or VS Code over SSH](docs/host.md) |

The environment includes managed language runtimes, shell and CLI tools, Docker, Codex, Graphify, and Chrome with Chrome DevTools MCP. See the [tool inventory](docs/tools.md) for the full list and [documentation home](docs/index.md) for daily workflows, maintenance and verification.

**Before installing:** the Ubuntu baseline changes SSH/firewall policy, gives VM Codex full filesystem access, and grants root-equivalent authority through the default Docker group. Review [installation scope](docs/getting-started.md#choose-the-installation-scope) and [security boundaries](docs/security.md).

## License

[MIT](LICENSE).
