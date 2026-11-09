# VS Code on Windows and Ubuntu

Workstation manages separate Windows host and Ubuntu Remote-SSH defaults. Windows setup reviews conflicting preferences interactively; Ubuntu adds missing remote settings while preserving existing values.

## Apply defaults

Run in normal Windows PowerShell from an installed [wvm setup](windows.md#the-wvm-command):

```powershell
wvm setup vscode
```

Setup reuses an existing Stable installation. If absent, it asks before installing the pinned x64 User Setup; No stops before settings or extension changes. It then asks whether to install Remote SSH, Catppuccin and vscode-icons; Enter accepts, `n` skips the bundle. No PowerShell 7 installation is required. Run `wvm setup terminal` separately for PowerShell, Windows Terminal and Starship.

For Ubuntu remote settings, run from the repository root inside Ubuntu:

```sh
ansible-playbook ansible/site.yml --tags vscode
```

## Settings ownership and recovery

Host defaults live in `host/windows/vscode/settings.json`; remote defaults live in `dotfiles/vscode/remote-settings.json`. Windows selects the PowerShell profile and Nerd Font prepared by terminal setup; Ubuntu selects Zsh. Shell integration is enabled, scrollback is 1,000 lines and closed windows do not automatically revive terminal processes. Persistence across window reloads is retained.

The Windows installer adds missing settings and skips identical values. For each different value, including nested profiles and exclusions, it shows Current/Proposed and asks `Override this value? [y/N]`. Enter keeps the current value; Yes replaces only that value. No unrequested keys are removed. Confirmed values no longer prompt on repeat; declined differences are offered again on later interactive runs. JSONC comments and trailing commas are accepted; invalid files are left untouched. A changed Windows write atomically saves the previous file as `settings.json.workstation.bak` (the latest pre-change backup) and normalizes the active file to JSON. If the file changes while setup is asking questions, setup stops so the new contents can be reviewed. Identical runs do not rewrite it.

The Ubuntu Ansible role runs its helper directly from the local playbook without installing runtime helper/config copies. It supports read-only Ansible check mode, adds missing remote settings and preserves existing values without prompting. Its first-change backup is retained. Settings Sync, named profiles and workspace settings may override these defaults. Remote settings target the standard VS Code Stable SSH server.

The integrated browser uses remote HTTP/HTTPS proxying and workspace storage unless an existing preference overrides them. Remote proxying is a preview feature and is not a VM isolation boundary. Select ephemeral storage in VS Code for disposable browser sessions.

## Extensions and appearance

The optional bundle installs Remote SSH, Catppuccin and vscode-icons locally. Different active theme/icon choices use the same override prompt; otherwise Catppuccin Macchiato and vscode-icons are selected. Installed extension IDs and versions are inspected first; existing versions (including disabled extensions) are left alone, and only missing IDs are installed. Other theme/icon extensions are not treated as package conflicts and are not uninstalled. Language-specific extensions are left to the user and project; Ansible tooling belongs in Ubuntu.

## Resource use and privacy

Remote settings exclude `.venv`, `__pycache__` and `.pytest_cache` from watching and search. Language servers have separate indexing settings. Put build-directory exclusions and language-server limits in the relevant project. These defaults impose no global Node heap cap and promise no fixed memory saving.

Use VS Code Process Explorer while the affected project is open to investigate memory. Include remote extensions, language servers, terminals and development servers in the measurement.

Host defaults disable built-in AI features and VS Code telemetry, hide extension recommendations and vscode-icons version notices, and open Markdown as text. Red Hat telemetry defaults to disabled on both host and remote. Different existing host preferences require explicit override approval; these telemetry settings do not control every third-party extension.

## Pinned Windows installation

The [Windows installer](../host/windows/vscode/Install-VSCode.ps1) owns the initial Stable version, Microsoft download URL and SHA256 pin. It requires both the expected checksum and a valid Microsoft Corporation Authenticode signature. Installation is user-scoped and does not launch VS Code or reboot Windows. Existing versions are neither upgraded nor downgraded; automatic updates remain under the user's existing policy. There is no generic applications installer or WinGet dependency for VS Code.

Settings parsing preserves JSON scalar types, nested arrays and date-like strings on PowerShell 5.1 and 7.x. JSONC comments are removed before handling trailing commas. Optional extensions are installed after conflict review and before writing settings, so an installation failure does not activate an unavailable theme.
