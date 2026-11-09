# Windows setup

This guide owns the optional Windows host applications, `wvm` command and Hyper-V image/VM lifecycle. Development inside Ubuntu is covered by [Ubuntu setup](getting-started.md); SSH connections and application previews are covered by the [host guide](host.md).

Use an **administrator, 64-bit PowerShell window** for VM/image operations on Windows 11 Pro x64. Installing wvm itself does not install host applications or create VMs. All user-facing operations go through wvm; the other scripts are implementation details.

Windows Pro VM creation requires Hyper-V. The Ubuntu command enables Hyper-V if disabled, then stops before downloading media or creating a VM and asks you to restart Windows and rerun it. Pending enable/disable changes also stop for a restart. No automatic reboot occurs. Ubuntu also needs the Windows OpenSSH Client optional feature. Existing development VMs are not altered. When testing inside another VM, the outer hypervisor must expose nested virtualization and leave sufficient RAM for both levels.

Choose the next task:

| Task | Section |
| --- | --- |
| Install or refresh the wvm launcher | [The wvm command](#the-wvm-command) |
| Inspect resources without changing VMs | [Host diagnostics](#read-only-host-diagnostics) |
| Start, stop or delete an existing VM | [VM lifecycle](#start-stop-and-delete-by-vm-name) |
| Configure host applications | [Codex](#codex-host-setup), [terminal](#terminal), [VS Code](#vs-code-defaults) |
| Build/reuse a base image | [Packer images](#packer-first-base-images) |
| Understand guest setup and networking | [Ubuntu clones](#ubuntu-server-2604-clones), [Windows clones](#windows-11-pro-clones) |
| Resume interrupted work and understand coverage | [Recovery and validation](#recovery-compatibility-and-validation) |

## Source layout

| Location | Responsibility |
| --- | --- |
| `host/windows/vscode/Install-VSCode.ps1` | VS Code detection, confirmed pinned installation, defaults and optional extensions |
| `host/windows/codex/` | Windows Codex defaults and managed instructions |
| `host/windows/terminal/` | Terminal dependencies, PowerShell startup, font and appearance |
| `host/windows/wvm/` | User command, per-user bootstrap installation and read-only doctor diagnostics |
| `host/windows/hyperv/windows-pro/` | Windows Pro image recipe and unattended setup |
| `host/windows/hyperv/ubuntu-26-04/` | Ubuntu creation, Packer recipe, host-enforced network policy, SSH/account finalization and recovery |
| `host/windows/hyperv/shared/Packer.ps1` | Pinned Packer installation and build process handling |
| `host/windows/hyperv/shared/Seed-ISO.ps1` | Shared native Windows ISO creation |
| `host/windows/hyperv/shared/VM-Resources.ps1` | Shared numeric resource validation |

Each VM command owns its recorded installation directory. Saved VM IDs, ownership tokens, disk paths and recovery payloads must be preserved; do not remove a VM's directory to resolve a resume error.

## The wvm command

Install wvm once from the cloned checkout in a **normal PowerShell window**:

~~~powershell
.\host\windows\wvm\Install-WVM.ps1
wvm help
wvm setup terminal    # Optional terminal setup
wvm setup vscode      # Optional VS Code setup and extensions
wvm setup codex       # Optional Windows Codex defaults and instructions
~~~

The installer places a managed CMD launcher, PowerShell dispatcher and checkout-location record under `%LOCALAPPDATA%\Workstation\bin`, adds that directory to the user's PATH once and updates the current PowerShell process PATH. It does not install terminal applications, change profiles, enable Hyper-V or create a VM. Reruns update only files marked as Workstation-managed; unrelated files, another existing `wvm` command and linked paths are refused. The installed dispatcher is a small forwarding script; command routing and all implementation code run directly from this checkout. Keep the checkout in place, and rerun installation after moving it. Other terminal processes may retain their old PATH; signing out and back in refreshes that environment. The CMD launcher runs inbox PowerShell 5.1 with process-only `RemoteSigned`; persistent execution policies and Group Policy are not changed. Downloaded scripts still need to be trusted/unblocked before use.

Then, in an **administrator PowerShell window**:

```powershell
wvm create
```

Choose **1: Ubuntu Server 26.04** (Enter accepts this default) or **2: Windows 11 Pro 25H2**. The selected installer then asks for its VM name and resources, showing defaults that Enter accepts. User/password setup, saved records, media verification, Packer and recovery remain owned by that installer. Existing installations resume through their original ownership checks, without automatic replacement. Windows and Ubuntu retain their different networking policies described below.

You can also select the OS directly and override individual settings:

```powershell
wvm create -OS windows-pro -VMRoot 'D:\VMs' -OpenConsole
wvm create -OS ubuntu-26-04 -VMName interview -CPUs 2 -MemoryGB 4
wvm list
```

`wvm list` reads all local Hyper-V VMs, including those created outside Workstation, and displays name, state, CPU count, assigned/startup memory and uptime. It never starts, stops or changes a VM. The account needs Hyper-V inventory access; use an administrator PowerShell window if access is denied. Create-only flags are refused for list.

Only explicitly supplied settings are forwarded. Each OS keeps its own VM name, storage root, disk-size default and validation. `-NestedVirtualization` is supported only with Windows Pro. Passwords are never CLI arguments. Help works without administrator rights; create does not elevate automatically.

### Read-only host diagnostics

```powershell
wvm doctor
wvm doctor -Detailed
& .\host\windows\wvm\wvm.ps1 doctor -Detailed -AsObject
wvm doctor -VMRoot 'D:\VMs' -ImageRoot 'D:\WorkstationImages'
```

Doctor does not require elevation to start. It reports unavailable providers, access-denied metadata and missing counters as **UNKNOWN**; rerunning from an administrator window can improve coverage. It never elevates, enables features, starts/stops VMs or services, mounts disks, runs guest commands, rewrites settings, installs tools or deletes anything. `-AsObject` returns the report for further processing when calling the checkout `wvm.ps1` directly, as above. The installed native/CMD launcher formats the result as text and does not preserve PowerShell objects across its default-text process boundary. No report file is written. VM/create/setup options are rejected.

#### Report coverage

The quick report includes Windows RAM availability and a conservative new-VM sizing hint, logical CPU count, VM vCPU/CPU and assigned/startup/demand/dynamic memory, integration status, fixed-drive free space, VHDX file/virtual sizes and parent/checkpoint references, adapter switches/IPs, managed VM identity and recovery records. RAM headroom reserves the larger of 2 GiB or 10% of visible host RAM; this is a heuristic, not an admission guarantee. Running guests may not expose memory demand/status, and host metrics cannot identify a guest application's RAM consumption. Hyper-V CPU percentages and Windows host-OS load are different measures and are not added together. For fixed-memory VMs, inactive dynamic-memory limits are omitted from the human report. Long disk/cache/review paths use separate lines so narrow terminals do not squeeze them into tiny columns; cleanup reasons are always printed.

Detailed mode takes three performance readings separated by five seconds. Disk latency is calculated from raw counters, not integer-rounded formatted seconds or localized counter names; an idle disk has unknown latency rather than a fabricated zero. CPU/latency readings are short workload samples, not proof of a bottleneck. Extra CIM, filesystem and network calls can extend total runtime beyond ten seconds. CPU, VM and disk providers are sampled independently: an unavailable provider does not discard the other measurements. Missing memory, CPU or volume counters are unavailable rather than zero.

#### Ubuntu policy and SSH observations

For identity-matching, completed Ubuntu VMs, doctor compares the saved policy identity, current Default Switch topology, live ACLs and adapter guards against the current policy recipe. It compares the owning user's managed SSH alias with the saved address without evaluating SSH config directives. Detailed mode probes only TCP/22 at the saved IPv4 address when that same address is currently reported by the running VM (one second per probe, five seconds combined wait budget). It does not scan subnets, read keys, authenticate, run SSH, verify server identity or test guest-to-host/LAN/internet traffic. Policy and SSH checks report independently, so a policy mismatch does not hide the address/SSH findings. Matching policy configuration is not a security attestation.

#### Record and cache discovery

Record discovery covers the default WindowsVMs/UbuntuVMs stores, the image store's `.builds`, optional `-VMRoot`, and records found above registered VM configuration paths. Custom/offline stores outside these locations are not discovered automatically. Store/image metadata inspection is capped at 200 directories per store/family. Only known diagnostic JSON filenames are read; installation secrets and Packer variable files are excluded. Linked paths are refused.

Detailed cache sizing inspects the selected image store and the default Workstation Media/Tools directories, deduplicating overlapping roots. It streams directory entries under a shared 20,000-entry/five-second traversal budget, skips reparse points and marks partial/error-limited totals explicitly. Sizes are logical file lengths, not guaranteed reclaimable physical space. The review list includes checkpoint chains, records without a registered VM, partial downloads, unpublished images and reusable ISOs/base images. Registered disk chains and mounted media references are checked across all readable VMs/checkpoints. **No registered reference observed** does not establish safe deletion: active/recoverable installations, partial clones, future reuse, unregistered workloads and external backups can still need those files. No cleanup command is invoked.

### Start, stop and delete by VM name

Use an administrator PowerShell window. Both positional names and `-VMName` are accepted:

```powershell
wvm list
wvm start interview
wvm start interview -OpenConsole
wvm stop interview
wvm delete interview -WhatIf
wvm delete interview
```

Start and stop accept an exact existing local VM name, including unmanaged VMs; wildcard matching is not used. Starting a running VM and stopping an Off VM are harmless repeats. Stop requests a normal guest shutdown and waits up to two minutes; it never silently cuts power. Saved/paused guests must be handled explicitly. Operations on managed VMs share their installer's lock and refuse active Packer/setup processes. A managed installation must be complete before start; use create to finish recovery otherwise. Ubuntu's isolation policy is refreshed while Off or verified before restoring a saved/running VM. This command does not refresh SSH aliases after a DHCP address change; rerun the Ubuntu create/resume command when that is needed.

Delete accepts any exact registered Hyper-V VM name, regardless of installer or installation-record version. Hyper-V supplies the VM ID, active disks and checkpoint disk chains. Before unregistering the VM and again before removing files, deletion checks all other VMs and checkpoints for shared disks (including parent VHDs), configuration and media references. Any conflict aborts deletion. Confirmation is required; the VM must be Off unless -Force explicitly permits power-off. -WhatIf performs discovery and reference checks without creating a journal or deleting anything.

For Workstation VMs, optional metadata with matching live VM ID/name/token identifies setup files, keys and the installation directory; its schema/backend are not used as eligibility criteria. Without metadata, cleanup removes the disks and VM-specific configuration/state files identified from Hyper-V, then empty directories. It does not guess ownership of unrelated files in a shared directory. Shared installation ISOs and tool caches are retained. A matching Ubuntu SSH-config block is removed for its owning user.

An administrator-only journal under %ProgramData%\Workstation\Deletions stores the exact file plan before unregistering. Rerunning the same delete command completes interrupted cleanup even after VM registration disappears. A new VM reusing the name is refused. A VM that was already unregistered before any deletion plan was captured is not guessed from stray files. No VM name has a special exemption.

## Codex host setup

Run `wvm setup codex` in a normal PowerShell window after installing/opening the Codex desktop app and making its native `codex.exe` CLI available on PATH. This command configures the existing Codex installation; it does not download Codex, sign in, enable Windows features or provision the VM.

The installer proposes `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, `features.prefer_mxc = true` and `windows.sandbox = "elevated"`. MXC is preferred when the device and policy support it; elevated is the documented legacy fallback, whose commands run without administrator privileges. Existing model choices, MCP servers, plugins and unrelated settings remain unchanged. Selected profiles and organization policy can override these user defaults. See the [official Windows sandbox guide](https://learn.chatgpt.com/docs/windows/windows-sandbox).

Configuration is read and edited through the installed CLI's [official config API](https://learn.chatgpt.com/docs/app-server), over private standard input/output. There is no listening network port or agent conversation. Edits target only the base user `config.toml` in `CODEX_HOME` (default `%USERPROFILE%\.codex`); version checks reject concurrent edits. Invalid configuration or an unsupported API stops setup rather than rewriting TOML with a partial parser.

Missing settings are added, matching settings are left alone, and differing values show current/proposed values and ask `Override ...? [y/N]`. Enter preserves the current value. Windows instructions come from `host/windows/codex/Instructions.md` and are maintained in a marked block in the user's `AGENTS.md`; existing text outside that block is preserved, and updating a nonempty file requires confirmation. Changed files are backed up under their sibling `workstation-backups` directory. Setup refuses linked paths and concurrent setup for the same Codex home.

Skills are managed separately. Codex setup has no Git dependency, does not fetch an external skill repository and leaves existing skills unchanged.

Open a new chat after setup. Host Codex and remote Codex use their own configuration: for development in Ubuntu, select the VM repository as an SSH project in Codex. Sending an SSH command from a host chat does not move that chat's skills or execution boundary into Ubuntu. This setup never imports VM credentials, private keys, authentication files, chat history, Linux-only tool commands or skills.

For Workstation-created Ubuntu VMs, create/resume already publishes the host SSH alias after account setup. Codex setup leaves SSH keys, aliases, VM state and app connection records unchanged. In Codex, open **Settings > Connections**, enable the existing SSH alias and select the remote repository folder. Codex discovers concrete aliases from the host user's SSH config; remote Codex installation and sign-in remain prerequisites. For an existing VM outside this workflow, prepare its SSH alias using the [host connection guide](host.md#add-a-host-side-ssh-alias). See the [official remote connection guide](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host).

## Packer-first base images

Packer builds a generalized **base image once per recipe fingerprint**. VM creation copies that disk into an independent writable VHDX, creates a new Hyper-V VM and applies instance-specific configuration. It does not run the ISO installer again when a matching verified image exists.

```powershell
# Optional explicit preparation, in administrator PowerShell:
wvm image build -OS windows-pro
wvm image build -OS ubuntu-26-04
wvm image list

# Automatically builds a missing base, then creates a separate instance:
wvm create -OS windows-pro -VMName interview-win -VMRoot 'D:\VMs'
wvm create -OS ubuntu-26-04 -VMName interview-linux -VMRoot 'D:\VMs'
```

`-ImageRoot` selects an absolute local image-store directory; the default is `%ProgramData%\Workstation\Images`. Both public `New-*VM.ps1` commands use the same pipeline. Guest OS/version, pinned media hash, recipe and build-helper hashes determine the image ID and versioned directory. Changing that specification produces a new version; a Ready image is never overwritten. Updating only wvm routing does not change the base recipe. Reuse is per specification, not a promise to keep an old OS patch level forever; update the recipe/revision deliberately when refreshing the baseline.

Image builds share verified **Packer 1.16.2 / Hyper-V plugin 1.1.5** under `%ProgramData%\Workstation\Tools`; they do not add tools to global PATH. Recipes live in each guest's `image/base.pkr.hcl`. Packer creates a uniquely named temporary builder under `Images\.builds`, seals it and captures its standalone disk. The build controller removes the temporary builder before publishing the image. A frozen hashed build payload and process records protect recovery. An unregistered failed builder or changed identity is never adopted/rebuilt automatically. Builders use **2 CPUs / 4 GiB RAM**, leaving 2 GiB for the host; initial builds require at least 80 GiB free on the Windows image-store drive or 40 GiB for Ubuntu to allow build/sealing/publication copies.

The store permits writes only by Administrators/SYSTEM. `base.vhdx` is marked read-only. A private pending manifest is written only after generalization has been verified; the public Ready manifest appears after owned builder cleanup. Publication can resume after an interruption. Before reuse, the wrapper verifies manifest identity, protected storage ACLs, SHA256 and standalone VHD size. These are locally built artifacts with recorded provenance, not Microsoft-signed VHD files. Vendor ISO verification remains unchanged.

Every VM receives a **full copy**, not a differencing child of the base. Its VHD identifier, VM ID, bootstrap token and (for Windows) local vTPM are new. Deleting a VM does not remove its base image; a base is not a runtime disk dependency. The requested virtual disk can grow beyond the base size, but cannot shrink it. Windows base size is 64 GiB; Ubuntu is 40 GiB. Offline Windows inspection/seeding is serialized to avoid simultaneous host attachments with shared GPT identifiers. Only trusted generalized builders and never-booted clone disks are mounted by the host; existing guest disks are not mounted for configuration.

## Ubuntu Server 26.04 clones

`wvm create -OS ubuntu-26-04` asks for name, resources and non-root user. Defaults remain `workstation-ubuntu-26-04`, **4 CPUs / 8 GiB / 80 GiB**, user `dev`; Enter accepts each default. Explicit parameters skip their questions. The new clone path accepts 4–32 GiB RAM. Ubuntu can enable Hyper-V when absent, then asks for a Windows restart and stops without creating a VM. Windows OpenSSH Client is required. During the initial questions, Ubuntu also asks **Install the Workstation development environment too? [Y/n]**. Enter (including whitespace-only input) accepts Yes; `n` skips it. Yes asks for the Git author name/email required by the existing playbook and saves the preference with the VM record. After account finalization, SSH and network isolation are ready, the selected configuration runs automatically inside Ubuntu as its non-root user. The VM remains ready if configuration fails; rerun **wvm configure VM_NAME** to retry or opt in later. Completed configuration is skipped by ordinary create/resume; configure explicitly reapplies the saved source snapshot.

The host uploads only tracked ansible/dotfiles source and ansible.cfg from this checkout (including working-tree edits), excluding local host_vars/localhost.yml, Git history and credentials. A hashed source bundle is retained for repeatable retries. The guest installs ansible-core, python3-debian and sudo, then runs ansible-playbook ansible/site.yml. The Git identity is supplied as non-secret extra variables. The initial account password stays in Ubuntu's passwd prompt; configuration asks for that sudo password once more in the guest terminal, shares it with package installation and Ansible through process input/anonymous pipes, and never stores it in VM records, archives, command arguments or files. Workstation is not baked into the reusable base image.

For an explicit opt-in without the yes/no question, use **wvm create -OS ubuntu-26-04 -ConfigureWorkstation**; Git identity questions still apply.

### Base image and account finalization

The base uses pinned **Ubuntu Server 26.04.1 amd64**, SHA256 `cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927`, downloaded from Canonical over HTTPS. The temporary builder has a locked-password account with unique temporary client/server SSH keys. A strictly pinned SSH session waits for cloud-init, removes the build account, SSH host keys, temporary sudo access, installer/cloud-init state and machine identity, then runs `cloud-init clean --logs --machine-id --seed`. A token-specific sealing attestation and verified normal shutdown are required before image publication. Builder credentials and seed media are removed with its owned build directory.

A clone gets a new NoCloud CIDATA seed, hostname/instance ID, SSH client and pinned SSH server identity. Cloud-init creates the chosen user with a locked password and temporary bootstrap sudo, grows the root filesystem and configures Turkish Q, English UI and Istanbul timezone inherited from the base. The user enters the console/sudo password through Ubuntu's `passwd` over pinned SSH; it is never a CLI argument, Packer variable or host password file. Finalization locks root and replaces passwordless bootstrap sudo with password-protected sudo. Host policy is applied before first boot. After completion, the seed and temporary host-key copies are detached/removed; the client key stays on the host, and the SSH alias is published. Cloud-init's per-instance cache is explicitly retained across reboots after seed removal; the generalized base has no such instance cache.

### Network isolation

`Ubuntu-Network.ps1` owns the policy on the recorded VM's single Hyper-V adapter. It uses Microsoft's [extended port ACLs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/create-security-policies-extended-port-access-control-lists) for stateful IP filtering and [adapter guards](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/jj679878(v=ws.11)). Guest root cannot remove these host-side rules.

| Traffic | Policy |
| --- | --- |
| VM to public IPv4 TCP/UDP services | Allowed with return traffic tracked |
| Host Default Switch address to VM TCP 22 | Allowed with stateful SSH replies |
| VM to host, private/shared/link-local ranges and connected LAN prefixes | Denied, except the infrastructure traffic below |
| VM to gateway DNS TCP/UDP 53 | Allowed; no other host application ports are opened |
| DHCP client UDP 68 to gateway/broadcast UDP 67; gateway replies | Allowed |
| VM to other guests' addresses on the Default Switch | Denied by the private-address destination restrictions |
| IPv6 and other IP protocols, including ICMP/ping and protocol-41 tunnels | Denied |
| Unsolicited inbound connections | Denied, except host SSH and DHCP replies |

Blocked prefixes include host IPv4 addresses and connected on-link routes, so public-address LANs are covered as well as RFC1918 networks. MAC spoofing, teaming, port mirroring and SR-IOV bypass are disabled; DHCP and router guards are enabled. Wildcard MAC ACLs are not installed: both the combined and egress-only variants broke Default Switch boot networking during live testing; the IP-only comparison restored SSH. Prior managed MAC rules are removed during the journaled update. This is TCP/UDP IP connection isolation on a shared switch, not layer-2 separation: ARP/broadcast visibility, raw Ethernet covert channels and broadcast denial of service remain outside its guarantee. A separately segmented network is needed when untrusted guests must not share layer 2. Internet access can still transmit guest data to Internet services; proxies, host-configured port forwarding and hypervisor vulnerabilities are outside this policy's guarantee.

For new image-backed clones, the policy is installed **while Off before the first guest boot**. The isolated Packer builder runs only pinned, trusted installation content and is deleted after sealing; do not run untrusted code there. Do not run untrusted code during installation. For an existing installed VM, shut it down normally, then rerun the same `wvm create -OS ubuntu-26-04` command; it installs the policy and resumes that VM without reinstalling Ubuntu or resetting the password. A running VM without a policy is refused, not forcibly stopped. A saved VM needing changes must first be resumed and shut down normally.

`network-policy.json` records the VM, adapter, ownership token, topology and exact managed rules. Policy changes are journaled before mutation and verified by reading the adapter back. Interrupted installation leaves an `Applying` journal and the VM Off; rerun to reconcile only recorded rules. Foreign ACLs or a replaced adapter cause a refusal. An unchanged policy is not rewritten. No background service or scheduled task is installed.

**Before switching Wi-Fi, VPN, host interface addresses or Default Switch configuration, shut down an untrusted VM.** Rerun setup while it is Off to refresh the topology and policy. Setup checks the topology again before starting a VM and refuses stale rules on a running/saved VM. This is not continuous network-change monitoring; starting a VM directly in Hyper-V Manager bypasses these wrapper checks. Never treat an old policy as protecting newly added public-address LANs or host addresses without refreshing it.

### Network validation evidence

Live validation on Windows 11 Pro on 2026-11-05 passed **26 checks** with the IP-only policy. Positive baselines first established reachable host TCP/UDP, peer TCP/UDP, host IPv6, LAN TCP ports 53/80/443, DNS UDP and Internet HTTPS. After policy installation, two shutdown/start cycles preserved pinned host SSH, DNS UDP and HTTPS while denying the tested host TCP/UDP, peer TCP/UDP, host IPv6 and previously reachable LAN services. A separate host-to-peer UDP control confirmed the peer remained responsive. Unchanged reapplication and recovery from an `Applying` journal with a missing rule passed; dev-vm was unchanged and the temporary peer/disk/firewall rules were removed.

The Default Switch DNS proxy did not answer TCP before isolation, so DNS-over-TCP service was not counted as a successful availability test. Peer ARP neighbor entries remained visible, consistent with shared layer 2; these tests establish the listed IP connection behavior, not protection against forged raw Ethernet or a general penetration-test guarantee. Source parsing and offline mocks alone must never be reported as live isolation validation.

## Windows 11 Pro clones

`wvm create -OS windows-pro` keeps defaults `workstation-windows-pro`, **4 CPUs / 8 GiB / 120 GiB**, user `dev`. Names and omitted resources are interactive; Enter accepts defaults. `-NestedVirtualization` exposes virtualization extensions on the new VM. Generation 2, Microsoft Windows Secure Boot, a fresh local vTPM, fixed RAM, disabled automatic checkpoints/auto-start and disabled Guest Service Interface are applied before its first boot. Use basic VMConnect for untrusted work; enhanced sessions can redirect host resources. Windows' Internal switch is not the Ubuntu network-isolation policy.

The Packer base installs **Windows 11 Pro 25H2** into Audit Mode, without creating the final user or asking for a password. An audit task runs Sysprep `/generalize /oobe /shutdown /mode:vm`. The host requires normal shutdown, the matching image/build token and the offline SOFTWARE hive's `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` state. It never publishes a merely powered-off, unverified installation. Windows recovery is placed before the final C: partition so C: can grow in clones.

For a new instance, the parent asks for the chosen user's password twice as SecureString. It writes a per-instance answer file and explicit Setup pointer into the **never-booted private disk copy**, without a Windows PE partitioning pass. Setup specializes that copy, creates the new account, grows C: and applies English UI, Turkish Q, Turkey regional formats and Istanbul timezone. The password is recoverable in that protected clone until Windows consumes/cleans the answer file; it is never in the base image, build variables, command line or VM JSON. PowerShell Direct verifies the VM ID, disk, per-instance token and Setup completion, then removes cached answer files. No SSH/WinRM listener is opened for this flow. A pending clone resumes with the original password; a completed clone does not ask again.

Installation media is pinned in `host/windows/hyperv/windows-pro/Windows-Media.ps1` to **Windows 11 25H2, build 26200.6584, x64, English (United States), multi-edition including Pro**. The SHA256 is `D141F6030FED50F75E2B03E1EB2E53646C4B21E5386047CB860AF5223F102A32`, originally published in the English 64-bit row on [Microsoft's download page](https://www.microsoft.com/ja-jp/software-download/windows11?msockid=2d54d98863066df52f04cf0962136c58). The current download page may list a newer release; updating it never changes this repository's pin. The fixed Microsoft CDN URL was published in this [Microsoft Q&A answer](https://learn.microsoft.com/en-us/answers/questions/6020251/i-need-a-direct-download-link-for-the-windows-11-2) and checked on 2026-11-04.

The command downloads directly from that pinned HTTPS URL into `%ProgramData%\Workstation\Media`. It does not call the temporary-link API, ask for a URL, change regions, or use third-party mirrors. Redirects are refused. If Microsoft removes the file or the network fails, it stops with the download error; there is no silent upgrade or unverified fallback. A verified existing cache is reused; a mismatching cache is preserved and refused. Downloads use a temporary `.partial` file which is removed on handled failure and published as an ISO only after verification. A forcibly terminated process can leave a partial file; it is never treated as a completed ISO.

An ISO is not an Authenticode-signed executable. The command verifies the entire ISO against Microsoft's pinned SHA256, then checks the **Microsoft Authenticode signature on the ISO's `setup.exe`**, plus the Pro edition, x64 architecture and exact image build. It never executes Windows Setup on the host. Enterprise Evaluation and Pro N media are rejected. To supply a previously downloaded copy, use `-IsoPath 'D:\ISO\Windows11-x64.iso'`; it must match the same pin. There is no caller-provided checksum override. Changing release requires reviewing and updating the media pin in the repository.

## Recovery, compatibility and validation

Both guests use the same schema-1 record format with an explicit guest type. Packer prepares reusable base images; all VM creation copies a base image. There is no ISO-per-VM installer, old-record migration or compatibility dispatcher.

VM IDs, ownership tokens, settings and bootstrap-source hashes are saved before mutations. Missing/replaced VMs, changed disks/records/payloads, concurrent operations and unrecorded resources are refused. Partial clone copying uses a private temporary disk and recorded source hash; no existing disk is overwritten to retry an installation. A clone's original base is needed only until the initial disk copy completes. Windows offline seeding is never repeated after the record enters its first-boot phase. Account finalization and seed cleanup can resume without resetting an already-completed password. `wvm start/stop/delete` use image-backed VM records and Ubuntu isolation checks.

The image/clone architecture still needs fresh Hyper-V end-to-end validation for **both OSes**, including two clones, distinct guest identities, interrupted build/publication/first-boot recovery, repeated creation and deleting a clone while keeping the base. Parser, HCL validation and mocked checks are not evidence of a live image build. Existing VM disks and state must remain unchanged during that validation.

## Terminal

Terminal setup is self-contained. From a **normal PowerShell 5.1 or 7 window**, run:

```powershell
wvm setup terminal
```

`Install-Terminal.ps1` owns installation of **PowerShell 7, Windows Terminal and Starship** through the explicit WinGet package IDs and the `winget` source. Existing executables are reused without upgrading or reinstalling. App Installer/WinGet is needed only when a dependency is missing; the command reports how to obtain it if unavailable. The installer accepts the selected package/source agreements, and an individual package installer may request elevation. Process PATH is refreshed without changing persistent PATH. Failed installation or a still-missing executable stops before terminal configuration.

After dependencies are available, `Install-Terminal.ps1` prepares the prompt, pinned Nerd Font, Slate Glass and Terminal profiles directly. The terminal setup command uses this same entry point. Running terminal installation alone does not install VS Code, Git, WSL or Hyper-V, and does not create VMs.

There are two scripts under `host/windows/terminal/`: use `wvm setup terminal` for installation and configuration; `PowerShell-Profile.ps1` is the runtime profile copied by the installer and loaded automatically in each new Workstation tab. The runtime loads Starship and available PSReadLine settings. Configuration uses `%LOCALAPPDATA%\Workstation\Terminal`; existing `$PROFILE` files remain untouched. Console-only PSReadLine configuration is skipped with redirected input/output. No execution-policy change is made. Existing profile GUIDs, Slate Glass and 62% opacity are preserved. Setup makes Workstation the default in stable Windows Terminal settings, preserving comments and other settings and keeping the original settings in `settings.json.workstation-backup` before the first change.

Setup records the resolved Starship executable in `%LOCALAPPDATA%\Workstation\Terminal\runtime.json`. Both PowerShell profiles initialize Starship using that absolute path, so a new Terminal tab can refresh its environment without losing the prompt. If Starship is moved or reinstalled elsewhere, rerun terminal setup to refresh the recorded path. Opening a terminal does not install applications or change persistent PATH settings.

## VS Code defaults

See [VS Code configuration](vscode.md) for host/remote terminal defaults, preserved user settings, browser behavior and optional extensions. `wvm setup vscode` applies the Windows VS Code defaults; terminal setup is separate.
