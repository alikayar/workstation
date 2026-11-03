# Windows 11 Pro host

This is the first Windows implementation and still needs an end-to-end run on a real Windows 11 Pro x64 host. Host application setup and VM creation are separate commands. Run them from a local Git checkout of Workstation under your own Windows account; the Ubuntu VM cannot configure its Windows host.

## Set up the host terminal and editor

Use a normal, non-administrator PowerShell window:

```powershell
.\host\windows\Install-Host.ps1
```

The script installs missing Windows Terminal, PowerShell 7 and Starship packages through WinGet, plus VS Code for the current user and its `ms-vscode-remote.remote-ssh` extension. Some package installers may request elevation; launch the script itself as your normal desktop user. Existing installations are reused rather than upgraded on every run. Existing VS Code settings and extensions are preserved.

Reopen Windows Terminal and select **Workstation** from its profile menu. This uses PowerShell 7, Catppuccin Mocha, 88% opacity with acrylic blur, JetBrains Mono Nerd Font at 12 pt and the same two-line Starship layout used in Ubuntu. The Windows prompt always shows `host:<computer-name>`; the shared VM configuration shows the remote hostname over SSH. PSReadLine supplies history-based inline suggestions where supported and Tab opens menu completion.

For Hyper-V provisioning, use **Workstation (Windows PowerShell 5.1)** with the same appearance, opened as administrator under the same account. These dedicated profiles load only the managed startup script, leaving your existing PowerShell profiles untouched. Make Workstation the default in **Settings → Startup → Default profile** if desired. The Terminal window's global theme remains your choice; choose Dark under Appearance for matching window chrome.

Terminal settings are added through a [JSON fragment](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions) under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Workstation`; the existing `settings.json` is not rewritten. Prompt files live under `%LOCALAPPDATA%\Workstation\Terminal`, and the font is registered only for your user. Files are rewritten only when their managed contents change. To adjust opacity or font size, use Terminal's settings for the Workstation profile; user overrides take precedence over fragment defaults.

The font is downloaded from the Nerd Fonts v3.4.0 JetBrains Mono release sources. The [Catppuccin color scheme](https://github.com/catppuccin/windows-terminal) is included with its MIT notice. Reopen all Terminal windows after setup; if the font still does not appear, sign out and back in. Windows transparency settings and the desktop session can affect the acrylic appearance.

After changing the shared Starship configuration in the repository, rerun host setup to refresh its Windows copy. This does not apply Ansible or change the running VM. Additional language extensions belong to the remote project.

WinGet comes through Windows App Installer. If PowerShell blocks a downloaded script, review it and follow your machine's script-signing/execution policy rather than disabling that policy globally. If Windows OpenSSH Client is missing, install it from Windows Optional Features or run this in an administrator PowerShell window:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

## Prepare a key and VM inputs

Use an existing SSH public key, or create a dedicated key from your normal PowerShell session:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\workstation_ed25519"
```

Choose a passphrase when prompted. Do not overwrite an existing key. The `.pub` file is used to authorize access in Ubuntu. On resume, Windows OpenSSH uses the corresponding private key locally and may prompt for its passphrase; the private key is never copied to the VM. Pass `-IdentityFile` if its path differs from the public-key path without `.pub`.

VM creation needs hardware virtualization enabled in firmware, Windows 11 Pro x64 with Hyper-V, Git for Windows, WinGet and Windows OpenSSH. The script installs Packer on demand for unattended Ubuntu installation. Use an elevated PowerShell window under the **same Windows account**, not a different administrator account.

## Create Ubuntu and install Workstation

Commit any Linux provisioning changes you want included first. The VM payload is a Git bundle of the current committed branch, so ignored host variables and uncommitted changes never travel to the VM. This also works while the repository is private: the new VM does not need GitHub credentials to receive the bundle.

Run from the repository root in administrator PowerShell:

```powershell
.\host\windows\New-WorkstationVM.ps1 `
    -GitName 'Your Name' `
    -GitEmail 'you@example.com' `
    -PublicKeyPath "$env:USERPROFILE\.ssh\workstation_ed25519.pub"
