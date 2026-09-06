# Mise

Mise manages language runtimes and keeps their versions in one project-owned
configuration instead of maintaining separate version managers.

- **Official docs:** https://mise.jdx.dev/
- **Source repository:** https://github.com/jdx/mise
- **Managed by:** `mise`
- **Configuration:** `dotfiles/mise/config.toml`
- **Installed as:** `~/.config/mise/config.toml`
- **Binary:** `~/.local/bin/mise`

## Managed runtimes

```toml
[tools]
node = "24.20.0"
python = "3.14.7"
go = "1.26.5"
bun = "1.4.2"
```

## Why

- One mechanism manages all configured language runtimes.
- Runtime versions are explicit and reproducible.
- The same mechanism can activate tools per project when a repository defines
  its own `mise.toml`.
- Zsh activation is managed in `.zshrc`; Starship reads the active toolchain.

Mise installs runtime versions for the user. It does not install project
dependencies, global application packages, or language-specific CLI tools.
