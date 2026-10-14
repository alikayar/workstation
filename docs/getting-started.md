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
ansible-lint ansible/site.yml tests/preflight.yml
bash -n tests/preflight.sh
```

The password-based regression test provisions disposable containers only. It uses a public test password and never modifies the host's accounts or sudo configuration:

```bash
docker run --rm --mount type=bind,source="$PWD",target=/workstation,readonly ubuntu:24.04 bash /workstation/tests/preflight.sh
docker run --rm --mount type=bind,source="$PWD",target=/workstation,readonly ubuntu:26.04 bash /workstation/tests/preflight.sh
```

Full-role apply/idempotency checks run on disposable GitHub-hosted Ubuntu 24.04 and 26.04 runners. Container regression checks cover the actual preflight, password authentication, check mode with role tags, variable/environment overrides and fallback when `/usr/bin/sudo.ws` is missing. They do not establish a complete WSL or aarch64 installation result.
