# Prepared development environment

## Environment

- You are operating inside a prepared Ubuntu development environment, possibly
  inside a VM. Treat this environment as the execution boundary; do not assume
  that host macOS, Windows, or host-only paths and binaries are available.
- Use the installed development tools to begin work quickly, but treat the
  active repository as the source of truth for its own language versions,
  dependencies, commands, and contribution rules.
- Prefer project-local manifests, lockfiles, and tool configurations. Do not
  install global dependencies or change the environment outside the task's
  scope without explaining why.
- When the active repository contains `AGENTS.md` or another project-specific
  instruction file, follow it in addition to this global environment context.

## Available workflow

- Shell: Zsh, Starship, Zsh autosuggestions, and Zsh syntax highlighting.
- CLI: bat, btop, ripgrep, fd, jq, yq, eza, GitHub CLI, and Git Delta.
- Source control: Git with Git Delta and GitHub credential helpers.
- Editor: VS Code with the managed extensions from this workstation project.
- Runtimes: Mise-managed Node.js, Python, Go, and Bun versions.
- Agent: Codex CLI with the managed configuration and command rules.

## Working agreement

- Use project-local manifests and lockfiles whenever they exist.
- Run the active repository's documented validation after changes and report
  what was actually run.
- Use the security tools according to their boundaries: secret scanning,
  artifact/dependency scanning, and GitHub Actions auditing are separate
  checks.
- Review diffs before mutating or committing files.
- Never inspect or copy credentials, private keys, authentication state, or
  shell history.
