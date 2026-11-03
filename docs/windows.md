# Windows setup

On Windows 11 Pro x64, start in a **normal PowerShell window**:

```powershell
git clone https://github.com/alikayar/workstation.git
cd workstation
.\setup.ps1
```

Setup asks for your Git name, email and SSH public-key path, with defaults where available. Press Enter to keep a default. It saves your answers, installs the host applications, requests administrator access, and prepares Ubuntu on Hyper-V. Approve elevation with the **same Windows account**. If the selected key does not exist, SSH key generation asks you for a passphrase; existing private keys are never overwritten or copied into the VM.

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

- Windows Terminal with Catppuccin Mocha, 88% opacity, acrylic blur and JetBrains Mono Nerd Font at 12 pt.
- A **Workstation** PowerShell 7 profile and a matching **Workstation (Windows PowerShell 5.1)** profile for Hyper-V work.
- The Ubuntu Starship layout, with an explicit `host:<computer-name>` label on Windows. PSReadLine supplies history suggestions where supported and Tab menu completion.
- VS Code and Remote - SSH.
- Windows OpenSSH Client, Hyper-V and Packer as needed, followed by Ubuntu Server 24.04.5 and the existing Ansible playbook.

The default VM is named `workstation`: Generation 2, 4 CPUs, 8 GiB fixed RAM and an 80 GiB virtual disk. It uses Hyper-V's existing **Default Switch** for DHCP and outbound access. The `dev` account has key-based SSH access and passwordless sudo inside this development VM. The Ubuntu ISO checksum and Packer Hyper-V plugin version are pinned in `host/windows/ubuntu.pkr.hcl`.

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
| Same VM name without an installation record, or mismatched VM location/guest identity | Stops without provisioning it |
| Guest checkout or local Ansible variables changed during an incomplete installation | Preserves your work and asks you to finish manually |
| Installer stopped before Ubuntu SSH became available | Preserves the disk and asks you to inspect Hyper-V Manager |

Recovery uses the original committed revision and saved Git identity. New host commits are not silently applied to an interrupted installation. Completion records installation success, not ongoing configuration drift; use the [Ubuntu setup guide](getting-started.md) inside the VM for later changes.

Setup owns one marked block in `%USERPROFILE%\.ssh\config`. It backs up existing contents before changes and preserves other entries. An unmanaged `workstation` alias is left untouched and reported for manual resolution. The Default Switch can change the VM address; rerun setup to refresh the alias. Authentication errors never trigger a rebuild or disable host-key checking.

State lives under `%LOCALAPPDATA%\Workstation`: `setup.json` stores your non-secret answers, `Terminal` holds prompt files, and `HyperV\workstation` holds the VM disks, installation record and recovery payload. **Keep the VM directory.** Temporary build keys stay on Windows and are removed by the error handler; the permanent private key is only used locally by OpenSSH. Successful guest provisioning removes the temporary public key while preserving other authorized keys.

Packer uses a temporary HTTP endpoint bound to the Hyper-V adapter for installation metadata and public keys, with a matching temporary firewall rule. An abruptly terminated PowerShell process may leave a `Workstation-Packer-*` rule or `bootstrap-*` directory; inspect and remove only that attempt's leftovers. Bootstrap directories contain temporary private keys and must never be shared. Packer also creates an export copy; setup removes it after a successful build, but a failed export can leave an `output` directory separate from the live disks under `machines`.

For custom VM sizes, switch names or usernames, use `host/windows/New-WorkstationVM.ps1` directly as described by its parameters. The short setup flow deliberately uses the defaults. VMs created manually or by an older bootstrap without an ownership record are not adopted automatically.

## Windows trial status

This workflow has not yet been run end to end on Windows. During the first trial, confirm both terminal profiles, SSH and Remote - SSH access, reboot recovery, interrupted Ansible recovery, and a repeated run that reuses the VM without provisioning it again. An unrelated VM or SSH alias must remain untouched.

References: [WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/install), [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh), [Catppuccin](https://github.com/catppuccin/windows-terminal) (MIT notice included), [Packer Hyper-V builder](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso), [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html).
