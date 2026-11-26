# Set up the Ubuntu environment

Run the commands in this guide **inside the Ubuntu environment** as your development user. After obtaining the checkout below, run Ansible from its repository root. If you have not connected yet, start with the [host connection guide](host.md). Ansible uses a local inventory: launching it on a host computer does not provision a remote VM. For WSL, complete the [WSL prerequisites](#wsl-2) before installing.

Workstation targets Ubuntu 24.04 and 26.04 LTS on a VM, physical machine or WSL 2. The machine needs internet access and a non-root user with `sudo` access. Roles support x86_64 and aarch64 assets; the full installation CI currently runs on x86_64 for both LTS releases. Other Ubuntu releases at least as new as 24.04 pass platform validation but are not CI targets. Other distributions and older Ubuntu releases are rejected before package changes.

## Install Ansible

Install Git, Ansible and the Debian support library once. Ubuntu 26.04 sudo prompt handling is explained in [sudo compatibility](operations.md#sudo-compatibility).

```bash
sudo apt-get update
sudo apt-get install --yes git ansible-core python3-debian sudo
```

## Obtain the checkout

For a new installation, clone inside the Ubuntu filesystem and enter the repository:

```sh
mkdir -p ~/projects
cd ~/projects
git clone https://github.com/alikayar/workstation.git
cd workstation
```

If the checkout already exists, enter it and inspect local changes instead of cloning over it. Use [the update procedure](maintenance.md#update-an-existing-workstation) when adopting newer source. All remaining Ansible commands in this guide run from this checkout; `ansible.cfg` selects its local inventory.

## Set your Git identity

Create the ignored local host variables file without replacing an existing one, then set the identity used by the managed `.gitconfig`:

```bash
cp -n ansible/host_vars/localhost.example.yml ansible/host_vars/localhost.yml
nano ansible/host_vars/localhost.yml
```

## Choose the installation scope

Direct Ansible and the Windows menu share the same role sources but select scope differently. Direct Ansible is noninteractive apart from sudo and defaults to all five languages; setting a runtime list does not disable Docker, Codex or other roles. An untagged apply includes all default-enabled roles below. Tags select components, while each optional component's enable flag still applies. The Windows `wvm` menu defaults to `all` for languages, development tools and helper tools and requires final scope confirmation. See [Ubuntu Server clones](hyperv.md#ubuntu-server-2604-clones) for the full menu. Neither path automatically removes old software or migrates legacy state.

For example, merge these non-secret overrides into ignored `ansible/host_vars/localhost.yml`, preserving your Git identity:

```yaml
workstation_languages: [node, python]
agent_tools_browser_enabled: false
agent_tools_graphify_enabled: true
docker_add_user_to_group: false
workstation_security_enabled: true
```

This example narrows languages, skips managed Chrome/MCP activation and avoids adding Docker-group membership. It still installs Docker when its role is selected and does not remove existing membership/software. On ARM64, keep the architecture-derived browser default rather than forcing Chrome on. To omit a role entirely, select a reviewed tag set or use `--skip-tags`.

| Scope | Tags or setting | Prerequisites and effects |
| --- | --- | --- |
| Common prerequisites | `base` | Installer/network/archive tools, system Python and user-session support; native build tools when any language is selected |
| Shell | `shell` | System packages/login-shell change; mise-backed shortcuts need the runtime role |
| Git | `git` | Required Git author name/email; replaces the managed user config |
| Runtimes/shared tool binaries | `runtimes` or `mise` | Selected languages plus always-included CLI entries; PHP prerequisites/Composer follow PHP selection |
| Ubuntu CLI packages/operations | `cli_tools` | APT packages, `workstation-doctor` and task service helper; see [operations](operations.md) |
| Codex | `codex`; `codex_config` or `codex_plugins` on a prepared install | Full defaults or the named sub-scope; see [Codex ownership](codex.md) |
| Editor machine settings | `vscode` | Adds missing Stable Remote-SSH settings; does not install the host app |
| Containers | `docker` | Requires systemd; service and optional Docker-group access |
| Browser | `chrome` plus `codex_config` on a prepared install | x86_64 Chrome/libraries/policy and matching MCP configuration |
| Indexer | `graphify` with its enabled flag | Existing mise/uv; its own pinned Python |
| Server baseline | `security`; enabled by default | Key-only SSH/UFW and other access changes; [prepare access first](security.md#ubuntu-server-baseline) |

The base role runs first and accompanies full installer tags; it supplies build-essential/pkg-config when any language is selected, including Node/Python without PHP. Its system Python is a provisioning prerequisite, not an additional mise language choice. The Windows scope summary discloses these dependencies.

The `agent_tools` tag selects its enabled helper-tool tasks together. A narrow configuration-only tag assumes its destination directories and tools already exist. Use the full relevant role for a first installation. These tags do not start application services, index a repository, sign in to Codex or execute application tests; Docker and the server baseline do start their managed system services.

## Apply the workstation configuration

The default security baseline switches SSH to key-only access for the development user, enables UFW with TCP/22 allowed and manages AppArmor/security updates. Establish working public-key SSH and a console recovery route first; custom SSH ports and additional users require a reviewed policy. See the [baseline and explicit opt-out](security.md#ubuntu-server-baseline).

Run the playbook from the repository root:

```bash
ansible-playbook ansible/site.yml --ask-become-pass
```

Preview changes without applying them:

```bash
ansible-playbook ansible/site.yml --check --diff --ask-become-pass
```

Apply only one part of the workstation when needed:

```bash
ansible-playbook ansible/site.yml --tags shell --ask-become-pass
ansible-playbook ansible/site.yml --tags docker --ask-become-pass
```

After Docker adds the user to its group, start a new terminal or run:

```bash
newgrp docker
```

## Recognize completion

The playbook must finish without failed tasks. Open a new SSH/login session for shell and group changes. Connect to the intended VM account, confirm command resolution from the active project using the [inspection procedure](operations.md#inspect-the-agent-environment), and complete Codex/Git-host sign-in separately when needed. No credentials or application dependencies are supplied by the playbook.

Next, [connect your editor or Codex](host.md#prepare-the-vm-and-connect-the-app). Use [maintenance](maintenance.md#update-an-existing-workstation) for later updates and [verification](verification.md) for test commands and coverage.

## WSL 2

Use a WSL 2 Ubuntu distribution and clone projects into its Linux filesystem, for example `~/projects/`, rather than a Windows-mounted project directory. Windows-specific prerequisites stay outside this Linux playbook.

The default security baseline and native Docker Engine require systemd. Check `ps -p 1 -o comm=` before applying it. If PID 1 is not systemd, merge the following into `/etc/wsl.conf`, preserving any existing sections:

```ini
[boot]
systemd=true
```

Then run `wsl --shutdown` from Windows PowerShell and reopen Ubuntu. The Docker role reports a prerequisite error before installation when systemd is unavailable. See [Microsoft's WSL systemd instructions](https://learn.microsoft.com/en-us/windows/wsl/systemd).

If you use Docker Desktop with WSL integration, keep systemd available for the default security baseline. Then let Desktop manage the engine and apply the remaining workstation roles with:

```bash
ansible-playbook ansible/site.yml --skip-tags docker --ask-become-pass
```

GPU drivers and AI model environments are not managed by Workstation. NVIDIA's Windows driver supplies WSL CUDA access; do not install a Linux NVIDIA display driver inside WSL. See [NVIDIA's WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/).
