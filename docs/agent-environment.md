# Agent environment

Workstation provides executables, version defaults and launchers. Shared skills describe task workflows; project repositories own their service commands, ports, architecture and evaluation questions.

## Version policy

- Mise, runtime tools, Composer, selected binaries and MCP packages use reviewed pins already maintained in their respective defaults. APT packages follow Ubuntu's package updates.
- The Codex role bootstraps a missing CLI through an upstream commit and checksum-pinned installer, but neither pins the resulting CLI release nor upgrades/downgrades an existing executable. The immutable installer URL avoids breaking fresh installs when the public installer endpoint changes. Desktop/CLI updates remain explicit lifecycle decisions; this avoids Ansible fighting the desktop updater. Do not describe the entire environment as bit-for-bit reproducible.
- Update a tool's pin only after reviewing its release and the behavior used here. Apply the relevant role, run authorized checks, and review project overrides before changing an active version.
- Optional Python tools live in separate versioned environments. Top-level packages are pinned; transitive dependencies are not locked. Old environments are retained until deliberately removed, since another process may still use them.

## Document conversion

Enable MarkItDown with `workstation_markitdown_enabled: true` in the ignored local host variables and apply the `agent_tools` role. The existing mise/uv/Python setup must be installed first.

Use `workstation-markitdown input.pdf -o output.md`. The launcher points to an isolated uv tool environment under `~/.local/share/workstation/markitdown-0.1.9/`, with only the PDF, DOCX, PPTX and XLSX extras requested. It does not enable third-party converter plugins or configure hosted AI services. Text extraction does not prove layout, OCR or complex table fidelity.

Disabling the setting skips future installation; it does not uninstall an existing environment or launcher.
