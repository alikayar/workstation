# Windows host setup

Install the optional host applications and `wvm` launcher here. [Hyper-V management](hyperv.md) covers VM creation, diagnostics, networking, storage and recovery. [Host connections](host.md) covers SSH and application previews.

Use a **normal, 64-bit PowerShell 5.1 or 7 window** for host setup. Hyper-V operations use a separate administrator window; installing the launcher does not create a VM or enable Hyper-V.

## The wvm command

With Git already available, obtain the checkout and install wvm in a **normal 64-bit PowerShell window**. If you already have the checkout, enter it and preserve any local changes instead of cloning again:

~~~powershell
git clone https://github.com/alikayar/workstation.git
Set-Location workstation
.\host\windows\wvm\Install-WVM.ps1
wvm help
wvm setup terminal    # Optional terminal setup
wvm setup vscode      # Optional VS Code setup and extensions
wvm setup codex       # Optional Windows Codex defaults and instructions
~~~

The installer places a managed CMD launcher, PowerShell dispatcher and checkout-location record under `%LOCALAPPDATA%\Workstation\bin`, adds that directory to the user's PATH once and updates the current PowerShell process PATH. It does not install terminal applications, change profiles, enable Hyper-V or create a VM. Reruns update only files marked as Workstation-managed; unrelated files, another existing `wvm` command and linked paths are refused. The installed dispatcher is a small forwarding script; command routing and all implementation code run directly from this checkout. Keep the checkout in place, and rerun installation after moving it. Other terminal processes may retain their old PATH; signing out and back in refreshes that environment. The CMD launcher runs inbox PowerShell 5.1 with process-only `RemoteSigned`; persistent execution policies and Group Policy are not changed. Downloaded scripts still need to be trusted/unblocked before use.

For a new VM, continue with [Hyper-V creation](hyperv.md#create-a-vm). For an existing environment, [connect over SSH](host.md).

## Codex host setup

Run `wvm setup codex` in a normal PowerShell window after installing/opening the Codex desktop app and making its native `codex.exe` CLI available on PATH. This command configures the existing Codex installation; it does not download Codex, sign in, enable Windows features or provision the VM.

The installer proposes `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, `features.prefer_mxc = true` and `windows.sandbox = "elevated"`. If the config API reports a nonempty `default_permissions` selector or a nonempty `permissions` table in the effective configuration, returned configuration layers or their named profiles, setup skips `sandbox_mode` entirely. It preserves permission profiles and does not introduce the legacy setting that could override them. An existing `sandbox_mode` is also left untouched in this case; setup does not automatically resolve a pre-existing mixed configuration. The other three defaults retain their normal conflict prompts. See [permission profile compatibility](https://learn.chatgpt.com/docs/permissions).

MXC is preferred when the device and policy support it; elevated is the documented legacy fallback, whose commands run without administrator privileges. Existing model choices, MCP servers, plugins and unrelated settings remain unchanged. Selected profiles and organization policy can override these user defaults. These are setup defaults, not an attestation of active permissions or a restriction on every host tool. See the [official Windows sandbox guide](https://learn.chatgpt.com/docs/windows/windows-sandbox).

Configuration is read and edited through the installed CLI's [official config API](https://learn.chatgpt.com/docs/app-server), over private standard input/output. There is no listening network port or agent conversation. Edits target only the base user `config.toml` in `CODEX_HOME` (default `%USERPROFILE%\.codex`); version checks reject concurrent edits. Invalid configuration or an unsupported API stops setup rather than rewriting TOML with a partial parser.

Missing settings are added, matching settings are left alone, and differing values show current/proposed values and ask `Override ...? [y/N]`. Enter preserves the current value. Windows instructions come from `host/windows/codex/Instructions.md` and are maintained in a marked block in the user's `AGENTS.md`; existing text outside that block is preserved, and updating a nonempty file requires confirmation. Changed files are backed up under their sibling `workstation-backups` directory. Setup refuses linked paths and concurrent setup for the same Codex home.

Skills are managed separately. Codex setup has no Git dependency, does not fetch an external skill repository and leaves existing skills unchanged.

Open a new chat after setup. For Ubuntu development, use the [SSH connection procedure](host.md#prepare-the-vm-and-connect-the-app); Workstation-created Ubuntu VMs already publish the host SSH alias after account setup. Codex setup leaves SSH keys, aliases, VM state and app connection records unchanged. Host and remote sessions retain separate [execution and security boundaries](security.md#host-applications-and-remote-execution).

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
