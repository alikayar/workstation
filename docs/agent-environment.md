# Agent environment

Workstation provides executables, version defaults and launchers. Shared skills describe task workflows; project repositories own their service commands, ports, architecture and evaluation questions.

## Version policy

- Mise, runtime tools, Composer, selected binaries and MCP packages use reviewed pins already maintained in their respective defaults. APT packages follow Ubuntu's package updates.
- The Codex role bootstraps a missing CLI through an upstream commit and checksum-pinned installer, but neither pins the resulting CLI release nor upgrades/downgrades an existing executable. The immutable installer URL avoids breaking fresh installs when the public installer endpoint changes. Desktop/CLI updates remain explicit lifecycle decisions; this avoids Ansible fighting the desktop updater. Do not describe the entire environment as bit-for-bit reproducible.
- Update a tool's pin only after reviewing its release and the behavior used here. Apply the relevant role, run authorized checks, and review project overrides before changing an active version.
- Optional Python tools live in separate versioned environments. Top-level packages are pinned; transitive dependencies are not locked. Old environments are retained until deliberately removed, since another process may still use them.
- Agent-browser and Chrome for Testing use explicit version and SHA256 pins. The native CLI has no npm runtime dependency; APT browser libraries follow Ubuntu updates.

## Document conversion

Enable MarkItDown with `workstation_markitdown_enabled: true` in the ignored local host variables and apply the `agent_tools` role. The existing mise/uv/Python setup must be installed first.

Use `workstation-markitdown input.pdf -o output.md`. The launcher points to an isolated uv tool environment under `~/.local/share/workstation/markitdown-0.1.9/`, with only the PDF, DOCX, PPTX and XLSX extras requested. It does not enable third-party converter plugins or configure hosted AI services. Text extraction does not prove layout, OCR or complex table fidelity.

Disabling the setting skips future installation; it does not uninstall an existing environment or launcher.

## Browser automation

The Ubuntu `agent_tools` role installs **agent-browser 0.41.2** and **Chrome for Testing 157.0.8103.38** by default on x86_64. Both downloads are versioned and SHA256 checked. Version directories under `/opt/workstation` are root-owned. Chrome's completed extraction is recorded only after unpacking; an interrupted extraction is retried. Old versions, artifacts and the verified archive cache are retained.

Chrome for Testing does not provide a Linux ARM64 download. `workstation_agent_browser_enabled` therefore defaults to false on ARM64; explicitly enabling it there stops with an explanation. Other roles retain their ARM64 support. Setting this variable to false skips future installation; it does not uninstall an existing browser.

Full workstation provisioning includes this setup. To apply it separately, run inside Ubuntu from the repository root:

```sh
ansible-playbook ansible/site.yml --tags agent_browser,codex --ask-become-pass
```

The `agent_browser` tag installs only browser dependencies and launchers. The `codex` tag also applies the existing Codex role, including its managed global instructions and configuration; that role remains their single owner. Applying either role does not authorize or run browser verification or install external skills. Browser setup refuses to replace unrelated or linked `~/.local/bin/agent-browser` and `workstation-browser-task` files. Existing user and project browser configuration is not overwritten; the launcher loads a separate managed config. It clears inherited browser settings and refuses session/profile/restore/CDP/provider, config/executable, headed and idle-timeout overrides. These managed commands intentionally expose a subset of upstream CLI flags: use `agent-browser --session TASK COMMAND [FLAGS ...]`, with formatting flags such as `--json` after the command. `connect` and identity/profile overrides are refused; `wait --state` still controls element visibility. `--help` and `--version` remain available without starting a session. Preview mode skips downloads; it does not verify asset availability or checksum bytes.

### One foreground workflow

```sh
workstation-browser-task sh -eu -c '
  agent-browser open http://127.0.0.1:3000
  agent-browser snapshot -i
  agent-browser screenshot
'
```

The helper generates a unique session and a mode-0700 directory under `~/.local/share/workstation/browser-tasks`, prints both to stderr and passes session/output settings to child commands. It clears inherited `AGENT_BROWSER_*` settings first, so profile, CDP and provider settings are not inherited. Cleanup closes only its own session after the foreground command exits, including failures and handled INT/TERM/HUP signals. Artifacts remain for review. A successful workflow with failed cleanup returns nonzero; an already-failed workflow keeps its failure status. Do not detach browser commands or servers from this scope.

### Agent steps across tool calls

Generate a unique ID once:

```sh
printf 'task-%s\n' "$(cat /proc/sys/kernel/random/uuid)"
```

Record the printed ID and pass that literal value on every subsequent command, replacing `TASK_ID` below:

```sh
agent-browser --session TASK_ID open http://127.0.0.1:3000
agent-browser --session TASK_ID snapshot -i
agent-browser --session TASK_ID screenshot /absolute/project/artifacts/page.png
agent-browser --session TASK_ID close
```

Managed Codex instructions require explicit close at task completion, including failure/cancellation. There is no reliable OS event for the end of an arbitrary agent chat, so this multi-call workflow still requires agent cleanup. Never close all sessions. SIGKILL, power loss and disconnected agents can bypass cleanup; the five-minute native idle timeout is a fallback for local headless sessions. Keep headed, remote-attached and restored personal profiles outside this workflow.

The browser runs inside Ubuntu and reaches the application's VM-local address. Inspect screenshots for layout checks; accessibility snapshots alone do not prove visual correctness. Session separation is not a security boundary against processes running as the same Unix user. Browser execution still needs the user's authorization.

On AppArmor-enabled Ubuntu, a profile permits user namespaces for the exact root-owned Chrome executable, following [Chromium's documented approach](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md). The exact policy is reloaded on each apply so a previously interrupted apply can recover even when its file is unchanged. File changes carry the Ansible change report; the derived kernel reload does not restart the AppArmor service. The role does not disable AppArmor globally, add a SUID executable or pass `--no-sandbox`. This grants namespace use; it is not full filesystem/network confinement. Upstream agent-browser itself disables Chrome sandboxing under root, `CI` and container environments; use the intended non-root native VM and do not treat CI/container launches as sandbox verification.

Upstream: [installation](https://agent-browser.dev/installation), [sessions](https://agent-browser.dev/sessions), [commands](https://agent-browser.dev/commands). The CLI digest comes from upstream v0.41.2 release asset metadata; the Chrome SHA256 was calculated from Google's version-specific archive. Checksums freeze these bytes; they are not vendor signatures.
