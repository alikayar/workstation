# VS Code on Windows and Ubuntu

Workstation manages separate Windows host and Ubuntu Remote-SSH defaults. Windows setup reviews conflicting preferences interactively; Ubuntu adds missing remote settings while preserving existing values.

## Apply defaults

Run in normal Windows PowerShell from an installed [wvm setup](windows.md#the-wvm-command):

```powershell
wvm setup vscode
```

Setup reuses an existing Stable installation. If absent, it asks before installing the pinned x64 User Setup; No stops before settings or extension changes. It then asks whether to install Remote SSH and the bundled static Workstation appearance; Enter accepts, `n` skips both. Only Remote SSH is downloaded from the Marketplace; appearance files come from this checkout. No PowerShell 7 installation is required. Run `wvm setup terminal` separately for PowerShell, Windows Terminal and Starship.

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

The optional bundle requires VS Code 1.104.0 or newer and installs Remote SSH and the local `workstation-local.appearance` package. An older VS Code installation is retained; update it explicitly or skip the bundle. Different active theme/icon choices use the same override prompt; otherwise Workstation Macchiato and Workstation Icons are selected. Installed extension IDs and versions are inspected first; existing Remote SSH versions (including disabled installations) are left alone. Language-specific extensions are left to the user and project; Ansible tooling belongs in Ubuntu.

The [appearance directory](../host/windows/vscode/appearance/package.json) contains fixed Catppuccin Macchiato, Mocha, Frappé and Latte themes from 3.19.0 and the icon mappings and referenced images from vscode-icons 13.0.0. It declares only theme contributions, with no JavaScript, extension entry points, commands, runtime dependencies or upstream project-detection/customization behavior. SVG images retain their original bytes; icon mapping paths are relocated. Source release URLs and archive SHA256 values are recorded in the manifest. Required attribution and licenses travel with the package; there is no upstream build or download during appearance installation.

Setup copies the package into `%USERPROFILE%\.vscode\extensions\workstation-local.appearance-1.1.0`, staging the complete directory before moving it into place. Linked paths, executable asset types, runtime manifest entries and differing contents at the same installed version are refused. Identical contents are left alone. Restart VS Code after installation so it discovers the local package. Use Preferences: Color Theme to select Workstation Macchiato, Workstation Mocha, Workstation Frappé (dark themes), or Workstation Latte (light theme); Macchiato remains the setup default. This package has a separate identity from the Marketplace themes and does not receive their updates. It reduces third-party runtime/update exposure; it does not sandbox VS Code or remove image/parser risks.

To migrate an existing setup, accept the proposed theme/icon setting replacements when running `wvm setup vscode`, restart VS Code, and confirm that Workstation Macchiato and Workstation Icons display correctly. Then uninstall `catppuccin.catppuccin-vsc` and `vscode-icons-team.vscode-icons` from the local Extensions view. Setup warns if these upstream packages are present but does not remove or disable them automatically. Selecting the local appearance alone does not remove the old packages or their update risk. Other themes and icon extensions are preserved. If an extension allowlist is configured separately, it must permit `workstation-local.appearance`.

For a deliberate appearance update, review the selected upstream release, replace only the required static assets and mapping/theme data, preserve required notices, update provenance and bump the local package version. Setup will install the new version without replacing old package directories; account for and remove superseded local versions explicitly. Do not introduce an upstream installer, runtime code or automatic refresh for these assets.

## Resource use and privacy

Remote settings exclude `.venv`, `__pycache__` and `.pytest_cache` from watching and search. Language servers have separate indexing settings. Put build-directory exclusions and language-server limits in the relevant project. These defaults impose no global Node heap cap and promise no fixed memory saving.

Use VS Code Process Explorer while the affected project is open to investigate memory. Include remote extensions, language servers, terminals and development servers in the measurement.

Host defaults disable built-in AI features and VS Code telemetry, hide extension recommendations, and open Markdown as text. Red Hat telemetry defaults to disabled on both host and remote. Different existing host preferences require explicit override approval; these telemetry settings do not control every third-party extension. Existing obsolete vscode-icons preferences are preserved rather than removed during settings merge.

## Pinned Windows installation

The [Windows installer](../host/windows/vscode/Install-VSCode.ps1) owns the initial Stable version, Microsoft download URL and SHA256 pin. It requires both the expected checksum and a valid Microsoft Corporation Authenticode signature. Installation is user-scoped and does not launch VS Code or reboot Windows. Existing versions are neither upgraded nor downgraded; automatic updates remain under the user's existing policy. There is no generic applications installer or WinGet dependency for VS Code.

Settings parsing preserves JSON scalar types, nested arrays and date-like strings on PowerShell 5.1 and 7.x. JSONC comments are removed before handling trailing commas. Optional extensions are installed after conflict review and before writing settings, so an installation failure does not activate an unavailable theme.