```

If Hyper-V is disabled, the script enables it and returns. Restart Windows when convenient and rerun the same command. Firmware virtualization must already be available; a script cannot reliably enable it for every computer.

Defaults are a Generation 2 VM named `workstation`, 4 CPUs, 8 GiB of fixed RAM, an 80 GiB virtual disk and Ubuntu Server 24.04.5. The official ISO checksum is pinned in `host/windows/ubuntu.pkr.hcl`. The `dev` account uses SSH keys, has password login disabled and has passwordless sudo inside this development VM. Do not use this bootstrap as a production-server policy.

The existing Hyper-V **Default Switch** supplies DHCP and outbound network access. If it has a different name on your machine, pass `-SwitchName`; the selected switch must be Internal, with DHCP and internet access. The script does not create or modify virtual switches. You can also set `-VMName`, `-UserName`, `-CPUs`, `-MemoryMB`, `-DiskGB` and `-StateRoot`.

Packer boots the installer and supplies autoinstall configuration through a temporary HTTP endpoint bound to the host's Hyper-V adapter. A temporary firewall rule permits that port on the same adapter for the local subnet and is removed when the command exits normally or through its error handler. The endpoint serves only installation configuration and public keys. The temporary build private key stays in a restricted Windows directory; it is removed after the build, and successful provisioning leaves only your supplied public key in the VM's authorized keys.

After Ubuntu installs, Packer transfers the committed repository and Git identity into the VM, runs the existing Ansible playbook as the development user, shuts the VM down cleanly and starts it again. Codex/GitHub account sign-in remains a separate interactive step. On subsequent runs, PowerShell recognizes this installation and resumes provisioning over SSH instead of invoking the Ubuntu installer again.

## Connect VS Code or Codex

After the VM starts, get its reported IPv4 address from administrator PowerShell:

```powershell
Get-VMNetworkAdapter -VMName workstation | Select-Object -ExpandProperty IPAddresses
```

If no address appears yet, wait for Ubuntu to boot or inspect it in Hyper-V Manager. Use the guest's reachable IPv4 address in the host's SSH config, following the [connection guide](host.md#add-a-host-side-ssh-alias), with `User dev` and `IdentityFile ~/.ssh/workstation_ed25519`. The Default Switch address can change after a restart; update the alias when needed. No fixed IP or port-forwarding rule is installed by these scripts.

As soon as Packer connects to the installed Ubuntu guest, it prints `SSH_HOST_FINGERPRINT_FOR_FIRST_CONNECTION` followed by the VM's Ed25519 host-key fingerprint. Keep that output and compare it with the fingerprint shown by the first SSH connection before accepting. The account has no console password. If the fingerprint differs or the build did not reach that step, inspect the VM through a trusted recovery console; do not disable host-key checking.

From a normal host terminal:

```powershell
ssh workstation
code --remote ssh-remote+workstation /home/dev/projects/workstation
```

Alternatively use VS Code's **Remote-SSH: Connect to Host** command. VS Code installs its server in Ubuntu on first connection. Codex can use the same SSH alias; see [connecting the desktop app](host.md#prepare-the-vm-and-connect-the-app). Repositories and development servers live inside Ubuntu, with previews available through [port forwarding](host.md#preview-an-application).

## Reruns and failures

Application setup can be rerun; it skips installed applications and the existing Remote - SSH extension, and refreshes only changed managed terminal files. Run the same VM command with the same state directory, username, public key and Git identity to resume an installation:

| Existing state | Action |
| --- | --- |
| No VM or previous guest disks | Create Ubuntu with Packer, then provision Workstation |
| Recognized VM is off, saved or paused | Start or resume it, then wait up to ten minutes for SSH |
| Ubuntu is reachable, Workstation is incomplete | Transfer the saved payload and rerun Ansible |
| Workstation completion marker exists | Print the current connection address without uploading files or rerunning Ansible |
| Same VM name without an installation record, or mismatched VM location/guest identity | Stop without provisioning it |
| Guest disks exist but VM registration is missing | Stop and preserve the disks for manual recovery |
| Installer stopped before Ubuntu SSH became available | Preserve the VM and ask you to inspect the installer in Hyper-V Manager |

The Windows installation record, VM path and installer-written guest identifier establish ownership. VMs created manually or by the earlier bootstrap without this record are not adopted automatically. The script does not change an existing VM's CPU, memory, disk size or switch on reruns.

The original committed revision, Git identity and provisioning script are retained as a payload. New host-side commits are not silently applied during recovery. A successful Ansible run writes the guest completion marker; an interrupted run leaves the installation resumable. A changed guest checkout or changed local Ansible variables causes recovery to stop instead of resetting your work. Completion records installation success, not ongoing configuration drift; use the [Ubuntu setup guide](getting-started.md) inside the VM for later updates.

VM files and the installation record live under `%LOCALAPPDATA%\Workstation\HyperV\workstation` by default. **Keep that directory: it contains the VM disks and recovery payload.** Packer creates an export copy before completing and the script removes that copy after the registered VM starts successfully. Allow free space for both copies during setup and for the downloaded ISO cache. An interruption during export can leave an extra `output` directory; inspect it separately from the live disks under `machines`.

Recovery uses normal SSH host-key checking. Compare the first connection's fingerprint with the Packer output described above. If no trusted fingerprint was captured, obtain it through the VM recovery console. An authentication failure stops recovery; it does not recreate the VM or disable host-key checking.

If PowerShell is terminated before its error handler can run, a `Workstation-Packer-*` firewall rule or `bootstrap-*` directory may remain. Inspect and remove only the rule/directory from that attempt. Bootstrap directories contain temporary private keys; never commit them, publish them or attach them to an issue. The recovery payload retains only the temporary **public** key so successful provisioning can remove that key from the guest while preserving other authorized keys.

The script never deletes a guest disk or automatically restarts an interrupted OS installation. For a deliberate fresh installation, preserve any work first and use a new VM name or manually remove only the failed VM and its installation directory.

## First Windows trial

On the Windows host, confirm that both Workstation terminal profiles show the font, colors and host label, that existing profiles remain intact, and that application setup can be rerun without duplicate profiles. Confirm that Hyper-V setup handles a pending restart, Ubuntu completes installation and SSH and Remote - SSH connect. Interrupt Workstation provisioning after Ubuntu is installed, rerun the same command and confirm it reuses the same VM and completes Ansible. Run it again to confirm the completed installation skips provisioning, and repeat with the VM powered off. An unrelated VM with the same name must be left unchanged. Check that the temporary firewall rule and bootstrap key are gone after a successful build. These Windows checks have not been performed from the Linux development environment.

References: [WinGet installation](https://learn.microsoft.com/en-us/windows/package-manager/winget/install), [VS Code CLI](https://code.visualstudio.com/docs/configure/command-line), [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh), [Hyper-V Packer builder](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso), [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html).
