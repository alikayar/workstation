# Windows setup

Windows features have separate entry points. Run terminal/application setup in a **normal PowerShell window**; run VM creation/removal in an **administrator, 64-bit PowerShell window** on Windows 11 Pro x64.

```powershell
# Terminal only
.\host\windows\terminal\Install-Terminal.ps1

# Optional VS Code installation plus the same terminal setup
.\host\windows\Install-Host.ps1
```

Windows Pro VM creation requires Hyper-V to be enabled beforehand. The Ubuntu command enables Hyper-V if disabled, then stops before downloading media or creating a VM and asks you to restart Windows and rerun it. Pending enable/disable changes also stop for a restart. No automatic reboot occurs. Ubuntu also needs the Windows OpenSSH Client optional feature. Existing development VMs are not altered. When testing inside another VM, the outer hypervisor must expose nested virtualization and leave sufficient RAM for both levels.

## Source layout

| Location | Responsibility |
| --- | --- |
| `host/windows/Install-Host.ps1` | VS Code installation and terminal setup |
| `host/windows/terminal/` | Terminal dependencies, PowerShell startup, font and appearance |
| `host/windows/hyperv/windows-pro/` | Windows Pro creation, unattended setup and owned-VM removal |
| `host/windows/hyperv/ubuntu-26-04/` | Ubuntu creation, Packer recipe, SSH/account finalization and recovery |
| `host/windows/hyperv/shared/Seed-ISO.ps1` | Shared native Windows ISO creation |
| `host/windows/hyperv/shared/VM-Resources.ps1` | Shared numeric resource validation |

Each VM command owns its recorded installation directory. Saved VM IDs, ownership tokens, disk paths and recovery payloads must be preserved; do not remove a VM's directory to resolve a resume error.

## Standalone Ubuntu Server 26.04 VM

Run the new standalone flow in an **administrator, 64-bit PowerShell** on Windows 11 Pro x64 with Windows OpenSSH Client enabled:

```powershell
& '.\host\windows\hyperv\ubuntu-26-04\New-UbuntuVM.ps1' -VMRoot 'D:\VMs' -OpenConsole
```

Windows PowerShell 5.1 and PowerShell 7 (including 7.6) use the same inbox 5.1 worker. This command prepares pinned **Packer 1.16.2** and its **Hyper-V plugin 1.1.5**, then runs the recipe in `ubuntu-26-04/ubuntu.pkr.hcl`. Packer lives under `%ProgramData%\Workstation\Tools\Packer\1.16.2`, with administrator/SYSTEM write access; no global installation or PATH change is made. The archive hash is pinned, and the executable is checked against that verified archive before use. The command does not apply Ansible or change existing development VMs. Hyper-V is enabled when needed; rerun after the requested Windows restart.

New installations ask for the VM name, CPU count, RAM, disk and non-root user, displaying defaults: `workstation-ubuntu-26-04`, **4 CPUs / 8 GiB / 80 GiB**, user `dev`. Enter accepts each default; explicit parameters skip its question. This pinned Hyper-V plugin supports at most **32 GiB RAM**, so the prompt and parameter reject larger values before a build. Answers are saved in `<VMRoot>\<VMName>\ubuntu-vm.json`; a rerun reuses saved resources and rejects conflicting parameters. Changing saved VM settings is not a resize operation.

