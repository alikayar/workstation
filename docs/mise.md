# Mise

Mise manages language runtimes and keeps their versions in one project-owned
configuration instead of maintaining separate version managers.

- **Official docs:** https://mise.jdx.dev/
- **Source repository:** https://github.com/jdx/mise
- **Managed by:** `mise`
- **Configuration:** [dotfiles/mise/config.toml](../dotfiles/mise/config.toml)
- **Installed as:** `~/.config/mise/config.toml`
- **Binary:** `~/.local/bin/mise`

## Managed runtimes

The [mise configuration](../dotfiles/mise/config.toml) pins the Node.js,
Python, Go, and Bun versions installed by the `mise` role.

## Why

- One mechanism manages all configured language runtimes.
- Runtime versions are explicit and reproducible.
- The same mechanism can activate tools per project when a repository defines
  its own `mise.toml`.
- Zsh activation is managed in `.zshrc`; Starship reads the active toolchain.

Mise installs runtime versions for the user. It does not install project
dependencies, global application packages, or language-specific CLI tools.
