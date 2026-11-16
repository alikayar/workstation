# Shell design

The shell layer is intentionally small and explicit. It manages Zsh, the prompt, two Zsh plugins and optional fzf/zoxide initialization; it does not turn the shell configuration into a framework.

## Managed configuration

| Source | Installed destination | Responsibility |
| --- | --- | --- |
| [`.zshenv`](../dotfiles/zsh/.zshenv) | `~/.zshenv` | Noninteractive PATH and mise shims. |
| [`.zshrc`](../dotfiles/zsh/.zshrc) | `~/.zshrc` | Interactive shell, completion, history and tool initialization. |
| [`starship.toml`](../dotfiles/starship/starship.toml) | `~/.config/starship.toml` | Prompt appearance. |

The `shell` role installs these files and sets `/usr/bin/zsh` as the login shell. Use [Ubuntu setup](getting-started.md) for installation and [maintenance](maintenance.md#update-an-existing-workstation) for updates.

## Decisions

- Zsh uses native history search and completion.
- fzf and zoxide are initialized after mise and compinit, so the pinned tools and completions are available.
- Syntax highlighting is loaded last, as required by the plugin.
- `mise` is initialized before Starship so the prompt can display active runtime versions.
- `EDITOR` and `VISUAL` default to `nano`.

The linked configuration files are the source of truth. Local machine-specific shell changes should be made deliberately and kept separate from the managed file. Reapplying the role replaces managed shell/prompt files with Ansible backups; it does not merge arbitrary personal edits. See [configuration ownership](maintenance.md#configuration-ownership) before maintaining a customized source.

## Session activation

An inherited Python virtual environment keeps its `bin` directory ahead of mise shims in child Zsh commands.

Every normal Zsh invocation reads `.zshenv`, including `zsh -c` and `zsh -lc`. It silently prepends the mise shim directory and `~/.local/bin`, removing duplicate PATH entries. Shims select the installed runtime for the working directory, so agent commands do not depend on an interactive terminal's activated version. `.zshrc` keeps interactive completion, history, prompt and mise hooks. The mise role refreshes shims after installing tools.

For services or other shells without this environment, run `~/.local/bin/mise exec -- COMMAND` from the project directory. Existing parent processes retain their inherited environment; start a new shell or reconnect the agent after applying changes. Do not delete old runtime installations solely because a newer default exists: project manifests may still select them. Resolve conflicting standalone binaries only after establishing their ownership.

After changing the login shell, start a fresh login session. See [terminal troubleshooting](#terminal-still-opens-bash) if Bash still opens.

## Productivity shortcuts

After applying the `mise`, `cli_tools` and `shell` roles, open a new Zsh session. Ctrl+R searches your command history interactively, Ctrl+T inserts selected file paths, and Alt+C selects a directory through fzf. `z studio` jumps to a frequently visited matching directory; `zi` opens an interactive directory picker. These commands keep their state local and do not introduce a history-sync service. Agents must not inspect shell history.

Use `tmux new -s work` for a persistent session, detach with Ctrl+B then D, and reconnect with `tmux attach -t work`. A tmux session survives an SSH client disconnect while the Ubuntu environment continues running; shutting down WSL or the host still stops it.

For an agent-owned development server, prefer the explicit [task service workflow](operations.md#start-one-owned-task-service) when a user manager is available. It provides a recorded unit, resource limits, status/logs and an exact stop operation. Tmux remains an interactive session tool; it does not enforce per-task limits or replace application readiness checks.

## Terminal still opens Bash

The shell role sets the account's login shell to `/usr/bin/zsh`. Verify the account setting separately from the current process:

```bash
getent passwd "$(id -un)" | cut -d: -f7
ps -p $$ -o comm=
```

If the first command returns `/usr/bin/zsh` and the second returns `bash`, the account setting is correct. An already running Bash session does not change when the playbook updates the login shell. Enter Zsh in that terminal with:

```bash
exec /usr/bin/zsh -l
```

If newly opened terminals also start Bash, inspect the terminal application's profile. The shell role does not rewrite terminal application profiles or redirect intentional Bash sessions through `.bashrc`. Separate Windows setup and Ubuntu VS Code settings may supply defaults; existing preferences can take precedence.

For VS Code connected through WSL or Remote-SSH, run **Terminal: Select Default Profile** in the remote window and select **zsh**, then create a new terminal. If the detected shell/profile is stale, close and reconnect the remote window. A remote Linux profile can explicitly use `/usr/bin/zsh` with `-l`; configure it in the remote settings rather than changing unrelated local Windows profiles. See [VS Code terminal profiles](https://code.visualstudio.com/docs/terminal/profiles).

For Windows Terminal, open the Ubuntu profile's **Command line** setting. Use the WSL distribution's default shell instead of an explicit `bash`, `-e bash` or `--exec bash` command. Preserve the intended distribution and any other profile-specific settings. See [Windows Terminal profile settings](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-general).

If the account setting itself is still Bash, apply the shell role as the intended Ubuntu user and then start a fresh session:

```bash
ansible-playbook ansible/site.yml --tags shell --ask-become-pass
```
