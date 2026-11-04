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
| `host/windows/Install-Host.ps1` | Install host applications and invoke terminal setup |
| `host/windows/terminal/` | Terminal profiles, startup script and Slate Glass palette |
| `host/windows/hyperv/` | VM bootstrap, resource inputs and Packer template |
| `host/windows/hyperv/commands/` | Temporary VM commands, ownership checks, image factory and seed ISO |
| `host/windows/hyperv/guest/` | SSH account finalization and Ubuntu bootstrap payload scripts |

Saved payloads keep their existing filenames and state directories. Recovery reads source files from the recorded Git revision and supports both the current and previous flat source layout.

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

Setup records the resolved Starship executable in `%LOCALAPPDATA%\Workstation\Terminal\runtime.json`. Both PowerShell profiles initialize Starship using that absolute path, so a new Terminal tab can refresh its environment without losing the prompt. A portable or Sandbox installation can use `host/windows/terminal/Set-Terminal.ps1 -StarshipPath C:\path\to\starship.exe` after placing the executable at its final location. If Starship is moved or reinstalled elsewhere, rerun terminal setup to refresh the recorded path. Opening a terminal does not install applications or change persistent PATH settings.

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