Media is **Ubuntu Server 26.04.1 LTS amd64**, with SHA256 `cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927`, pinned from [Canonical's checksums](https://releases.ubuntu.com/26.04/SHA256SUMS). It downloads from Canonical over HTTPS into `%ProgramData%\Workstation\Media`; an existing cache or optional `-IsoPath` must match the same hash. Packer receives the verified local ISO and checks the same pinned SHA256; its shared download cache is `%ProgramData%\Workstation\Media\Packer`. No caller-provided checksum override is accepted. Updating the pin requires a source change; this is a pinned SHA256 check, not an on-host GPG signature verification.

The Generation 2 VM has one dynamic VHDX, fixed RAM, Ubuntu Secure Boot, automatic checkpoints disabled and Guest Service Interface file copy disabled by the first host provisioner. The wrapper creates the `machines` parent directory before Packer runs. Packer keeps the registered VM and its original disk under `<VMRoot>\<VMName>\machines`; the record stores the actual Hyper-V ID and disk path. It uses an existing Internal switch (normally Default Switch) for DHCP and outbound internet. It does not allocate static IPs or modify host firewall/NAT rules. Internal networking alone does **not** isolate the host or other guests from malicious code.

Following [Canonical's autoinstall method](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html), the command attaches a CIDATA seed and enters the initial `autoinstall ds=nocloud` boot command through the owned VM's virtual keyboard. The installer handles English UI, Turkish Q keyboard, Europe/Istanbul timezone, the new disk, security updates and SSH without user selection screens. No HTTP seed server or inbound host firewall exception is needed. The installer refuses to partition a disk that already has partitions.

Windows OpenSSH is used through Packer host provisioners (`communicator = "none"`) so every guest connection retains strict host-key pinning. First boot/cloud-init must finish, then the guest shuts down gracefully. Startup/checkpoint settings are applied only while the guest is Off, before Packer exports it. If a build stops after recording VM ownership, rerunning the command completes this same first-boot/shutdown/policy sequence without restarting Packer. No forced shutdown is used. The wrapper starts the retained VM for the interactive account step. A separate client Ed25519 identity is generated automatically for each VM; no existing user key is imported or replaced. A unique SSH server identity is generated in the protected setup directory and supplied on first boot. Its public key is pinned before any SSH connection. The client private key stays on the host. The temporary server key and seed are readable only to the creating account, Administrators and SYSTEM through the VM directory's protected ACL; seed media contains the server private key, **not a user password**. Once account finalization succeeds, the script detaches installation media, removes the host seed and temporary server key copies and removes the redundant Packer export after checking for references from other VMs/checkpoints. This flow creates an individual VM; workstation provisioning is a separate step. Root-only installer/cloud-init records inside the guest may retain the supplied server key.

The host waits for a guest-reported IPv4 address, verifies its pinned SSH key and installation token and confirms Ubuntu 26.04. The guest installs `linux-cloud-tools-virtual` and starts/checks `hv-kvp-daemon`, which supplies Hyper-V's IP information. Waiting messages distinguish a missing guest IP report from an SSH failure and include the last connection error. Stale or changed DHCP addresses are probed afresh, not trusted from the saved record. Ubuntu's own `passwd` then asks for the console/sudo password twice over an authenticated SSH terminal. This is the only account interaction after the initial host questions; no Ubuntu installer screens need answering. Passwords never enter PowerShell variables, arguments, JSON, ISO or host files. Ubuntu controls password acceptance. Root remains locked, SSH root/password login is disabled, and sudo requires the user password. Temporary bootstrap passwordless sudo is removed during finalization; do not run untrusted code before this step completes.

Ubuntu's live installer disables cloud-init after its first boot. Readiness therefore requires all four saved cloud-init stages to have finished without errors and the `boot-finished` marker, rather than requiring a current `done` status. The expected warning about leaving the bootstrap account's blank password locked is accepted; other warnings stop setup for inspection. The account password is still set only through interactive `passwd`.

After successful setup, a managed block in the creating user's `~/.ssh/config` enables `ssh <VMName>` with the VM's own identity and pinned server key. Other config contents are preserved; an existing explicit alias outside this installation's block is refused. Rerunning setup refreshes the verified DHCP address and updates the same block without duplicating it. The alias does not discover a changed IP by itself: rerun `New-UbuntuVM.ps1` when the VM's DHCP address changes. Run setup as your own Windows account with elevation, rather than as a different administrator account.

Reruns use the recorded VM ID, ownership token, resources and disk. They do not reinstall, reset a completed password or adopt a replaced/missing VM. The recipe, helpers and account finalizer are copied into a hashed recovery payload before building; a changed payload is refused. `packer build -on-error=abort` retains failed build state. A recorded, installed VM resumes over pinned SSH without invoking Packer again. A failure before the first Packer host provisioner records ownership requires inspection; an unrecorded VM or leftover build disk is never adopted/rebuilt automatically. Existing records from the uncommitted direct-Hyper-V prototype are also refused. Additional disks, checkpoints or changed network attachments cause a refusal. Concurrent operations on the same VM name, or a still-running recorded Packer/setup process, are refused. Switch names use letters, digits, spaces, underscores, dots or hyphens; paths containing shell expansion characters are rejected before reaching the Packer driver.

The HCL recipe has been checked with the pinned Packer and plugin using `packer validate`. The new path still needs a real Hyper-V run, including first boot and interrupted/resumed setup; parsing, configuration validation and mocked checks do not establish end-to-end readiness. Follow the [Ubuntu setup guide](getting-started.md) inside the installed guest when ready to apply Ansible.

## Windows 11 Pro test VM

`host/windows/hyperv/windows-pro/New-WindowsProVM.ps1` creates a separate Windows VM for testing the host tooling. It is independent of the Ubuntu installer. Run it in an **administrator, 64-bit PowerShell** window on Windows 11 Pro x64 with Hyper-V already enabled. Windows PowerShell 5.1 and PowerShell 7 (including 7.6) use the same inbox Windows PowerShell 5.1 worker; PowerShell 7 does not load Hyper-V through compatibility-session proxies. No PowerShell installation, execution-policy change or automatic elevation is performed.

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

## Terminal

Terminal setup is self-contained. From a **normal PowerShell 5.1 or 7 window**, run:

```powershell
.\host\windows\terminal\Install-Terminal.ps1
```

`Install-Terminal.ps1` owns installation of **PowerShell 7, Windows Terminal and Starship** through the explicit WinGet package IDs and the `winget` source. Existing executables are reused without upgrading or reinstalling. App Installer/WinGet is needed only when a dependency is missing; the command reports how to obtain it if unavailable. The installer accepts the selected package/source agreements, and an individual package installer may request elevation. Process PATH is refreshed without changing persistent PATH. Failed installation or a still-missing executable stops before terminal configuration.

After dependencies are available, `Install-Terminal.ps1` prepares the prompt, pinned Nerd Font, Slate Glass and Terminal profiles directly. `Install-Host.ps1` delegates terminal preparation to this same entry point. Running terminal installation alone does not install VS Code, Git, WSL or Hyper-V, and does not create VMs.

There are two scripts under `host/windows/terminal/`: run `Install-Terminal.ps1` for installation and configuration; `PowerShell-Profile.ps1` is the runtime profile copied by the installer and loaded automatically in each new Workstation tab. The runtime loads Starship and available PSReadLine settings. Configuration uses `%LOCALAPPDATA%\Workstation\Terminal`; existing `$PROFILE` files remain untouched. Console-only PSReadLine configuration is skipped with redirected input/output. No execution-policy change is made. Existing profile GUIDs, Slate Glass and 62% opacity are preserved. Setup makes Workstation the default in stable Windows Terminal settings, preserving comments and other settings and keeping the original settings in `settings.json.workstation-backup` before the first change.

Setup records the resolved Starship executable in `%LOCALAPPDATA%\Workstation\Terminal\runtime.json`. Both PowerShell profiles initialize Starship using that absolute path, so a new Terminal tab can refresh its environment without losing the prompt. If Starship is moved or reinstalled elsewhere, rerun terminal setup to refresh the recorded path. Opening a terminal does not install applications or change persistent PATH settings.
