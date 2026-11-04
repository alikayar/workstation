# Windows setup

On Windows 11 Pro x64, start in a **normal PowerShell window**:

```powershell
git clone https://github.com/alikayar/workstation.git
cd workstation
.\setup.ps1
```

Setup asks for your Git name, email and SSH public-key path, with defaults where available. Press Enter to keep a default. It saves your answers, installs the host applications, requests administrator access, and prepares Ubuntu on Hyper-V. Approve elevation with the **same Windows account**. If the selected key does not exist, SSH key generation asks you for a passphrase; existing private keys are never overwritten or copied into the VM.

For a new installation, set resource sizes in that normal PowerShell window before running setup:

```powershell
$env:WORKSTATION_VM_CPUS = '4'
$env:WORKSTATION_VM_MEMORY_MB = '8192'
$env:WORKSTATION_VM_DISK_GB = '80'
.\setup.ps1
```

These are logical CPU counts, MiB of memory and GiB of virtual disk capacity. Defaults are 4 / 8192 / 80; accepted ranges are 2–64 CPUs, 4096–131072 MiB and 40–2048 GiB. Invalid values stop before host provisioning. Setup saves non-secret resource settings in `setup.json` before elevation, so they survive a reboot and do not depend on environment-variable inheritance. Reruns reuse the saved sizes and reject conflicting environment values. Existing VMs are never resized automatically. Direct `New-WorkstationVM.ps1` parameters take precedence over environment variables.

After provisioning, Ubuntu's own `passwd` tool asks for the development user's console/sudo password over an authenticated SSH terminal. Enter it there, not in environment variables or setup arguments. The password never enters PowerShell variables, Packer's HTTP autoinstall data, JSON payloads or local files. The SSH host key and guest installation marker are checked before this step. If interrupted, rerun setup; successful finalization is recorded in the guest and does not reset the password on subsequent runs.

If Windows needs a restart, restart when convenient, return to this checkout and run `./setup.ps1` again. The same command also resumes an interrupted Workstation installation. It does not schedule a startup task or reboot automatically.

At completion, reopen Windows Terminal and select **Workstation**. Setup adds the SSH alias and prints:

```powershell
ssh workstation
code --remote ssh-remote+workstation /home/dev/projects/workstation
```

