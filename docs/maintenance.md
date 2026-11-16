# Maintain and update Workstation

Use this guide when changing the workstation definition or reviewing a dependency proposal. [Ubuntu updates](getting-started.md#update-an-existing-workstation) own machine apply/recovery commands; [Windows recovery](windows.md#recovery-compatibility-and-validation) owns VM/image state. Updating source, updating an installed tool and proving the new behavior are separate operations.

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

## Roll out and recover

For Ubuntu, review the changes from the recorded prior commit, preview the relevant scope, apply it and open a new shell/agent session where required. Follow [configuration ownership](getting-started.md#configuration-ownership) before replacing full files. Ansible check mode is a preview and may not exercise downloads, extraction or tool startup. A clean source checkout does not mean machine state has been backed up.

For Windows, the launcher executes its linked checkout, while in-progress builds/clones retain their recorded payload identities. Rerunning launcher installation updates the forwarding files; it does not upgrade VMs or rebuild published bases. Recipe changes select new versioned images. Do not edit an in-progress recovery record or delete its payload to force it onto newer source.

Stop on checksum, ownership, identity or concurrent-write failures. Preserve records, disks, logs and the previous working source. Choose the component's documented recovery path; do not reset the repository, erase a tool cache or recreate the development VM as routine repair. Full rollback may require a separately prepared machine backup/checkpoint because reverting a Git commit cannot restore application data or overwritten user files.
