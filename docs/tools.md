# Workstation tools

This inventory shows what each tool contributes and how Workstation provisions
it. Versions and installation details live in the Ansible roles or linked
configuration files.

| Tool | Role in workstation | Provisioning | Reference |
| --- | --- | --- | --- |
| Ansible (`ansible-playbook`) | Apply the workstation configuration. | Prerequisite: `ansible-core`. | [Documentation](https://docs.ansible.com/ansible/latest/) |
| Zsh | Interactive shell with managed history, completion, and aliases. | `shell` role: `zsh`. | [Documentation](https://zsh.sourceforge.io/Doc/) |
| Starship | Prompt for the managed Zsh environment. | `shell` role: pinned release binary. | [Documentation](https://starship.rs/config/) |
| zsh-autosuggestions | Suggest commands while typing. | `shell` role: Ubuntu package. | [Repository](https://github.com/zsh-users/zsh-autosuggestions) |
| zsh-syntax-highlighting | Highlight command syntax. | `shell` role: Ubuntu package. | [Repository](https://github.com/zsh-users/zsh-syntax-highlighting) |
| Git | Version control with managed identity and defaults. | `git` role: Ubuntu package and `.gitconfig`. | [Documentation](https://git-scm.com/doc) |
| Git Delta (`delta`) | Readable Git diffs. | `cli_tools` role: `git-delta`. | [Documentation](https://dandavison.github.io/delta/) |
| GitHub CLI (`gh`) | GitHub commands and Git credential helper. | `cli_tools` role: `gh`. | [Documentation](https://cli.github.com/manual/) |
| mise | Manage pinned Node.js, Python, Go, and Bun runtimes. | `mise` role: installer and [runtime configuration](../dotfiles/mise/config.toml); `shell` role: Zsh activation. | [Documentation](https://mise.jdx.dev/) |
| bat | Read source files with syntax highlighting. | `cli_tools` role: `bat`. | [Repository](https://github.com/sharkdp/bat#usage) |
| btop | Monitor VM resource usage. | `cli_tools` role: `btop`. | [Repository](https://github.com/aristocratos/btop#documentation) |
| eza | Git-aware file listings and shell aliases. | `cli_tools` role: `eza`; `shell` role: aliases. | [Repository](https://github.com/eza-community/eza#command-line-options) |
| fd | Search for files and directories. | `cli_tools` role: `fd-find`. | [Repository](https://github.com/sharkdp/fd#how-to-use) |
| jq | Query and transform JSON. | `cli_tools` role: `jq`. | [Documentation](https://jqlang.org/manual/) |
| yq | Query and transform YAML and related formats. | `cli_tools` role: pinned binary with checksum. | [Documentation](https://mikefarah.gitbook.io/yq/) |
| ripgrep (`rg`) | Search source code and text. | `cli_tools` role: `ripgrep`. | [Repository](https://github.com/BurntSushi/ripgrep#user-guide) |
| Docker Engine, Compose, Buildx | Run containers and build images. | `docker` role: official Docker APT repository and packages. | [Documentation](https://docs.docker.com/) |
| Codex CLI | Coding agent with managed configuration and rules. | `codex` role: pinned installer and dotfiles. | [Documentation](https://developers.openai.com/codex/cli) |

## Implementation notes

- Zsh syntax highlighting is sourced last in `.zshrc`; see the [shell design](shell.md).
- Ubuntu names the bat and fd binaries `batcat` and `fdfind`. The `cli_tools`
  role provides `bat` and `fd` symlinks in `~/.local/bin`.
- The managed Git configuration uses `gh` as the credential helper for GitHub
  and Gist. Authentication state is not stored in this repository.
- Docker group membership grants root-equivalent access to the Docker host.
- Codex configuration includes a local Playwright MCP endpoint, but does not
  start that server; see the [Codex notes](codex.md).
