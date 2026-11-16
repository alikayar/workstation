# Workstation tools

This inventory shows what each tool contributes and how Workstation provisions it. Versions and installation details live in the Ansible roles or linked configuration files. Installation scope and opt-in flags are defined in [Ubuntu setup](getting-started.md#choose-the-installation-scope); this catalog is not a promise that every listed tool is installed on every machine.

## Provisioning and agents

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| Ansible (`ansible-playbook`) | Apply the workstation configuration. | Prerequisite: `ansible-core`. | [Documentation](https://docs.ansible.com/ansible/latest/) |
| Codex CLI | Coding agent with managed configuration and rules. | `codex` role: pinned installer and dotfiles. | [Documentation](https://developers.openai.com/codex/cli) |
| Graphify (`workstation-graphify`) | Local graph discovery with separate checkout caches and optional Codex semantic docs extraction. | `agent_tools` role: pinned isolated Graphify and mise Python; no application dependencies or upstream skill installation. | [Local workflow](agent-environment.md#repository-knowledge-indexing) |

## Shell and navigation

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| Zsh | Interactive shell with managed history, completion, and aliases. | `shell` role: `zsh`. | [Documentation](https://zsh.sourceforge.io/Doc/) |
| Starship | Prompt for the managed Zsh environment. | `shell` role: pinned release binary. | [Documentation](https://starship.rs/config/) |
| zsh-autosuggestions | Suggest commands while typing. | `shell` role: Ubuntu package. | [Repository](https://github.com/zsh-users/zsh-autosuggestions) |
| zsh-syntax-highlighting | Highlight command syntax. | `shell` role: Ubuntu package. | [Repository](https://github.com/zsh-users/zsh-syntax-highlighting) |
| fzf | Interactive fuzzy history, file and directory selection. | Pinned mise tool plus Zsh key bindings. | [Repository](https://github.com/junegunn/fzf) |
| zoxide | Frequent-directory navigation with `z` and interactive `zi`. | Pinned mise tool plus Zsh initialization. | [Repository](https://github.com/ajeetdsouza/zoxide) |
| tmux | Persistent terminal sessions for SSH and long-running processes. | `cli_tools` role: `tmux`. | [Documentation](https://github.com/tmux/tmux/wiki) |

## Runtimes and containers

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| mise | Manage pinned Node.js, Python, Go, Bun, and PHP runtimes. | `mise` role: installer and [runtime configuration](../dotfiles/mise/config.toml); `shell` role: Zsh activation. | [Documentation](https://mise.jdx.dev/) |
| PHP CLI | Run PHP applications directly in the VM. | `php` role: build dependencies; `mise` role: pinned PHP source build with common extensions. No web service is started. | [Documentation](https://www.php.net/manual/en/features.commandline.php) |
| Composer | Install project-locked PHP dependencies. | `mise` role: version/checksum-pinned PHAR beside managed PHP. | [Documentation](https://getcomposer.org/doc/) |
| uv | Isolated Python environments, dependency resolution and project execution. | Pinned mise tool. | [Documentation](https://docs.astral.sh/uv/) |
| Docker Engine, Compose, Buildx | Run containers and build images. | `docker` role: official Docker APT repository and packages. | [Documentation](https://docs.docker.com/) |

## Repository and data tools

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| Git | Version control with managed identity and defaults. | `git` role: Ubuntu package and `.gitconfig`. | [Documentation](https://git-scm.com/doc) |
| Git Delta (`delta`) | Readable Git diffs. | Pinned mise tool. | [Documentation](https://dandavison.github.io/delta/) |
| GitHub CLI (`gh`) | GitHub commands and Git credential helper. | Pinned mise tool. | [Documentation](https://cli.github.com/manual/) |
| bat | Read source files with syntax highlighting. | Pinned mise tool. | [Repository](https://github.com/sharkdp/bat#usage) |
| btop | Monitor VM resource usage. | `cli_tools` role: `btop`. | [Repository](https://github.com/aristocratos/btop#documentation) |
| eza | Git-aware file listings and shell aliases. | `cli_tools` role: `eza`; `shell` role: aliases. | [Repository](https://github.com/eza-community/eza#command-line-options) |
| fd | Search for files and directories. | Pinned mise tool. | [Repository](https://github.com/sharkdp/fd#how-to-use) |
| jq | Query and transform JSON. | `cli_tools` role: `jq`. | [Documentation](https://jqlang.org/manual/) |
| yq | Query and transform YAML and related formats. | Pinned mise tool. | [Documentation](https://mikefarah.gitbook.io/yq/) |
| ripgrep (`rg`) | Search source code and text. | Pinned mise tool. | [Repository](https://github.com/BurntSushi/ripgrep#user-guide) |
| ast-grep | Structural code search and rewriting. | Pinned mise tool; use `ast-grep` to avoid Ubuntu's unrelated `sg` command. | [Documentation](https://ast-grep.github.io/guide/quick-start.html) |
| Bitwarden Secrets Manager CLI (`bws`) | Optional secret retrieval by an explicitly configured workflow. | Shared pinned mise/aqua binary only; no account, token, login or automatic secret injection is provisioned. | [Runtime source](../dotfiles/mise/config.toml) |
| FFmpeg / ffprobe | Audio/video processing and machine-readable media metadata. | `cli_tools` role: `ffmpeg`. | [Documentation](https://ffmpeg.org/documentation.html) |

## Diagnostics and browser tools

Common installer prerequisites and selected-language C/C++ build tools are owned by the `base` role, independently of PHP/Docker selection. Project-specific libraries/toolchains remain project-owned.

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| `workstation-doctor` | Read-only command/runtime resolution, user-manager, resource and local socket observations. | Shared CLI role; system Python; no repairs or installs. | [Ubuntu operations](operations.md#read-only-diagnosis) |
| `workstation-service` | Start/status/log/stop for a UUID-owned user unit with RAM/CPU/runtime limits. | Shared CLI role; existing systemd user manager; no lingering or daemon bootstrap. | [Ubuntu operations](operations.md#start-one-owned-task-service) |
| Chrome for Testing | Real browser rendering, screenshots and interactions controlled through Chrome DevTools MCP. | `agent_tools` role: checksum-pinned x86_64 Chrome and AppArmor namespace policy. | [Browser guide](browser.md) |
| Ruff | Python linting and formatting when explicitly requested. | Pinned mise tool; project configuration takes precedence. | [Documentation](https://docs.astral.sh/ruff/) |
| ShellCheck | Shell script diagnostics when explicitly requested. | Pinned mise tool. | [Repository](https://github.com/koalaman/shellcheck) |
| actionlint | GitHub Actions workflow diagnostics when explicitly requested. | Pinned mise tool. | [Repository](https://github.com/rhysd/actionlint) |
| hyperfine | Command timing comparisons when explicitly requested. | Pinned mise tool. | [Repository](https://github.com/sharkdp/hyperfine) |

## MCP integrations

| Tool | Purpose | Provisioning | Reference |
| --- | --- | --- | --- |
| Context7 MCP | Version-specific library and framework documentation when applicable. | Codex's remote Streamable HTTP MCP configuration, no local package. | [Repository](https://github.com/upstash/context7) |
| Chrome DevTools MCP | Navigation, interaction, screenshots, tracing, console/network inspection and native page audits. | Pinned `npx` package; enabled with the managed browser. | [Repository](https://github.com/ChromeDevTools/chrome-devtools-mcp) |

## Implementation notes

- Zsh syntax highlighting is sourced last in `.zshrc`; see the [shell design](shell.md).
- mise provides `bat` and `fd` directly through its shims; no distribution-name aliases are installed.
- The managed Git configuration uses the absolute mise `gh` shim as the credential helper for GitHub and Gist. Authentication state is not stored in this repository.
- Docker group membership grants root-equivalent access to the Docker host.

## Ownership and use

Engineering skills are managed separately. Workstation provisions tools and agent settings; it does not install, copy or link personal/shared skills.

APT manages Ubuntu CLI packages; mise pins shared runtimes and standalone tools. Project manifests and lockfiles own project dependencies and validation rules. Use the [verification guide](verification.md) for authorized Workstation checks; installation alone does not authorize execution.

Context7 is enabled, and Chrome DevTools is enabled with the managed browser; see the [MCP guide](mcp.md).

## Host and server tooling

Windows host apps are separate from the Ubuntu catalog: `wvm setup terminal` manages terminal dependencies/appearance, `wvm setup vscode` reviews editor setup, and `wvm setup codex` configures an already installed host Codex. `wvm doctor` supplies read-only diagnostics. See the [Windows guide](windows.md) for privileges, effects and recovery.

The default Ubuntu [server baseline](security.md#ubuntu-server-baseline) manages OpenSSH, UFW, AppArmor, unattended security upgrades and password quality. It can be explicitly disabled or omitted by tag; it is separate from Chrome's namespace policy and Hyper-V's host-side network rules.
