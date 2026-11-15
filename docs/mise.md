# Runtimes, PHP and Composer

Mise manages Node.js, Python, Go, Bun and PHP and keeps their versions in one project-owned configuration instead of maintaining separate version managers. The `php` role installs build dependencies before mise compiles PHP; the mise role installs checksum-pinned Composer alongside it.

- **Official docs:** [mise](https://mise.jdx.dev/)
- **Source repository:** [jdx/mise](https://github.com/jdx/mise)
- **Managed by:** `mise`
- **Configuration:** [dotfiles/mise/config.toml](../dotfiles/mise/config.toml)
- **Installed as:** `~/.config/mise/config.toml`
- **Binary:** `~/.local/bin/mise`

## Managed runtimes

The [mise configuration template](../dotfiles/mise/config.toml) pins the Node.js, Python, Go, Bun and PHP versions installed by the `mise` role, together with uv, Ruff, ast-grep, actionlint, fzf and zoxide.

`workstation_languages` selects which language entries are rendered; shared CLI entries are always included. Direct Ansible applies default to `[node, python, go, bun, php]`. Set the list in ignored host variables to narrow it, or use `[]` for shared tools only. The Windows domain menu supplies this list from the selected languages and disclosed tool dependencies. PHP build packages and Composer are skipped when PHP is absent. A custom `mise_config_src` is rendered as a template and must respect the same selection if selective installs are required. Narrowing configuration does not uninstall existing runtimes.

## Project versions and activation

- One mechanism manages the language runtimes listed in the mise configuration.
- Runtime versions are explicit; PHP is compiled against the installed Ubuntu libraries.
- The same mechanism can activate tools per project when a repository defines its own `mise.toml`.
- Zsh loads shims through `.zshenv` and interactive hooks through `.zshrc`; see [session activation](shell.md#session-activation).

Mise installs the listed runtimes and standalone CLI tools for the user. It does not install application dependencies into projects. Keep project-local tool versions and validation configuration in their own manifests. uv manages Python dependency environments; for models requiring Python 3.12, select that interpreter in the model project rather than changing the workstation-wide Python default.

## PHP and Composer

PHP is pinned in `dotfiles/mise/config.toml`. The `php` role installs Ubuntu build dependencies before the `mise` role compiles PHP through its [vfox backend](https://github.com/jdx/vfox-php). The backend enables common extensions including MySQL, mbstring, XML, ZIP and curl and installs Composer alongside PHP. The mise role then replaces the bundled Composer with the version and checksum pinned in `ansible/roles/mise/defaults/main.yml`. No application service is started.

Apply the PHP prerequisites and managed runtime configuration from the Workstation root:

```sh
ansible-playbook ansible/site.yml --tags php --ask-become-pass
```

The tag includes the mise role and therefore installs all missing tools in the rendered configuration, not only PHP. PHP prerequisites and Composer run only when `php` is in `workstation_languages`. Enter the sudo password in your terminal. PHP's first installation compiles from source and takes longer than downloading a runtime binary.

Composer resolves through the mise shim. This baseline does not migrate older standalone launchers or remove distribution packages. Ubuntu PHP extensions and `/etc/php` settings do not configure mise's PHP. Project dependencies remain local: run `composer install` in the project's Composer directory.

The PHP backend sets `COMPOSER_HOME` inside the selected PHP installation. Existing global Composer packages and settings are not automatically migrated; project lockfiles remain authoritative.

## Dependency update proposals

[renovate.json](../renovate.json) configures the hosted Renovate GitHub App. After this configuration is merged, install or configure [Renovate](https://github.com/apps/renovate) for `alikayar/workstation` only and complete its onboarding if offered. No workstation service, repository token or self-hosted workflow is required. The repository file alone does not grant the app access or start the bot.

The bot proposes updates on Monday before 10:00 in Europe/Istanbul, with at most three active update PRs and no automatic merges. Releases with timestamps wait seven days; prereleases are excluded. Node uses Renovate's LTS-aware `node` versioning, so a new major is proposed after that line reaches LTS. Go and the other tracked tools follow stable releases. Exact pins remain in the source; merging a PR does not provision an existing VM.

The mise configuration contains Jinja conditionals, so Renovate uses explicit `# renovate:` annotations instead of the TOML manager. Coverage includes all language/runtime and shared CLI pins in that template, Graphify/MarkItDown/Lighthouse package versions, Python/npm MCP package versions and digest-pinned GitHub Actions. Keep annotations immediately above the version assignment. Bun, PHP and Bitwarden use explicit tag-prefix extraction so vendor tag prefixes are not written into mise's version values.

Checksum-coupled downloads (mise installer, Composer, Starship, browser engines, SiteOne, Packer and installation media), the pinned Graphify Python compatibility runtime, reviewed Codex installer/plugin revisions and bundled theme/icon snapshots remain deliberate manual updates. Do not add a version-only rule for those downloads: version, URL, checksum and any matching recipe must change together. Review update diffs and use the [verification guide](verification.md); automatic source checks do not establish full-install or Windows compatibility.

See Renovate's [regex manager](https://docs.renovatebot.com/modules/manager/regex/) and [Node versioning](https://docs.renovatebot.com/modules/versioning/node/) documentation for extraction and LTS behavior.
