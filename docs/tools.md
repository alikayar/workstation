# Workstation tools

This is the inventory and rationale for the tools managed by Workstation.
Installation details belong to the owning Ansible role; usage details belong
to each tool's official documentation.

## Ansible

- **Purpose:** Apply the workstation configuration idempotently.
- **Package / command:** `ansible-core` / `ansible-playbook`
- **Official docs:** https://docs.ansible.com/ansible/latest/
- **Source repository:** https://github.com/ansible/ansible
- **Managed by:** Prerequisite for the project
- **Why:** The workstation should be reproducible and safe to re-apply.

## Zsh

- **Purpose:** Interactive shell for the development environment.
- **Package / command:** `zsh` / `zsh`
- **Official docs:** https://zsh.sourceforge.io/Doc/
- **Source repository:** https://github.com/zsh-users/zsh
- **Managed by:** `shell`
- **Why:** Provides a capable, configurable shell with predictable interactive behavior.

## Starship

- **Purpose:** Cross-shell prompt.
- **Package / command:** release binary / `starship`
- **Official docs:** https://starship.rs/config/
- **Source repository:** https://github.com/starship/starship
- **Managed by:** `shell`
- **Why:** Keeps prompt information readable and portable across environments.

## Zsh integrations

### zsh-autosuggestions

- **Purpose:** Suggest commands from shell history while typing.
- **Package / command:** `zsh-autosuggestions` / Zsh plugin
- **Official docs:** https://github.com/zsh-users/zsh-autosuggestions
- **Source repository:** https://github.com/zsh-users/zsh-autosuggestions
- **Managed by:** `shell`
- **Why:** Speeds up repeated commands without replacing Zsh's native history behavior.

### zsh-syntax-highlighting

- **Purpose:** Highlight valid and invalid command syntax interactively.
- **Package / command:** `zsh-syntax-highlighting` / Zsh plugin
- **Official docs:** https://github.com/zsh-users/zsh-syntax-highlighting
- **Source repository:** https://github.com/zsh-users/zsh-syntax-highlighting
- **Managed by:** `shell`
- **Why:** Catches malformed commands before they are executed.
- **Notes:** It is sourced last in `.zshrc` because it must see the final Zsh line-editor state.

## bat

- **Purpose:** Read files in the terminal with syntax highlighting and line numbers.
- **Package / command:** `bat` / `bat`
- **Official docs:** https://github.com/sharkdp/bat#usage
- **Source repository:** https://github.com/sharkdp/bat
- **Managed by:** `cli_tools`
- **Why:** Preferred terminal file viewer for source code and configuration files.
- **Notes:** Ubuntu exposes the binary as `batcat`; Workstation provides `~/.local/bin/bat`.

## btop

- **Purpose:** Interactive resource monitor for CPU, memory, disks, network, and processes.
- **Package / command:** `btop` / `btop`
- **Official docs:** https://github.com/aristocratos/btop#documentation
- **Source repository:** https://github.com/aristocratos/btop
- **Managed by:** `cli_tools`
- **Why:** A VM workstation needs a quick way to diagnose resource pressure.

## eza

- **Purpose:** Modern, Git-aware replacement for `ls`.
- **Package / command:** `eza` / `eza`
- **Official docs:** https://github.com/eza-community/eza#command-line-options
- **Source repository:** https://github.com/eza-community/eza
- **Managed by:** `cli_tools` and `shell`
- **Why:** The shell aliases use its Git status, tree, sorting, and readable output.

## fd

- **Purpose:** Fast, user-friendly file and directory search.
- **Package / command:** `fd-find` / `fd`
- **Official docs:** https://github.com/sharkdp/fd#how-to-use
- **Source repository:** https://github.com/sharkdp/fd
- **Managed by:** `cli_tools`
- **Why:** Faster and safer default for interactive file discovery than handwritten `find` commands.
- **Notes:** Ubuntu exposes `fdfind`; Workstation provides `~/.local/bin/fd`.

## jq

- **Purpose:** Query and transform JSON data from the command line.
- **Package / command:** `jq` / `jq`
- **Official docs:** https://jqlang.org/manual/
- **Source repository:** https://github.com/jqlang/jq
- **Managed by:** `cli_tools`
- **Why:** JSON is common in APIs, automation, and development tooling.

## yq

- **Purpose:** Query and transform YAML, JSON, XML, and related structured data.
- **Package / command:** `yq` / `yq`
- **Official docs:** https://mikefarah.gitbook.io/yq/
- **Source repository:** https://github.com/mikefarah/yq
- **Managed by:** `cli_tools`
- **Why:** Complements `jq` for Ansible and other configuration-heavy workflows.
- **Notes:** The Ubuntu package version is intentionally documented separately from the upstream v4 release model.

## ripgrep

- **Purpose:** Fast recursive text and source-code search.
- **Package / command:** `ripgrep` / `rg`
- **Official docs:** https://github.com/BurntSushi/ripgrep#user-guide
- **Source repository:** https://github.com/BurntSushi/ripgrep
- **Managed by:** `cli_tools`
- **Why:** Primary text/code search tool for both interactive use and automation.

## Git and Git Delta

- **Purpose:** Version control and readable side-by-side diffs.
- **Package / command:** `git`, `git-delta` / `git`, `delta`
- **Official docs:** https://git-scm.com/doc and https://dandavison.github.io/delta/
- **Source repository:** https://github.com/git/git and https://github.com/dandavison/delta
- **Managed by:** `git` and `cli_tools`
- **Why:** Git is the source-control baseline; Delta makes review-oriented workflows easier to read.
- **Notes:** GitHub and Gist credential helpers use the GitHub CLI.

## GitHub CLI

- **Purpose:** Work with GitHub repositories, issues, pull requests, and authentication from the terminal.
- **Package / command:** `gh` / `gh`
- **Official docs:** https://cli.github.com/manual/
- **Source repository:** https://github.com/cli/cli
- **Managed by:** `cli_tools`
- **Why:** Keeps common GitHub operations close to the repository and supports Git credential integration.

## Docker

- **Purpose:** Run containers and build multi-stage/containerized applications.
- **Package / command:** Docker Engine, Compose, Buildx / `docker`
- **Official docs:** https://docs.docker.com/
- **Source repository:** https://github.com/docker
- **Managed by:** `docker`
- **Why:** Container tooling is a core development dependency for local services and reproducible environments.
- **Notes:** The user is added to the `docker` group; this grants root-equivalent access to the Docker host.

## VS Code

- **Purpose:** Graphical code editor.
- **Package / command:** existing `code` CLI / `code`
- **Official docs:** https://code.visualstudio.com/docs
- **Source repository:** https://github.com/microsoft/vscode
- **Managed by:** `vscode`
- **Why:** Keeps the selected editor extensions reproducible without managing the editor installation itself.

## Codex CLI

- **Purpose:** Local coding agent for repository work.
- **Package / command:** official installer / `codex`
- **Official docs:** https://developers.openai.com/codex/cli
- **Source repository:** https://github.com/openai/codex
- **Managed by:** `codex`
- **Why:** Makes the coding-agent configuration, rules, and approved integrations reproducible.
- **Notes:** Configuration policy is documented in [codex.md](codex.md).