On the first SSH connection, compare its host-key fingerprint with the value printed at the end of setup before accepting it. New installations save the public host key for this comparison; earlier installations require the original installer output or a trusted recovery console. Codex can use the same alias; see the [host connection guide](host.md#prepare-the-vm-and-connect-the-app). Account sign-in remains interactive.

## Before the first run

Git for Windows and WinGet must be available to clone and install applications. If Git is missing:

```powershell
winget install --id Git.Git --exact --source winget
```

Reopen PowerShell after installing Git. If WinGet is missing, install or update **App Installer** through Microsoft Store. The repository is private, so cloning may ask you to sign into GitHub. Firmware virtualization must be enabled; setup cannot enable it reliably across different computers.

If your own machine blocks local PowerShell scripts, review the scripts and your execution policy. `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` permits local scripts for your user; organizational policy may override it. Setup does not bypass execution policy. Package installation accepts the selected packages' and WinGet source's agreements; some installers may request elevation.

## What you get

- Windows Terminal with Slate Glass (adapted from Catppuccin Mocha), 62% opacity, acrylic blur, 20/16 padding and JetBrains Mono Nerd Font at 13 pt.
- A **Workstation** PowerShell 7 profile and a matching **Workstation (Windows PowerShell 5.1)** profile for Hyper-V work.
- The Ubuntu Starship layout, with an explicit `host:<computer-name>` label on Windows. PSReadLine supplies history suggestions where supported and Tab menu completion.
- VS Code and Remote - SSH.
- Windows OpenSSH Client, Hyper-V and Packer as needed, followed by Ubuntu Server 24.04.5 and the existing Ansible playbook.

The default VM is named `workstation`: Generation 2, 4 CPUs, 8 GiB fixed RAM and an 80 GiB virtual disk. It uses Hyper-V's existing **Default Switch** for DHCP and outbound access, with Secure Boot using Microsoft's UEFI CA template for Ubuntu. The `dev` account has key-based SSH access and password-protected sudo after setup finishes. Passwordless sudo exists only during bootstrap and is removed after the console password is set. The Ubuntu ISO checksum and Packer Hyper-V plugin version are pinned in `host/windows/ubuntu.pkr.hcl`.

## Security policy for new VMs

New Windows-created VMs enable the opt-in Ansible `security` role through their saved host variables. Existing manually configured workstations and CI runners do not have their firewall or SSH settings changed by default. Legacy installation records keep their original policy rather than being silently migrated.

- Root stays locked. SSH root login, password login and keyboard-interactive login are disabled; only the development user is allowed.
- Local SSH forwarding remains available for VS Code Remote SSH. Agent forwarding, remote forwarding, X11 and tunnel devices are disabled. Ubuntu's maintained cryptographic defaults remain intact.
- UFW denies incoming and forwarded traffic by default, permits outgoing traffic and allows TCP 22 before activation. This SSH rule is not restricted to a changing Hyper-V DHCP subnet. Do not expose the VM through host/router port forwarding without reviewing its network access policy.
- AppArmor is enabled. Ubuntu security updates run daily; automatic reboot is disabled. Reboot deliberately when updates require it.
- Password quality is enforced through PAM with a minimum length of 15, including the initial password set by root. Normal administration requires sudo authentication.
- New development users are not granted the root-equivalent `docker`, `lxd`, `incus-admin` or `disk` groups at account finalization. Docker commands require `sudo docker`. Unattended Docker-based browser/MCP tools will need a separately reviewed rootless or approved access setup; do not fix them by restoring unrestricted passwordless sudo.

Docker-published ports can bypass UFW's normal input filtering. Bind development ports explicitly to loopback where appropriate; UFW alone does not restrict published container ports. This is a development VM baseline, not a claim of CIS compliance, disk encryption or protection from a compromised administrator. See [Ubuntu user management](https://ubuntu.com/server/docs/how-to/security/user-management/), [OpenSSH](https://ubuntu.com/server/docs/how-to/security/openssh-server/), [automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/) and [Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw).

Installed applications are reused. The terminal configuration is a separate [JSON fragment](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions), so existing Terminal settings and PowerShell profiles remain intact. Dedicated Workstation profiles load their own startup script. Choose your default profile under **Settings → Startup**, and Dark under **Appearance** if you want matching window chrome. User overrides for font and opacity take precedence over fragment defaults. Font changes may require reopening Terminal or signing out and back in.

Setup records the resolved Starship executable in `%LOCALAPPDATA%\Workstation\Terminal\runtime.json`. Both PowerShell profiles initialize Starship using that absolute path, so a new Terminal tab can refresh its environment without losing the prompt. A portable or Sandbox installation can use `host/windows/Set-Terminal.ps1 -StarshipPath C:\path\to\starship.exe` after placing the executable at its final location. If Starship is moved or reinstalled elsewhere, rerun terminal setup to refresh the recorded path. Opening a terminal does not install applications or change persistent PATH settings.

## Reruns and recovery

| Existing state | What setup does |
| --- | --- |
| Host applications already installed | Reuses them and refreshes changed managed terminal files |
| Hyper-V needs a restart | Saves your answers and asks you to rerun after restarting |
| Recognized VM is off, saved or paused | Starts or resumes it |
| Ubuntu is reachable, Workstation is incomplete | Transfers the saved payload and reruns Ansible |
| Workstation installation is complete | Skips provisioning and refreshes the SSH address |
| New VM provisioning finished but account finalization was interrupted | Resumes the guest password prompt and removes bootstrap sudo only after success |
| Same VM name without an installation record, or mismatched VM location/guest identity | Stops without provisioning it |
| Guest checkout or local Ansible variables changed during an incomplete installation | Preserves your work and asks you to finish manually |
| Installer stopped before Ubuntu SSH became available | Preserves the disk and asks you to inspect Hyper-V Manager |

New installations require a clean committed checkout. Recovery uses the original committed revision and saved Git identity. The repository bundle, provisioning script, Packer template and account finalization script come from that same revision. New host commits are not silently applied to an interrupted installation. Completion records installation success, not ongoing configuration drift; use the [Ubuntu setup guide](getting-started.md) inside the VM for later changes.

Setup owns one marked block in `%USERPROFILE%\.ssh\config`. It backs up existing contents before changes and preserves other entries. An unmanaged `workstation` alias is left untouched and reported for manual resolution. The Default Switch can change the VM address; rerun setup to refresh the alias. Authentication errors never trigger a rebuild or disable host-key checking.

State lives under `%LOCALAPPDATA%\Workstation`: `setup.json` stores your non-secret answers and resource sizes, `Terminal` holds prompt files, and `HyperV\workstation` holds the VM disks, installation record and recovery payload. **Keep the VM directory.** Temporary build keys stay on Windows and are removed by the error handler; the permanent private key is only used locally by OpenSSH. Successful guest provisioning removes the temporary public key while preserving other authorized keys. `/var/lib/workstation/account-ready` records account finalization; no password or hash is stored in the host's installation record.

Packer uses a temporary HTTP endpoint bound to the Hyper-V adapter for installation metadata and public keys, with a matching temporary firewall rule. An abruptly terminated PowerShell process may leave a `Workstation-Packer-*` rule or `bootstrap-*` directory; inspect and remove only that attempt's leftovers. Bootstrap directories contain temporary private keys and must never be shared. Packer also creates an export copy; setup removes it after a successful build, but a failed export can leave an `output` directory separate from the live disks under `machines`.

For custom VM sizes, switch names or usernames, use `host/windows/New-WorkstationVM.ps1` directly as described by its parameters. The short setup flow deliberately uses the defaults. VMs created manually or by an older bootstrap without an ownership record are not adopted automatically.

## Windows trial status

This workflow has not yet been run end to end on Windows. During the first trial, confirm both terminal profiles, SSH and Remote - SSH access, reboot recovery, interrupted Ansible recovery, and a repeated run that reuses the VM without provisioning it again. An unrelated VM or SSH alias must remain untouched.

References: [WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/install), [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh), [Catppuccin](https://github.com/catppuccin/windows-terminal) (MIT attribution in the repository's `LICENSE`), [Packer Hyper-V builder](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso), [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html).
