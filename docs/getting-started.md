# Set up the Ubuntu environment

Run the commands in this guide **inside the Ubuntu environment** as your development user. After obtaining the checkout below, run Ansible from its repository root. If you have not connected yet, start with the [host connection guide](host.md). Ansible uses a local inventory: launching it on a host computer does not provision a remote VM.

Workstation targets Ubuntu 24.04 and 26.04 LTS on a VM, physical machine or WSL 2. The machine needs internet access and a non-root user with `sudo` access. Roles support x86_64 and aarch64 assets; the full installation CI currently runs on x86_64 for both LTS releases. Other Ubuntu releases at least as new as 24.04 pass platform validation but are not CI targets. Other distributions and older Ubuntu releases are rejected before package changes.

## Install Ansible

Install Git, Ansible and the Debian support library once:

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

If the checkout already exists, enter it and inspect local changes instead of cloning over it. Use [the update procedure](#update-an-existing-workstation) when adopting newer source. All remaining Ansible commands in this guide run from this checkout; `ansible.cfg` selects its local inventory.

## Set your Git identity

Create the ignored local host variables file without replacing an existing one, then set the identity used by the managed `.gitconfig`:

```bash
cp -n ansible/host_vars/localhost.example.yml ansible/host_vars/localhost.yml
nano ansible/host_vars/localhost.yml
```

## Choose the installation scope

Direct Ansible and the Windows menu share the same role sources but select scope differently. Direct Ansible is noninteractive apart from sudo; setting a runtime list does not disable Docker, Codex or other roles. Tags select components, while each optional component's enable flag still applies.

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

This is a fresh-install baseline. The untagged playbook installs all default-enabled roles, including the server security baseline, all configured runtimes, VM Codex settings/plugins, Docker Engine and its user group, Chrome with Chrome DevTools MCP enabled, and repository indexing. Review the sources and choose tags or overrides before applying; there are no per-package questions or automatic legacy migrations. The Windows `wvm` path asks separately for languages, development tools and helper tools, supports `hepsi` for all choices, and requires scope confirmation before running selected tags. For direct Ansible applies, `workstation_languages` in ignored host variables controls the runtime list; the default includes all five languages.

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

The playbook must finish without failed tasks. Open a new SSH/login session for shell and group changes. Connect to the intended VM account, confirm command resolution from the active project using the [inspection procedure](#inspect-the-agent-environment), and complete Codex/Git-host sign-in separately when needed. No credentials or application dependencies are supplied by the playbook.

Use [verification](verification.md) when actual runtime, idempotency or browser evidence is requested. Installation success alone does not establish those results. An omitted component is deliberately absent from the selected scope, rather than an installation failure.

## Update an existing workstation

Run from this checkout inside Ubuntu. Keep application work in its own repositories. Start with a clean Workstation checkout; if `git status --short` shows edits, finish or preserve them explicitly before updating. Do not stash/reset them automatically. Record the current commit and branch so there is a known source revision to return to:

```sh
git status --short
git rev-parse HEAD
git branch --show-current
git pull --ff-only
```

Review the diff from the recorded commit to `HEAD`, especially defaults, task behavior and configuration sources. For example, replace `PREVIOUS_COMMIT` with the recorded hash:

```sh
git diff --stat PREVIOUS_COMMIT..HEAD
git diff PREVIOUS_COMMIT..HEAD -- ansible dotfiles
```

Choose the relevant scope rather than applying everything for a documentation-only update:

| Changed component | Apply tag | State it manages |
| --- | --- | --- |
| Shell/default CLI | `shell` / `cli_tools` | Zsh/Starship files, packages, aliases and selected binaries; CLI collisions stop for ownership review. |
| Runtimes/PHP/Composer | `runtimes` | PHP build prerequisites, managed mise configuration, pinned runtimes and Composer. Project lockfiles stay authoritative. |
| Git | `git` | Managed `~/.gitconfig`; existing content receives an Ansible backup. |
| Codex settings only | `codex_config` | Replaces the complete `~/.codex/config.toml` from the configured source, including rendered browser paths. |
| All Codex defaults | `codex` | Also replaces global AGENTS and command rules and manages the pinned plugin. |
| Chrome/Graphify | `chrome`, `graphify` | Managed Chrome or repository indexer; Chrome setup may change libraries/AppArmor policy. |
| Docker | `docker` | Repository, packages, service and optional Docker-group membership. |

On a prepared VM, preview then apply the chosen tag; this example updates Chrome and the managed Codex integration:

```sh
ansible-playbook ansible/site.yml --tags chrome,codex --check --diff --ask-become-pass
ansible-playbook ansible/site.yml --tags chrome,codex --ask-become-pass
```

Check mode is a preview, not proof that downloads, extraction or a live tool will work. Standalone tool tags require their documented prerequisites; use the [browser guide](browser.md) and [agent environment](agent-environment.md) for prerequisites. For a change spanning roles, review and apply the full playbook. Choose authorized [verification](verification.md) for the affected behavior; repeated apply should report `changed=0`. Open a new shell for shell/group changes and a new Codex session for configuration changes.

### Configuration ownership

This setup owns complete files, not only selected keys. A `codex_config` or `codex` apply replaces existing Codex user settings; `codex` also replaces `~/.codex/AGENTS.md` and `rules/default.rules`. Review the intended sources before applying. If personal instructions/settings must remain independent, select maintained source overrides (`codex_config_src`, `codex_agents_src`, `codex_rules_src`) through the ignored host variables, or omit the Codex scope deliberately. The config source is rendered as a template without appending tables. The default template owns the draw.io marketplace identity; a custom source owns its complete content, including marketplace registration when the plugin scope is used. Do not put credentials in managed sources or assume an Ansible backup exists for Codex files. Existing personal/shared skills are never installed or modified by Workstation.

Shell and Git tasks have their own backup behavior; VS Code merges its selected settings. Consult each role before assuming a whole-machine merge or rollback. For changes that require restoring previous system/user state, arrange a VM checkpoint or approved backup with your existing VM manager before applying. No checkpoint or private-file backup is created by these update commands.

### Recover from a failed update

Keep the checkout, ignored host variables, VM and application data intact. Read the failing task and preserve its output. A download/checksum failure or an unrelated-file ownership error is a stop condition; do not delete user files or bypass the guard. Fix the cause and repeat only the relevant scope. An interrupted Chrome extraction is retried by its task; a success marker is written only after extraction finishes.

If the new source behavior is unsuitable, first ensure the checkout is clean, then use the recorded known-good commit in a detached checkout and reapply only the reviewed scope:

```sh
git status --short
git switch --detach KNOWN_GOOD_COMMIT
ansible-playbook ansible/site.yml --tags AFFECTED_TAG --check --diff --ask-become-pass
ansible-playbook ansible/site.yml --tags AFFECTED_TAG --ask-become-pass
```

Replace the placeholders; do not run them literally. Return to the recorded branch after recovery. Source rollback is not a complete machine rollback: APT updates, an existing Codex CLI, container/application data and removed or overwritten user files are not automatically restored. Use the checkpoint/approved recovery path when those states matter; changing a Git ref cannot restore them. Retain old tool environments while any process may still use them. Plugin revision conflicts have a [specific recovery procedure](codex.md#recover-a-marketplace-conflict); do not delete the plugin cache or rebuild the VM as a shortcut.

## Inspect the agent environment

When a tool is missing or resolves to an unexpected version, run the relevant commands from the active project directory. Project configuration takes precedence over workstation defaults; these commands do not replace project checks.

```sh
command -v node python3 go bun uv codex
mise which node
MISE_AUTO_INSTALL=0 node --version
```

Replace `node` with the affected tool; Go uses `go version`. In a shell without mise shims on PATH, use `~/.local/bin/mise exec -- COMMAND` with `MISE_AUTO_INSTALL=0` to avoid installing a missing runtime during inspection.

For local Docker access issues, explicitly target the VM's daemon:

```sh
docker --host unix:///var/run/docker.sock info --format '{{.ServerVersion}}'
```

This does not inspect rootless or remote Docker daemons. MCP configuration files also cannot establish which tools the current chat exposes; inspect the chat's available tools separately.

## Terminal still opens Bash

The shell role sets the account's login shell to `/usr/bin/zsh`. Verify the account setting separately from the current process:

```bash
getent passwd "$(id -un)" | cut -d: -f7
ps -p $$ -o comm=
```

If the first command returns `/usr/bin/zsh` and the second returns `bash`, the account setting is correct. An already running Bash session does not change when the playbook updates the login shell. Enter Zsh in that terminal with:

```bash
exec /usr/bin/zsh -l
```

If newly opened terminals also start Bash, inspect the terminal application's profile. The shell role does not rewrite terminal application profiles or redirect intentional Bash sessions through `.bashrc`. Separate Windows setup and Ubuntu VS Code settings may supply defaults; existing preferences can take precedence.

For VS Code connected through WSL or Remote-SSH, run **Terminal: Select Default Profile** in the remote window and select **zsh**, then create a new terminal. If the detected shell/profile is stale, close and reconnect the remote window. A remote Linux profile can explicitly use `/usr/bin/zsh` with `-l`; configure it in the remote settings rather than changing unrelated local Windows profiles. See [VS Code terminal profiles](https://code.visualstudio.com/docs/terminal/profiles).

For Windows Terminal, open the Ubuntu profile's **Command line** setting. Use the WSL distribution's default shell instead of an explicit `bash`, `-e bash` or `--exec bash` command. Preserve the intended distribution and any other profile-specific settings. See [Windows Terminal profile settings](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-general).

If the account setting itself is still Bash, apply the shell role as the intended Ubuntu user and then start a fresh session:

```bash
ansible-playbook ansible/site.yml --tags shell --ask-become-pass
```

## Sudo compatibility

Ubuntu 26.04 uses `sudo-rs` by default, whose password prompt is not understood by some distribution-packaged Ansible versions. The bootstrap package list includes `sudo` so the classic `/usr/bin/sudo.ws` is available. The playbook checks for that executable without privilege escalation and selects it only when no host/CLI `ansible_become_exe`, `ANSIBLE_BECOME_EXE` or configured become executable override was supplied. It leaves the ordinary `sudo` default in place when the classic binary is absent. No sudoers changes or system-wide provider switch are needed.

Use the Ubuntu user's password at the `BECOME password` prompt. Do not run the playbook itself as root: user-local configuration depends on the intended account's `USER` and `HOME`.

To bootstrap an older checkout affected by prompt detection, install classic sudo and select it just for that invocation:

```bash
sudo apt-get install --yes sudo
ANSIBLE_BECOME_EXE=/usr/bin/sudo.ws ansible-playbook ansible/site.yml --ask-become-pass
```

The automatic choice is a compatibility default, not a requirement to replace a working custom escalation setup. See [Ubuntu's sudo-rs notes](https://ubuntu.com/server/docs/reference/other-tools/sudo-rs/) and the [Ansible prompt compatibility issue](https://github.com/ansible/ansible/issues/85837).

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

## Validation

Use the [verification guide](verification.md) to choose source checks, isolated regressions, full Ubuntu provisioning or explicit browser smoke. It owns the commands, prerequisites, artifacts and CI coverage. An installed tool does not authorize its execution.

## PHP and Composer

Use the [mise and PHP guide](mise.md#php-and-composer) for source-build prerequisites, the scoped apply command and Composer ownership.
