# Windows setup

On Windows 11 Pro x64, start in a **normal PowerShell window**:

```powershell
git clone https://github.com/alikayar/workstation.git
cd workstation
.\setup.ps1
```

Setup asks for VM CPU count, memory and disk capacity, followed by your Git name and email. Each available default appears in brackets; press Enter without typing a value to accept it. Resource defaults are **4 CPUs, 8192 MiB RAM and 80 GiB disk**. Invalid resource answers repeat the same question. Your Git identity defaults to the existing Git configuration; a missing name or email must be supplied.

Answers are saved atomically in `%LOCALAPPDATA%\Workstation\setup.json` before host application installation and elevation. Subsequent runs reuse the saved answers without repeating the questions. Setup installs the host applications, requests administrator access and prepares Ubuntu on Hyper-V. Approve elevation with the **same Windows account**.

SSH key selection is automatic. Setup creates a dedicated Ed25519 key at `%USERPROFILE%\.ssh\workstation_ed25519` if missing, or reuses the existing pair. New keys have no passphrase prompt and their private file permissions are restricted to your Windows account and SYSTEM. The private key stays on the host; only the public key enters the VM. A public key without its matching private key stops setup rather than replacing the identity. An interrupted key creation can recover a missing public key from an existing unencrypted private key. Previously saved custom key paths remain in use; setup does not remove encryption from existing keys, so connecting with a protected existing key can still ask for its passphrase.

Optional environment variables change the defaults offered on the first run:

```powershell
$env:WORKSTATION_VM_CPUS = '6'
$env:WORKSTATION_VM_MEMORY_MB = '12288'
$env:WORKSTATION_VM_DISK_GB = '120'
.\setup.ps1
```

These are logical CPU counts, MiB of memory and GiB of virtual disk capacity. Accepted ranges are 2-64 CPUs, 4096-131072 MiB and 40-2048 GiB. Invalid environment values stop before host provisioning. Saved settings survive reboot and do not depend on environment-variable inheritance. Reruns reject environment values that conflict with saved sizes; clear those overrides to resume with the recorded configuration. Existing VMs are never resized automatically and legacy installations do not receive resource questions. Direct `New-WorkstationVM.ps1` parameters take precedence over environment variables; it also accepts an explicitly selected SSH public key for advanced use.

After provisioning, Ubuntu's own `passwd` tool asks for the development user's console/sudo password over an authenticated SSH terminal. Enter it there, not in environment variables or setup arguments. The password never enters PowerShell variables, Packer's HTTP autoinstall data, JSON payloads or local files. The SSH host key and guest installation marker are checked before this step. If interrupted, rerun setup; successful finalization is recorded in the guest and does not reset the password on subsequent runs.

If Windows needs a restart, restart when convenient, return to this checkout and run `./setup.ps1` again. The same command also resumes an interrupted Workstation installation. It does not schedule a startup task or reboot automatically.

At completion, reopen Windows Terminal and select **Workstation**. Setup adds the SSH alias and prints:

```powershell
ssh workstation
code --remote ssh-remote+workstation /home/dev/projects/workstation
```

