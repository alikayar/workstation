# Mise

Mise manages language runtimes and keeps their versions in one project-owned configuration instead of maintaining separate version managers.

- **Official docs:** https://mise.jdx.dev/
- **Source repository:** https://github.com/jdx/mise
- **Managed by:** `mise`
- **Configuration:** [dotfiles/mise/config.toml](../dotfiles/mise/config.toml)
- **Installed as:** `~/.config/mise/config.toml`
- **Binary:** `~/.local/bin/mise`

## Managed runtimes

The [mise configuration](../dotfiles/mise/config.toml) pins the Node.js, Python, Go and Bun versions installed by the `mise` role, together with uv, Ruff, ast-grep, actionlint, fzf and zoxide.

## Why

- One mechanism manages all configured language runtimes.
- Runtime versions are explicit and reproducible.
- The same mechanism can activate tools per project when a repository defines its own `mise.toml`.
- Zsh activation is managed in `.zshrc`; Starship reads the active toolchain.

Mise installs the listed runtimes and standalone CLI tools for the user. It does not install application dependencies into projects. Keep project-local tool versions and validation configuration in their own manifests. uv manages Python dependency environments; for models requiring Python 3.12, select that interpreter in the model project rather than changing the workstation-wide Python default.
