# Maintain and update Workstation

Use this guide when changing the workstation definition or reviewing a dependency proposal. The [Ubuntu update procedure](#update-an-existing-workstation) below owns machine apply/recovery commands; [Windows recovery](hyperv.md#recovery-compatibility-and-validation) owns VM/image state. Updating source, updating an installed tool and proving the new behavior are separate operations.

## Version policy

- Mise, runtime tools, Composer, selected binaries and MCP packages use reviewed pins already maintained in their respective defaults. APT packages follow Ubuntu's package updates.
- The Codex role bootstraps a missing CLI through an upstream commit and checksum-pinned installer, but neither pins the resulting CLI release nor upgrades/downgrades an existing executable. The immutable installer URL avoids breaking fresh installs when the public installer endpoint changes. Desktop/CLI updates remain explicit lifecycle decisions; this avoids Ansible fighting the desktop updater. Do not describe the entire environment as bit-for-bit reproducible.
- Update a tool's pin only after reviewing its release and the behavior used here. Apply the relevant role, run authorized checks, and review project overrides before changing an active version.
- Optional Python tools live in separate versioned environments. Top-level packages are pinned; transitive dependencies are not locked. Old environments are retained until deliberately removed, since another process may still use them.
- Chrome for Testing uses an explicit version and SHA256 pin. Chrome DevTools MCP uses a pinned npm package through the workstation Node runtime; APT browser libraries follow Ubuntu updates.

## Dependency update proposals

[renovate.json](../renovate.json) configures the hosted Renovate GitHub App. After this configuration is merged, install or configure [Renovate](https://github.com/apps/renovate) for `alikayar/workstation` only and complete its onboarding if offered. No workstation service, repository token or self-hosted workflow is required. The repository file alone does not grant the app access or start the bot.

The bot proposes updates on Monday before 10:00 in Europe/Istanbul, with at most three active update PRs and no automatic merges. Releases with timestamps wait seven days; prereleases are excluded. Node uses Renovate's LTS-aware `node` versioning, so a new major is proposed after that line reaches LTS. Go and the other tracked tools follow stable releases. Exact pins remain in the source; merging a PR does not provision an existing VM.

The mise configuration contains Jinja conditionals, so Renovate uses explicit `# renovate:` annotations instead of the TOML manager. Coverage includes all language/runtime and shared CLI pins in that template, the Graphify package version, the Chrome DevTools MCP npm version and digest-pinned GitHub Actions. Keep annotations immediately above the version assignment. Bun, PHP and Bitwarden use explicit tag-prefix extraction so vendor tag prefixes are not written into mise's version values.

Checksum-coupled downloads (mise installer, Composer, Starship, Chrome, Packer and installation media), the pinned Graphify Python compatibility runtime, reviewed Codex installer/plugin revisions and bundled theme/icon snapshots remain deliberate manual updates. Do not add a version-only rule for those downloads: version, URL, checksum and any matching recipe must change together. Review update diffs and use the [verification guide](verification.md); automatic source checks do not establish full-install or Windows compatibility.

See Renovate's [regex manager](https://docs.renovatebot.com/modules/manager/regex/) and [Node versioning](https://docs.renovatebot.com/modules/versioning/node/) documentation for extraction and LTS behavior.

## Review a change

1. Identify the entry point and installed state in [architecture and ownership](architecture.md). Read the affected defaults, tasks/templates and actual consumers before changing a pin or command.
2. Keep application dependencies and personal skills in their owning repositories. Preserve local Workstation overrides and unrelated edits; never copy private configuration into tracked templates or test fixtures.
3. Update the source and its canonical guide together. Trace a component change through Windows selections, guest tag/extra-variable mapping, Ansible tasks, rendered Codex configuration and test expectations when those consumers apply.
4. Choose the checks that cover the changed boundary using [verification](verification.md). Source parsing, mocked Windows contracts, browser integration and fresh provisioning prove different things. Record unexecuted checks explicitly; test edits/execution require the task's authorization.
5. Review the resulting diff, required asset notices and generated evidence before committing. Commit, push, workflow dispatch and applying to a machine are separate actions requiring authorization. Do not treat an update PR as permission to perform them.

### Coupled changes

| Change | Review together |
| --- | --- |
| Runtime or shared CLI pin | Mise annotation/template, supported architecture, project overrides and any compatibility-dependent tool |
| Chrome or MCP upgrade | Chrome URL/checksum, executable path, namespace policy, pinned MCP tool/flag contract and browser smoke/battle assertions |
| Graphify adapter publication | Immutable graph generation, writer deadline, freshness assertions and benchmark refresh consumer; historical measurements keep their original source hashes |
| Optional Python tool | Package pin, interpreter compatibility, versioned environment and managed launcher ownership |
| Codex installer/plugin | Immutable source/hash, supported installed CLI behavior, marketplace revision/version and configuration rendering |
| Windows base recipe/media | Media/hash/build verification, recipe fingerprint, frozen recovery payload and fresh image/clone scenarios |
| Static appearance snapshot | Required assets/notices, provenance, package version, passive manifest and existing-version conflict behavior |
| Removed component | Selection menu, tag mapping, provisioning, agent routing, Renovate coverage, tests and documentation; installed private state is not an automatic cleanup target |

A pin can protect a reviewed source identity without locking every transitive dependency. Keep checksum-coupled updates manual until their complete update mechanism is reviewed. Do not add fallback installers, migration paths or silently switch products to make an upgrade appear successful.

## Update an existing workstation

Run from this checkout inside Ubuntu. Keep application work in its own repositories. Start with a clean Workstation checkout; if `git status --short` shows edits, finish or preserve them explicitly before updating. Do not stash/reset them automatically. Record the current commit and branch so there is a known source revision to return to:

```sh
git status --short
git rev-parse HEAD
git branch --show-current
git pull --ff-only
```

Review the diff from the recorded commit to `HEAD`, especially defaults, task behavior and configuration sources. For example, replace `PREVIOUS_COMMIT` with the recorded hash:

```sh
git diff --stat PREVIOUS_COMMIT..HEAD
git diff PREVIOUS_COMMIT..HEAD -- ansible dotfiles
```

Choose the relevant scope rather than applying everything for a documentation-only update:

| Changed component | Apply tag | State it manages |
| --- | --- | --- |
| Shell/default CLI | `shell` / `cli_tools` | Zsh/Starship files, packages, aliases and selected binaries; CLI collisions stop for ownership review. |
| Runtimes/PHP/Composer | `runtimes` | PHP build prerequisites, managed mise configuration, pinned runtimes and Composer. Project lockfiles stay authoritative. |
| Git | `git` | Managed `~/.gitconfig`; existing content receives an Ansible backup. |
| Codex settings only | `codex_config` | Replaces the complete `~/.codex/config.toml` from the configured source, including rendered browser paths. |
| All Codex defaults | `codex` | Also replaces global AGENTS and command rules and manages the pinned plugin. |
| Chrome/Graphify | `chrome`, `graphify` | Managed Chrome or repository indexer; Chrome setup may change libraries/AppArmor policy. |
| Docker | `docker` | Repository, packages, service and optional Docker-group membership. |

On a prepared VM, preview then apply the chosen tag; this example updates Chrome and the managed Codex integration:

```sh
ansible-playbook ansible/site.yml --tags chrome,codex --check --diff --ask-become-pass
ansible-playbook ansible/site.yml --tags chrome,codex --ask-become-pass
```

Check mode is a preview, not proof that downloads, extraction or a live tool will work. Standalone tool tags require their documented prerequisites; use the [browser guide](browser.md) and [agent environment](agent-environment.md) for prerequisites. For a change spanning roles, review and apply the full playbook. Choose authorized [verification](verification.md) for the affected behavior; repeated apply should report `changed=0`. Open a new shell for shell/group changes and a new Codex session for configuration changes.

### Configuration ownership

This setup owns complete files, not only selected keys. A `codex_config` or `codex` apply replaces existing Codex user settings; `codex` also replaces `~/.codex/AGENTS.md` and `rules/default.rules`. Review the intended sources before applying. If personal instructions/settings must remain independent, select maintained source overrides (`codex_config_src`, `codex_agents_src`, `codex_rules_src`) through the ignored host variables, or omit the Codex scope deliberately. The config source is rendered as a template without appending tables. The default template owns the draw.io marketplace identity; a custom source owns its complete content, including marketplace registration when the plugin scope is used. Do not put credentials in managed sources or assume an Ansible backup exists for Codex files. Existing personal/shared skills are never installed or modified by Workstation.

Shell and Git tasks have their own backup behavior; VS Code merges its selected settings. Consult each role before assuming a whole-machine merge or rollback. For changes that require restoring previous system/user state, arrange a VM checkpoint or approved backup with your existing VM manager before applying. No checkpoint or private-file backup is created by these update commands.

### Recover from a failed update

Keep the checkout, ignored host variables, VM and application data intact. Read the failing task and preserve its output. A download/checksum failure or an unrelated-file ownership error is a stop condition; do not delete user files or bypass the guard. Fix the cause and repeat only the relevant scope. An interrupted Chrome extraction is retried by its task; a success marker is written only after extraction finishes.

If the new source behavior is unsuitable, first ensure the checkout is clean, then use the recorded known-good commit in a detached checkout and reapply only the reviewed scope:

```sh
git status --short
git switch --detach KNOWN_GOOD_COMMIT
ansible-playbook ansible/site.yml --tags AFFECTED_TAG --check --diff --ask-become-pass
ansible-playbook ansible/site.yml --tags AFFECTED_TAG --ask-become-pass
```

Replace the placeholders; do not run them literally. Return to the recorded branch after recovery. Source rollback is not a complete machine rollback: APT updates, an existing Codex CLI, container/application data and removed or overwritten user files are not automatically restored. Use the checkpoint/approved recovery path when those states matter; changing a Git ref cannot restore them. Retain old tool environments while any process may still use them. Plugin revision conflicts have a [specific recovery procedure](codex.md#recover-a-marketplace-conflict); do not delete the plugin cache or rebuild the VM as a shortcut.

## Windows rollout

The launcher executes its linked checkout, while in-progress builds/clones retain their recorded payload identities. Rerunning launcher installation updates the forwarding files; it does not upgrade VMs or rebuild published bases. Recipe changes select new versioned images. Follow [Hyper-V recovery](hyperv.md#recovery-compatibility-and-validation) for interrupted operations; do not edit a recovery record or delete its payload to force it onto newer source.