On the first SSH connection, compare its host-key fingerprint with the value printed at the end of setup before accepting it. New installations save the public host key for this comparison; earlier installations require the original installer output or a trusted recovery console. Codex can use the same alias; see the [host connection guide](host.md#prepare-the-vm-and-connect-the-app). Account sign-in remains interactive.

## Source layout

`setup.ps1` remains the main entry point. Windows-specific files are grouped by responsibility:

| Location | Responsibility |
| --- | --- |
| `host/windows/hyperv/windows-pro/` | Standalone Windows Pro VM command, media download, unattended setup and answer template |
| `host/windows/Install-Host.ps1` | Install host applications and invoke terminal setup |
| `host/windows/terminal/` | Standalone dependency installation, PowerShell configuration, Terminal profiles and font/theme |
| `host/windows/hyperv/` | VM bootstrap, resource inputs and Packer template |
| `host/windows/hyperv/commands/` | Temporary VM commands, ownership checks, image factory and seed ISO |
| `host/windows/hyperv/guest/` | SSH account finalization and Ubuntu bootstrap payload scripts |

Saved payloads keep their existing filenames and state directories. Recovery reads source files from the recorded Git revision and supports both the current and previous flat source layout.

## Windows 11 Pro test VM

`host/windows/hyperv/windows-pro/New-WindowsProVM.ps1` creates a separate Windows VM for testing the host tooling. It is independent of the Ubuntu `setup.ps1` and `wvm` lifecycle. Run it in an **administrator, 64-bit PowerShell** window on Windows 11 Pro x64 with Hyper-V already enabled. Windows PowerShell 5.1 and PowerShell 7 (including 7.6) use the same inbox Windows PowerShell 5.1 worker; PowerShell 7 does not load Hyper-V through compatibility-session proxies. No PowerShell installation, execution-policy change or automatic elevation is performed.

Installation media is pinned in `host/windows/hyperv/windows-pro/Windows-Media.ps1` to **Windows 11 25H2, build 26200.6584, x64, English (United States), multi-edition including Pro**. The SHA256 is `D141F6030FED50F75E2B03E1EB2E53646C4B21E5386047CB860AF5223F102A32`, originally published in the English 64-bit row on [Microsoft's download page](https://www.microsoft.com/ja-jp/software-download/windows11?msockid=2d54d98863066df52f04cf0962136c58). The current download page may list a newer release; updating it never changes this repository's pin. The fixed Microsoft CDN URL was published in this [Microsoft Q&A answer](https://learn.microsoft.com/en-us/answers/questions/6020251/i-need-a-direct-download-link-for-the-windows-11-2) and checked on 2026-11-04.

The command downloads directly from that pinned HTTPS URL into `%ProgramData%\Workstation\Media`. It does not call the temporary-link API, ask for a URL, change regions, or use third-party mirrors. Redirects are refused. If Microsoft removes the file or the network fails, it stops with the download error; there is no silent upgrade or unverified fallback. A verified existing cache is reused; a mismatching cache is preserved and refused. Downloads use a temporary `.partial` file which is removed on handled failure and published as an ISO only after verification. A forcibly terminated process can leave a partial file; it is never treated as a completed ISO.

An ISO is not an Authenticode-signed executable. The command verifies the entire ISO against Microsoft's pinned SHA256, then checks the **Microsoft Authenticode signature on the ISO's `setup.exe`**, plus the Pro edition, x64 architecture and exact image build. It never executes Windows Setup on the host. Enterprise Evaluation and Pro N media are rejected. To supply a previously downloaded copy, use `-IsoPath 'D:\ISO\Windows11-x64.iso'`; it must match the same pin. There is no caller-provided checksum override. Changing release requires reviewing and updating the media pin in the repository.

```powershell
.\host\windows\hyperv\windows-pro\New-WindowsProVM.ps1 `
    -VMRoot 'D:\VMs' `
    -NestedVirtualization -OpenConsole
```

Omit `-VMName`, `-CPUs`, `-MemoryGB` or `-DiskGB` to answer interactive questions for those values. Each question shows its default in brackets; Enter accepts it, and invalid answers repeat the question. Explicit parameters skip their questions. New VM defaults are `workstation-windows-pro`, 4 logical CPUs (capped at the host count), 8 GiB fixed RAM and a 120 GiB dynamically growing disk. When resuming an owned VM, resource questions show its saved sizes; changing them is refused rather than resizing the VM. The existing Internal `Default Switch` is used by default. `VMRoot` defaults to `%ProgramData%\Workstation\WindowsVMs`. The host must retain at least 2 GiB available RAM after VM allocation, and a new disk requires at least 64 GiB physical free space. The script does not stop other VMs to free memory. `-NestedVirtualization` exposes CPU virtualization extensions so Hyper-V can later be enabled inside Windows; it does not install the guest role. Networking for nested guests must be configured inside that guest, for example with its Default Switch/NAT. The script does not enable MAC spoofing or modify host switches/firewall rules.

New VMs also ask for a local user name `[dev]` (or accept `-UserName`) and a password twice through `Read-Host -AsSecureString`. Blank passwords and mismatches are rejected; passwords have no default and are never accepted as command-line parameters. The password prompt runs inside the 5.1 worker, so no secret is serialized into the PowerShell 7 delegation command. The account belongs to local Administrators for development and PowerShell Direct; automatic logon is not enabled.

`host/windows/hyperv/windows-pro/Autounattend.xml` selects **Windows 11 Pro**, English (`en-US`) UI, Turkish (`tr-TR`) regional formats/system locale, **Turkish Q** (`041f:0000041f`) and `Turkey Standard Time`. The template accepts the Windows licence terms and uses the public default Pro installation key to select the edition; that key does not activate Windows or provide a licence. Windows Setup creates EFI, MSR, Windows and approximately 1 GiB recovery partitions on the one new virtual disk. `WillWipeDisk` is false: an existing partitioned disk is not automatically wiped if installation is restarted from DVD.

The Microsoft ISO remains unchanged. The command reuses the existing seed-ISO writer to attach a second, nonbootable ISO with the answer file. In the console, **press a key once** if prompted to boot from DVD. Windows Setup then reads the answer file automatically. Do not press a key on subsequent reboots. `-OpenConsole` opens VMConnect; without it you must open the VM console yourself for that first keypress. Previously created schema-1 manual VMs keep their manual installation flow and are never converted or reinstalled automatically; choose a new VM name for unattended installation.

The rendered answer contains the supplied password in recoverable form, as required by Setup. Only its placeholder template is tracked. Host answer files and media are created under `<VMRoot>\<VMName>\setup-secrets` with inheritance disabled and access limited to the creating Windows account, SYSTEM and Administrators. Source XML is removed immediately after ISO creation; the password is not stored in `windows-vm.json`. The command waits up to 45 minutes, using authenticated **PowerShell Direct** rather than exposing a guest SSH/WinRM network listener. It checks the VM ID, ownership token, single disk, guest setup token and Windows setup-completion flags before setting the user's Turkey location (GeoID 235), deleting guest cached answer files, detaching both DVDs and removing host answer media. Setup verification is saved before host cleanup so interrupted cleanup can safely repeat. Deletion is ordinary file removal, not a forensic secure erase.

Keep the PowerShell window open through completion. Ctrl+C or a timeout retains the VM and its protected answer ISO; repeat the same command/name and supply the original password to continue verification, without regenerating installation media or reformatting the disk. Missing/tampered media, an incomplete secret directory or a failure between ISO publication and recording its hash stops for inspection. A pending installation must not be checkpointed or have disks replaced while verification runs. No new password is requested after verified setup cleanup is complete. See [Microsoft's answer-file search order](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-automation-overview) and [default input profiles](https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-input-locales-for-windows-language-packs).

The VM uses Generation 2, Microsoft Windows Secure Boot and a local vTPM. Automatic checkpoints and host auto-start are disabled. Guest Service Interface file-copy integration is disabled. Use a basic VMConnect session for untrusted workloads: enhanced sessions can redirect clipboard, drives and devices. An Internal switch alone is **not** the network-isolation policy used by the Ubuntu temporary VM commands. See Microsoft's [Windows 11 Hyper-V example](https://techcommunity.microsoft.com/blog/itopstalkblog/how-to-run-a-windows-11-vm-on-hyper-v/3713948) and [nested virtualization requirements](https://learn.microsoft.com/windows-server/virtualization/hyper-v/enable-nested-virtualization).

Repeat the same command with the same arguments to start or resume the recorded VM. Settings and ownership are saved atomically in `<VMRoot>\<VMName>\windows-vm.json`; concurrent invocations are refused. A running completed VM is left running, and a completed saved VM is restored without resetting its TPM or firmware. An incomplete VM must be Off before configuration can resume. Checkpoint disk chains are accepted only when they remain inside the VM directory and descend from its recorded base disk. Different settings, missing/replaced VM identities, unowned names/directories and linked paths stop with existing files preserved. A failure in the narrow interval between VM creation and ownership tagging requires manual inspection; it never triggers adoption, deletion or rebuilding. This command has no deletion operation.

Use the adjacent `Remove-WindowsProVM.ps1` for a create/delete test cycle or to clear orphaned files after manually removing a VM registration. Run from the same administrator account that created it, using the same `VMRoot` and an explicit VM name:

```powershell
# Preview; -Force permits considering a running/saved VM, without changing it.
.\host\windows\hyperv\windows-pro\Remove-WindowsProVM.ps1 `
    -VMRoot 'D:\VMs' -VMName 'workstation-windows-pro' -Force -WhatIf

# Delete this VM and all its files; asks for confirmation.
.\host\windows\hyperv\windows-pro\Remove-WindowsProVM.ps1 `
    -VMRoot 'D:\VMs' -VMName 'workstation-windows-pro' -Force
```

The command removes the owned VM registration, checkpoints, virtual disks, saved state and setup secrets under its recorded directory. The shared verified Windows ISO cache is retained. Without `-Force`, the VM must already be Off. `-Force` permits an immediate power-off and loss of unsaved guest state; it never bypasses ownership, dependency or active-operation checks. Use `-Confirm:$false` only when intentionally skipping the deletion confirmation. While the creation command is waiting for installation, finish it or cancel that command with Ctrl+C first; both commands use the same per-name lock. Cancelling the command retains the VM for inspection or deliberate deletion.

The marker's owner, VM ID, name, directory and token must match. A replaced VM, linked path, disk/configuration outside the owned directory, or another VM/checkpoint referencing files inside it causes refusal. Missing ownership records never authorize deleting an existing directory. Interrupted deletion keeps `.<VMName>.delete.json` beside the VM directory, so rerunning can finish even if its inner marker is already gone. A stale journal cannot delete a replacement generation; creation refuses that name until deletion finishes. Repeating removal when both VM and files are absent is harmless. A corrupt ownership record/journal requires inspection rather than guessing which files to delete.

## Temporary VM commands

Host application setup installs `wvm` in the managed Workstation terminal profiles and adds a **Workstation** folder to the Windows Start menu. Existing shell commands with the same name are preserved. The implementation lives under `host/windows/hyperv/commands/`; `Install-VMCommands.ps1` prepares the committed bundle without elevation and installs an administrator-owned, versioned command package after UAC approval. Later VM operations do not execute checkout scripts or Git hooks, and do not depend on the checkout staying in place. Rerun `host/windows/Install-Host.ps1` from the updated checkout to refresh installed commands, shortcuts and terminal startup files.

```powershell
wvm template           # Prepare the clean image once, preferably before the interview
wvm new                # Ask for a name [takehome], create or resume it, then open VS Code
wvm open               # Show saved names and ask which VM to open; Enter accepts the shown name
wvm open takehome      # Open the named VM directly, starting it if needed
wvm stop               # Ask which temporary VM to shut down gracefully
wvm list               # Show managed temporary VMs
wvm destroy takehome   # Remove this temporary VM and its files
```

Names use 2-32 lowercase letters, digits or hyphens, beginning with a letter and ending with a letter or digit. Named commands skip the name question. `new` with an existing managed name preserves its VM and disk and resumes unfinished creation instead of reinstalling. CPU and RAM default to saved setup answers; `wvm new takehome -CPUs 4 -MemoryMB 8192` can override them for a new VM. Disk capacity comes from the selected image. Existing VMs are never resized by these commands. `destroy` requires an explicit name and also supports `-WhatIf` and `-Confirm`.

The first image preparation uses a **new dedicated builder VM**, installs Ubuntu and the workstation tools, seals it and copies its powered-off disk into a versioned image. It can take as long as the initial installation; later `new` operations create a separate differencing disk and do not rebuild PHP or reinstall tools. Each VM receives its own Hyper-V ID, hostname, machine ID and SSH host keys. Image creation is refused if the builder has known external-account credential files. Host private keys are never included; the builder has no external sign-in step and its account password is removed before publication. For each temporary VM, Windows generates a unique Ed25519 SSH server identity in its protected instance directory and supplies it through the local read-only NoCloud ISO. The frontend pins the matching public key before connecting, including after a DHCP address change; a conflicting existing pin is refused. The Windows login private key is never included. The guest server private key is instance-specific sensitive data in the seed and instance directory, removed with that VM. First account finalization asks for the VM's own console/sudo password. No password is placed in the seed ISO or operation records.

`wvm template -Refresh` builds and selects a new image. Existing child disks keep their original image; older images are retained while their children may still use them. Keep image directories in place. If preparation is interrupted, its recorded builder and stage are reused where safe; ambiguous sealing/conversion failures stop for inspection rather than publishing an unverified disk. Installing or updating commands requires a clean committed checkout. Image creation uses the installed bundle, Packer template and bootstrap scripts. An interrupted builder retains its original package; installing newer commands does not replace its recovery payload. Repeating installation with the same revision, answers and editor path reuses the installed package. Older packages are retained for recovery. New image builds share a protected ISO cache; Packer still checks the pinned ISO checksum before using it.

`open` refreshes a managed SSH alias such as `ws-takehome`, then launches VS Code as the desktop user. It adds a marked Include block to the user's SSH config, preserves other entries and rejects direct alias collisions. Per-VM SSH fragments, host-key records and **Open / Stop / Destroy** shortcuts live in `%LOCALAPPDATA%\Workstation\Connections/<name>`, separately from the protected VM disks and ownership records. **VM folders** in the Start menu opens these directories; the other Start menu entries ask for the VM name. Per-VM shortcuts carry their own explicit name. Hyper-V operations request UAC for the same Windows account; no background administration service, scheduled task or automatic group membership is installed.

The backend is installed under `%ProgramFiles%\Workstation/<Windows SID>/Packages/<id>`, selected through an administrator-owned `current.json`. Authoritative state is under `%ProgramData%\Workstation/<Windows SID>`: `Instances/<name>` owns one temporary VM, `Images/<id>` owns an immutable base image, and `Results` holds operation results and logs. Administrators and SYSTEM can write these directories; the desktop user can read them. The worker accepts only the action, validated VM name, CPU/RAM values, refresh flag and request ID. It does not read user-written request files or execute a path supplied in a request. Packer 1.16.2 is installed from its pinned SHA-256 archive into the protected package; plugin discovery/configuration and temporary files use protected directories. SSH helpers use Windows OpenSSH by absolute path with user SSH configuration, agent use and forwarding disabled.

Destruction checks the recorded Hyper-V ID, directory boundaries, disk parent chain, linked paths and references from other VMs. It removes only that temporary VM and its owned directory; the desktop frontend removes a matching connection directory separately. It never adopts or deletes manually created VMs, the main `workstation` VM, `dev-vm`, `backup-vm` or shared images. Old user-writable VM records are not silently adopted or migrated. Filesystem deletion is not secure erasure.

The image factory and core lifecycle have been exercised on a Windows 11 host, but the complete workflow is not yet validated. See the validation checkpoint below; this is a backup checkpoint, not a release-readiness claim.

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

The default VM is named `workstation`: Generation 2, 4 CPUs, 8 GiB fixed RAM and an 80 GiB virtual disk. It uses Hyper-V's existing **Default Switch** for DHCP and outbound access, with Secure Boot using Microsoft's UEFI CA template for Ubuntu. The `dev` account has key-based SSH access and password-protected sudo after setup finishes. Passwordless sudo exists only during bootstrap and is removed after the console password is set. The Ubuntu ISO checksum and Packer Hyper-V plugin version are pinned in `host/windows/hyperv/ubuntu.pkr.hcl`.

## Isolation for temporary assignment VMs

This additional policy applies only to VMs owned by `wvm`. It does not retrofit existing development VMs or image builders. Build images from trusted workstation source before introducing assignment code; keep Windows, Hyper-V, Ubuntu, OpenSSH and VS Code patched.

| Boundary | Managed behavior |
| --- | --- |
| Public internet | Outbound IPv4 TCP/UDP on all ports, with stateful return traffic; DNS and QUIC remain usable. IPv4 ICMP reception supports path MTU discovery. |
| Host, LAN, other VMs | Hyper-V extended ACLs deny guest-originated traffic to private, loopback, link-local, CGNAT, multicast/reserved ranges, current host IPv4 addresses and current non-default host routes, including public-address LAN/VPN prefixes. |
| Necessary local traffic | Only DNS TCP/UDP 53 and DHCP UDP 68/67 to the Default Switch gateway, DHCP broadcast, and host-initiated SSH TCP 22 with stateful return traffic. |
| IPv6 | Denied at the VM adapter in both directions. This workflow offers IPv4 internet; IPv6-only destinations are unavailable. |
| Policy failure | The adapter is disconnected before rules are refreshed and reconnects only after the complete rule set is installed. Failure preserves disks and leaves networking disconnected. |
| Devices and sharing | One managed NIC, Secure Boot, fixed RAM, nested virtualization off, MAC spoofing off, DHCP/router guards on, port mirroring off, Guest Service Interface file copy disabled. Provisioning does not map host folders or add USB/GPU passthrough or an enhanced-session RDP service. |
| Resource pressure | CPU maximum 80% of assigned vCPU capacity, 3,000 maximum disk IOPS, 250 Mbit/s NIC cap. Before starting, require available guest RAM plus 2 GiB for Windows, and free disk for the full capacities of managed temporary disks plus a 20 GiB reserve. Disk admission is conservative and is not an NTFS quota or a guarantee against other host processes filling the disk. |
| Editor | Dedicated `%LOCALAPPDATA%\Workstation\Editor/<installation ID>` user data so reused VM names do not inherit prior Workspace Trust; a shared minimal extension directory; only Remote SSH and its companion extensions are admitted on the host. Settings Sync and automatic/restored port forwarding are off, forwarded ports bind to localhost, Workspace Trust remains enabled, and automatic tasks are off. Personal editor settings/extensions are not copied. Portable VS Code is refused because its data directory overrides CLI isolation. Editor caches are retained locally after VM deletion; deleting the VM is not erasure of editor/browser caches or copied files on the host. |

The worker refreshes the network policy on each `new`/`open`, including existing running temporary VMs; connections can briefly drop during refresh. After changing VPN or network topology, stop and reopen the temporary VM to refresh current host routes. A VPN that uses split-default routes can make the policy deny public egress; this fails closed rather than silently bypassing the VPN. Existing RFC1918/IPv6 blocks remain enforced even between refreshes. This IP policy does not claim to eliminate every layer-2 attack on a shared Default Switch, or route changes made while a VM remains open. Manually starting/reconfiguring a VM in Hyper-V Manager bypasses the lifecycle preflight; use `wvm` for managed operation.

The host policy remains outside the guest even if guest root or Docker bypasses Ubuntu UFW. DNS/DHCP, SSH/VS Code, virtual devices and the hypervisor remain deliberate attack surfaces. A separate editor profile is not an OS sandbox, and a host administrator can change any policy. Do not copy personal browser profiles, SSH private keys or broad GitHub/cloud credentials into the image or assignment VM. Public internet access also permits exfiltration of any secrets available to malicious guest code; use narrowly scoped, short-lived credentials and revoke them after the assignment.

Implementation is pending final validation; no successful isolation test is implied. The final run must check internet/DNS/package downloads and SSH/VS Code, negative host/LAN/peer and IPv6 probes (including guest root/container-published ports), rule-install failure, repeat/resume/destroy/name reuse, protected-file writes from an unelevated process, resource admission, and preservation of existing development VMs. Sources: [Microsoft extended/stateful ACLs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/create-security-policies-extended-port-access-control-lists), [adapter controls](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmnetworkadapter), [VS Code CLI isolation](https://code.visualstudio.com/docs/configure/command-line), [Workspace Trust](https://code.visualstudio.com/docs/editing/workspaces/workspace-trust), [Packer configuration](https://developer.hashicorp.com/packer/docs/configure) and [Packer checksums](https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_SHA256SUMS).

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

Terminal setup is self-contained. From a **normal PowerShell 5.1 or 7 window**, run:

```powershell
.\host\windows\terminal\Install-Terminal.ps1
```

`Install-Terminal.ps1` owns installation of **PowerShell 7, Windows Terminal and Starship** through the explicit WinGet package IDs and the `winget` source. Existing executables are reused without upgrading or reinstalling. App Installer/WinGet is needed only when a dependency is missing; the command reports how to obtain it if unavailable. The installer accepts the selected package/source agreements, and an individual package installer may request elevation. Process PATH is refreshed without changing persistent PATH. Failed installation or a still-missing executable stops before terminal configuration.

After dependencies are available, `Install-Terminal.ps1` prepares the prompt, pinned Nerd Font, Slate Glass and Terminal profiles directly. `Install-Host.ps1` delegates terminal preparation to this same entry point. Running terminal installation alone does not install VS Code, Git, WSL, Hyper-V or `wvm`, and does not create VMs.

There are two scripts under `host/windows/terminal/`: run `Install-Terminal.ps1` for installation and configuration; `PowerShell-Profile.ps1` is the runtime profile copied by the installer and loaded automatically in each new Workstation tab. The runtime loads Starship, available PSReadLine settings and an optional already-installed `wvm` shim. Configuration uses `%LOCALAPPDATA%\Workstation\Terminal`; existing `$PROFILE` files remain untouched. Console-only PSReadLine configuration is skipped with redirected input/output. No execution-policy change is made. Existing profile GUIDs, Slate Glass and 62% opacity are preserved. Setup makes Workstation the default in stable Windows Terminal settings, preserving comments and other settings and keeping the original settings in `settings.json.workstation-backup` before the first change.

Setup records the resolved Starship executable in `%LOCALAPPDATA%\Workstation\Terminal\runtime.json`. Both PowerShell profiles initialize Starship using that absolute path, so a new Terminal tab can refresh its environment without losing the prompt. If Starship is moved or reinstalled elsewhere, rerun terminal setup to refresh the recorded path. Opening a terminal does not install applications or change persistent PATH settings.

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

For custom VM sizes, switch names or usernames, use `host/windows/hyperv/New-WorkstationVM.ps1` directly as described by its parameters. The main setup flow prompts for resource sizes and uses the default switch and development username. VMs created manually or by an older bootstrap without an ownership record are not adopted automatically.

Isolated trials can pass `-KnownHostsFile` to keep their SSH host-key records separate from the user's normal `known_hosts`; strict host-key checking remains enabled.

## Windows state regression checks

Run `powershell.exe -NoProfile -File tests/windows/Test-VMState.ps1` or `pwsh -NoProfile -File tests/windows/Test-VMState.ps1`. These checks use generated filesystem fixtures, child PowerShell processes and mocked Hyper-V discovery. They require no administrator rights or Hyper-V, and verify atomic record replacement, path boundaries, interrupted deletion recovery, generation ownership, SSH host-key pinning across IP changes, stale-address rejection, MAC collision/concurrency refusal native stderr/exit-code handling, and asynchronous GUI launch argument quoting. `-TemporaryRoot` can select a writable scratch directory. The existing manual CI workflow also runs them on Windows PowerShell 5.1 and PowerShell 7.

Full Hyper-V integration trials require an elevated process. The backend installer accepts a fixed-format `ValidationId` only at installation; runtime requests cannot choose state paths. A validation package uses separate Program Files packages and `%ProgramData%\Workstation\Validation/<id>` state, plus separate local connection/editor files. This avoids changing production setup answers, selected images, SSH config or editor profiles. Validation namespaces are bound to the installing Windows SID. Their compact paths also stay within Hyper-V's legacy file path limits without changing Windows-wide long-path policy.

## Windows trial status

This workflow has not yet been run end to end on Windows. During the first trial, confirm both terminal profiles, SSH and Remote - SSH access, reboot recovery, interrupted Ansible recovery, and a repeated run that reuses the VM without provisioning it again. An unrelated VM or SSH alias must remain untouched.

References: [WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/install), [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh), [Catppuccin](https://github.com/catppuccin/windows-terminal) (MIT attribution in the repository's `LICENSE`), [Packer Hyper-V builder](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso), [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html).


### DHCP identity and reconnects

New temporary VMs keep a per-installation static, locally administered MAC and
use that MAC as their DHCP client identifier. A host-wide allocation lock checks
all registered VM and host adapters before assignment; a collision refuses the
operation instead of changing another VM. Existing records without a managed MAC
keep their current adapter identity. This is DHCP lease stability, not a static IP
reservation: Windows can still change the Default Switch subnet or lease.

`wvm open <name>` discovers the current address again and verifies both the pinned
per-instance SSH host key and `/etc/workstation-bootstrap-id` before returning it.
The SSH alias stays the same and its address is refreshed. A TCP listener alone
does not prove that a recycled address belongs to the intended VM. Multiple VMs
have separate identities, pins and connection directories.

Workstation does not guess an unused static IP on Default Switch or create a
second WinNAT. Microsoft's [NAT setup guide](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network)
requires guest address configuration and limits WinNAT to one internal NAT prefix.
A dedicated static-IP mode needs explicit ownership of a compatible NAT, subnet
overlap checks and an address allocator; it is not enabled by these changes.


### Validation checkpoint — 2026-11-04

This backup preserves work in progress. On the Windows 11 test host:

- Image creation, Ubuntu provisioning/sealing, child creation, repeated open,
  stop and interrupted-construction recovery passed. Recovery retained the same
  Hyper-V VM identity and differencing disk; an actual DHCP address change was
  handled with the guest's pinned SSH key and installation identity.
- Real Hyper-V policy installation passed. An injected ACL installation failure
  left the test adapter disconnected.
- Public DNS/HTTPS and a Python package index were reachable. Host and IPv4/IPv6
  peer canaries and a published container port were first verified reachable
  with narrow test allowances, then denied after removing them. Guest-firewall
  disablement and container probes did not bypass the Hyper-V boundary.
- Native password finalization, password-required sudo, root lock and effective
  SSH policy passed. Unelevated writes to the protected package/state were
  denied; repeated SSH-fragment/shortcut generation preserved a fixture alias.
- The original development/backup VM configuration snapshots matched after the
  network/account tests.
- Eighteen local regression checks passed on Windows PowerShell 5.1; twenty
  checks, including later GUI-launch argument checks, passed on PowerShell 7.

The isolated VS Code window/remote server did **not** become usable. Direct GUI
launch did not resolve it. The final real interrupted-deletion/name-reuse tests
were not reached; filesystem deletion-journal regressions passed separately.
Clean-machine portability and nested Windows testing remain unverified.

Before treating editor isolation as complete, also investigate current VS Code
`--shared-data-dir` behavior: Microsoft's [multi-instance launcher documentation](https://github.com/microsoft/vscode/blob/main/.agents/skills/launch/SKILL.md)
identifies application storage outside `--user-data-dir`. No personal account
storage was inspected or copied during this validation. Separate editor data and
extensions alone must not be presented as a complete account-isolation boundary.
