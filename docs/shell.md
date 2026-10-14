# Shell design

The shell layer is intentionally small and explicit. It manages Zsh, the prompt, two Zsh plugins and optional fzf/zoxide initialization; it does not turn the shell configuration into a framework.

## Managed configuration

- Source: `dotfiles/zsh/.zshrc`
- Installed as: `~/.zshrc`
- Prompt source: `dotfiles/starship/starship.toml`
- Installed as: `~/.config/starship.toml`
- Role: `ansible/roles/shell`
- Login shell: `/usr/bin/zsh`

## Decisions

- Zsh uses native history search and completion.
- The role sets Zsh as the user's login shell; terminal application profiles can override it.
- fzf and zoxide are initialized after mise and compinit, so the pinned tools and completions are available.
- Syntax highlighting is loaded last, as required by the plugin.
- `mise` is initialized before Starship so the prompt can display active runtime versions.
- `EDITOR` and `VISUAL` default to `nano`.

The shell file is the source of truth. Local machine-specific shell changes should be made deliberately and kept separate from the managed file.

## Session activation

Ansible cannot replace the shell process that invoked it. After changing the login shell, start a fresh login session or run `exec /usr/bin/zsh -l` in the current terminal. If a newly created terminal still launches Bash while the account shell is `/usr/bin/zsh`, fix the VS Code or Windows Terminal profile rather than changing the account again. See [terminal troubleshooting](getting-started.md#terminal-still-opens-bash).

## Productivity shortcuts

After applying the `mise`, `cli_tools` and `shell` roles, open a new Zsh session. Ctrl+R searches your command history interactively, Ctrl+T inserts selected file paths, and Alt+C selects a directory through fzf. `z studio` jumps to a frequently visited matching directory; `zi` opens an interactive directory picker. These commands keep their state local and do not introduce a history-sync service. Agents must not inspect shell history.

Use `tmux new -s work` for a persistent session, detach with Ctrl+B then D, and reconnect with `tmux attach -t work`. A tmux session survives an SSH client disconnect while the Ubuntu environment continues running; shutting down WSL or the host still stops it.
