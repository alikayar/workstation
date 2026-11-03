# Getting started

Workstation targets Ubuntu 24.04 and 26.04 LTS on a VM, physical machine or WSL 2. The machine needs internet access and a non-root user with `sudo` access. Roles support x86_64 and aarch64 assets; the full installation CI currently runs on x86_64 for both LTS releases. Other Ubuntu releases at least as new as 24.04 pass platform validation but are not CI targets. Other distributions and older Ubuntu releases are rejected before package changes.

## Install Ansible

Install Ansible and the Debian support library once:

```bash
sudo apt-get update
sudo apt-get install --yes ansible-core python3-debian sudo
```

## Set your Git identity

Create the local host variables file and set the identity used by the managed `.gitconfig`:

```bash
cp ansible/host_vars/localhost.example.yml ansible/host_vars/localhost.yml
nano ansible/host_vars/localhost.yml
```

## Apply the workstation configuration

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

If newly opened terminals also start Bash, inspect the terminal application's profile. Workstation does not rewrite Windows Terminal or VS Code settings, or redirect intentional Bash sessions through `.bashrc`.

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

The Docker role installs and manages native Docker Engine through systemd. Check `ps -p 1 -o comm=` before applying it. If PID 1 is not systemd, merge the following into `/etc/wsl.conf`, preserving any existing sections:

```ini
[boot]
systemd=true
```

Then run `wsl --shutdown` from Windows PowerShell and reopen Ubuntu. The Docker role reports a prerequisite error before installation when systemd is unavailable. See [Microsoft's WSL systemd instructions](https://learn.microsoft.com/en-us/windows/wsl/systemd).

If you use Docker Desktop with WSL integration, let Desktop manage the engine and apply the remaining workstation roles with:

```bash
ansible-playbook ansible/site.yml --skip-tags docker --ask-become-pass
```

GPU drivers and AI model environments are not managed by Workstation. NVIDIA's Windows driver supplies WSL CUDA access; do not install a Linux NVIDIA display driver inside WSL. See [NVIDIA's WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/).

## Validation

Run the repository's CI checks locally without applying the configuration:

```bash
ansible-playbook ansible/site.yml --syntax-check
ansible-lint ansible/site.yml
actionlint
```

Actionlint 1.7.12 needs `.github/actionlint.yaml` to recognize the GitHub-hosted `ubuntu-26.04` label. The configuration adds only that known label; other runner-label checks remain enabled. Remove the compatibility entry when the pinned actionlint release supports it natively.

Full-role apply/idempotency checks run on disposable GitHub-hosted Ubuntu 24.04 and 26.04 runners. They do not establish a complete WSL or aarch64 installation result.

## PHP and Composer through mise

PHP is pinned in `dotfiles/mise/config.toml`. The `php` role installs Ubuntu build dependencies before the `mise` role compiles PHP through its [vfox backend](https://github.com/jdx/vfox-php). The backend enables common extensions including MySQL, mbstring, XML, ZIP and curl and installs Composer alongside PHP. The mise role then replaces the bundled Composer with the version and checksum pinned in `ansible/roles/mise/defaults/main.yml`. No application service is started.

Apply the PHP prerequisites and managed runtime configuration from the Workstation root:

```sh
ansible-playbook ansible/site.yml --tags php --ask-become-pass
```

The tag includes the mise role and therefore installs all missing configured tools, not only PHP. Enter the sudo password in your terminal. PHP's first installation compiles from source and takes longer than downloading a runtime binary.

After PHP and pinned Composer are installed, the old Workstation launcher at `~/.local/bin/composer` is removed so the mise shim owns Composer resolution. Existing Ubuntu PHP packages are left installed for applications that explicitly use `/usr/bin/php`; their extensions and `/etc/php` settings do not configure mise's PHP. Project dependencies remain local: run `composer install` in the project's Composer directory.

The PHP backend sets `COMPOSER_HOME` inside the selected PHP installation. Existing global Composer packages and settings are not automatically migrated; project lockfiles remain authoritative.
