# Runtimes, PHP and Composer

Mise manages Node.js, Python, Go, Bun and PHP and keeps their versions in one project-owned configuration instead of maintaining separate version managers. The `php` role installs build dependencies before mise compiles PHP; the mise role installs checksum-pinned Composer alongside it.

- **Official docs:** [mise](https://mise.jdx.dev/)
- **Source repository:** [jdx/mise](https://github.com/jdx/mise)
- **Managed by:** `mise`
- **Configuration:** [dotfiles/mise/config.toml](../dotfiles/mise/config.toml)
- **Installed as:** `~/.config/mise/config.toml`
- **Binary:** `~/.local/bin/mise`

## Managed runtimes

The [mise configuration](../dotfiles/mise/config.toml) pins the Node.js, Python, Go, Bun and PHP versions installed by the `mise` role, together with uv, Ruff, ast-grep, actionlint, fzf and zoxide.

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

The tag includes the mise role and therefore installs all missing configured tools, not only PHP. Enter the sudo password in your terminal. PHP's first installation compiles from source and takes longer than downloading a runtime binary.

After PHP and pinned Composer are installed, the old Workstation launcher at `~/.local/bin/composer` is removed so the mise shim owns Composer resolution. Existing Ubuntu PHP packages are left installed for applications that explicitly use `/usr/bin/php`; their extensions and `/etc/php` settings do not configure mise's PHP. Project dependencies remain local: run `composer install` in the project's Composer directory.

The PHP backend sets `COMPOSER_HOME` inside the selected PHP installation. Existing global Composer packages and settings are not automatically migrated; project lockfiles remain authoritative.
