# Architecture and configuration ownership

Workstation has two independently applied layers: Windows scripts prepare host applications and Hyper-V resources; a local Ansible playbook prepares the Ubuntu development account. Updating this repository changes their source definitions. It changes an installed machine only when the appropriate entry point is applied.

## Execution boundaries

| Boundary | Entry point | Owned behavior |
| --- | --- | --- |
| Windows host | `host/windows/wvm/Install-WVM.ps1`, then `wvm` | Per-user launcher, host app setup, image builds, clone creation, VM lifecycle and diagnostics |
| Ubuntu environment | `ansible-playbook ansible/site.yml` from the checkout | Local packages, user configuration, runtimes, Docker and agent tools |
| Application checkout | Its own manifests and instructions | Dependencies, runtime overrides, ports, application data and validation |
| Active agent session | Host project or SSH-connected Ubuntu project | Available tools and execution environment for that session; stored MCP configuration alone does not establish either |

The Windows launcher forwards to its original checkout. Keep that checkout available and rerun launcher installation if it moves. Ansible uses a local inventory and derives the development user/home from the invoking environment; it is not a remote provisioning controller. Run it as the intended non-root Ubuntu user, with privilege escalation for system tasks.

## Ubuntu apply flow

[The playbook](../ansible/site.yml) first validates Ubuntu, architecture, user and language selection, and chooses the compatible sudo executable unless explicitly overridden. Its role order is base prerequisites, security (enabled by default), shell, VS Code, Git, Codex, PHP prerequisites, mise, shared CLI packages, Docker and agent tools. Role defaults and task files own exact behavior; tags select tasks from this sequence and do not install every omitted prerequisite.

Direct untagged applies include all default-enabled components. `workstation_languages` narrows the language entries in the mise template; shared CLI entries remain. The Windows selection path includes prerequisites and security in its base tag set and adds the selected components, enabling Chrome according to that selection. Omission skips provisioning and does not uninstall an existing component. See [scope selection](getting-started.md#choose-the-installation-scope) for examples.

### File and configuration owners

| Source | Installed state | Update behavior |
| --- | --- | --- |
| `ansible/roles/base/` | Common Ubuntu prerequisites and selected-language native toolchain | Runs before installers; independent of Docker/PHP selection |
| `dotfiles/zsh/`, `dotfiles/starship/` | Ubuntu shell and prompt | Managed files; inspect the shell role's backup behavior before replacing local changes |
| `dotfiles/git/.gitconfig` plus local identity variables | Ubuntu user Git configuration | Whole-file template with Ansible backup |
| `dotfiles/mise/config.toml` | Ubuntu global runtime/tool defaults | Rendered template; project-local versions take precedence |
| `dotfiles/codex/` | Ubuntu Codex config, global instructions and rules | Whole-file replacement, not an interactive merge; source overrides are supported |
| `dotfiles/vscode/remote-settings.json` | Stable Remote-SSH machine settings | Add missing values, preserve existing values and retain the first-change backup |
| `host/windows/vscode/settings.json` | Windows VS Code user settings | Review conflicts, preserve declined values, atomically write with a pre-change backup |
| `host/windows/vscode/appearance/` | Local static theme/icon package | Copy into a versioned extension directory; refuse differing contents at the same version |
| `host/windows/codex/` | Host Codex defaults and marked instruction block | Versioned config API edits with conflict prompts; preserve unrelated settings and instructions |
| `host/windows/terminal/` | Workstation Terminal files and profiles | Managed runtime files; preserve unrelated Terminal settings and the original settings backup |

Ignored `ansible/host_vars/localhost.yml` supplies machine-local overrides. The tracked example supplies only Git identity placeholders. Keep credentials out of both managed templates and publishable overrides. Configuration overrides are not permission to copy authentication stores between host and VM. See [ownership and recovery](getting-started.md#configuration-ownership) before applying over an existing user setup.

## Windows image and clone flow

`wvm create` selects a guest and forwards explicitly supplied options to the shared image/clone pipeline. The image specification combines guest/media identity and recipe/helper hashes. A matching verified Ready image is reused; otherwise a temporary Packer builder installs and generalizes it. Publication requires the expected sealing evidence, builder cleanup, protected storage and recorded disk hash.

Each instance receives a full writable copy with new disk/VM identity. Instance seeding and account setup happen after copying; development tools are applied separately inside Ubuntu. The base is not a runtime parent disk. Records are written before mutations, and frozen payload hashes protect resuming work after source changes. The [Windows guide](windows.md#packer-first-base-images) owns storage paths, flags, phase recovery and guest-specific behavior.

For selected Ubuntu provisioning, the host bundles tracked Ansible/dotfile sources and the guest runner, excluding private host variables and Git history. It retains the bundle hash for retries. `wvm configure` reuses that saved source selection; it is not an implicit update to the latest working tree. After Ubuntu is ready, SSH publishes the remote account boundary used by host applications.

## Long-lived and on-demand resources

Docker runs as a system service when its role is applied. Shared CLI tooling installs [read-only doctor and task-service commands](operations.md); service startup is an explicit operation using the existing systemd user manager, with per-task unit identity and resource/runtime limits. Shell configuration acts on new sessions. Graphify performs explicit indexing and exits; its private cache survives. Chrome DevTools starts under the client that launches it. The client owns MCP process lifetime, while browser tasks own the pages and recordings they create. No Workstation browser cleanup daemon or automatic index watcher is installed.

Skills, Codex login, Git-host authentication, application databases and project services have separate owners. They are not provisioned by copying another machine's state. Keep the host/VM [security boundaries](security.md) and [verification limits](verification.md) visible when assessing the resulting environment.
