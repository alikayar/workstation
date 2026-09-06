# Shell design

The shell layer is intentionally small and explicit. It manages Zsh, the
prompt, and two Zsh plugins; it does not turn the shell configuration into a
framework.

## Managed configuration

- Source: `dotfiles/zsh/.zshrc`
- Installed as: `~/.zshrc`
- Prompt source: `dotfiles/starship/starship.toml`
- Installed as: `~/.config/starship.toml`
- Role: `ansible/roles/shell`

## Decisions

- Zsh uses native history search and completion.
- Syntax highlighting is loaded last, as required by the plugin.
- `mise` is initialized before Starship so the prompt can display active
  runtime versions.
- `EDITOR` and `VISUAL` default to `nano`.

The shell file is the source of truth. Local machine-specific shell changes
should be made deliberately and kept separate from the managed file.
