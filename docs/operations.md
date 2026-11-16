# Diagnose Ubuntu and manage task services

Workstation installs `workstation-doctor` and `workstation-service` with the `cli_tools` role into the development user's `~/.local/bin`. Both use Ubuntu's system Python, so project runtime overrides do not replace their interpreter. They require no MCP server or persistent Workstation daemon. Run them inside the intended Ubuntu project; tool availability does not authorize diagnostics or starting a service without the task's requested scope.

## Installation and prerequisites

A normal full apply or confirmed Windows Ubuntu development selection includes these commands. To install them and their common prerequisites on a prepared workstation:

```sh
ansible-playbook ansible/site.yml --tags base,cli_tools --ask-become-pass
```

The base role runs before installers and explicitly supplies certificates, curl, archive tools, system Python, process/network inspection tools and the systemd user-session package. If any language is selected, it also installs `build-essential` and `pkg-config` for native dependencies, independently of PHP or Docker. System Python belongs to provisioning/tooling and is distinct from a selected mise Python. Project-specific library headers, Rust/CUDA toolchains and application dependencies remain project-owned.

The base role participates in the full installer tags for shell, Codex, mise/runtimes/PHP, shared CLI tools, Docker, Graphify and Chrome, so those scoped applies can establish common prerequisites first. Configuration-only tags remain narrow. `cli_tools_config` copies only the two commands on a prepared environment; it does not install packages. Linked command paths and unrelated existing commands are refused rather than overwritten. No task service is started, no user linger policy is changed and no sudoers rule is added by this command installation.

## Read-only diagnosis

From the project's directory, select the commands and project runtimes relevant to the task:

```sh
workstation-doctor
workstation-doctor --json --require git mise node codex --runtime node --runtime python
```

Default required commands are Git, mise, curl, system Python, ripgrep and the task-service helper. `--require` replaces that list; an intentionally omitted component need not be required. `--runtime` may be repeated for `node`, `python`, `go`, `bun` or `php`; it asks mise for the installed project-selected path with auto-install disabled. The report keeps command resolution separate from mise runtime resolution, so an active virtual environment or shim can be recognized without inspecting private configuration values.

The remaining observations are the account login shell, systemd user-manager availability, AppArmor service status, current filesystem free space, available RAM and ability to connect to the local `/var/run/docker.sock`. The Docker observation sends no API request, does not enumerate containers and does not inspect remote/rootless daemons. Missing service access is UNKNOWN. The fixed low-space/low-memory warnings are diagnostic hints (2 GiB free disk and 512 MiB available RAM), not capacity estimates or an assertion that an application can run.

To inspect a known managed Chrome executable, pass its exact path with `--chrome`; find the configured version/path in the [browser guide](browser.md). This checks file/executable availability without launching Chrome. AppArmor being active does not prove that Chrome's namespace policy is loaded or that sandbox enforcement has been tested.

Output distinguishes **OK**, **WARN** and **UNKNOWN**. Exit 0 means all requested observations were OK, exit 1 means at least one warning, and exit 2 means unavailable observations without a warning or a diagnostic error. Optional Docker or user-manager observations can therefore yield exit 2 on a deliberately minimal environment. Inspect the findings instead of treating unavailable providers as healthy. The command does not repair, install, print environment/config contents, inspect authentication files or query project databases.

## Start one owned task service

Use the project's normal foreground development command. It must stay in the foreground inside its service; do not append `&`, daemonize it or use another process supervisor. Generate one UUID for this task and record its literal value, directory, unit name and stop command. Shell variables do not persist across separate agent tool calls.

```sh
task_id=$(cat /proc/sys/kernel/random/uuid)
workstation-service start --task "$task_id" --directory "$PWD" \
  --memory 2G --cpu 100 --seconds 3600 \
  -- "$HOME/.local/bin/mise" exec -- npm run dev
```

The command resolves the executable, uses the selected working directory and starts `workstation-task-UUID.service` through the existing systemd user manager. It returns selected unit properties as JSON. Defaults are 2 GiB RAM, 100% CPU (one CPU worth of execution) and a 3,600-second runtime limit. Memory accepts integer `M`/`G` values from 64M through 1024G; CPU accepts 1–10000 percent; runtime accepts 1–86400 seconds. These are explicit limits, not reservations or dynamic sizing. Child processes belong to the unit's control group and are stopped with it. An exited foreground command remains represented until explicitly stopped, enabling inspection.

Systemd starts a service with its own environment; the caller's activated virtual environment and shell exports are not copied. Use the project's explicit interpreter, mise command or normal application env loader. Command arguments retain literal dollar expressions; shell expansion is not introduced by the helper. Keep secrets out of CLI arguments. Provisioning and this helper never enable lingering, start a missing bus, elevate or alter the project's env file.

A failed/unavailable user manager or rejected resource property is a failure, not a reason to relaunch unmanaged or as root. Login/session lifetime controls the user manager when lingering is disabled; a service is not promised to survive the final logout or VM shutdown. A successful start confirms process launch, not application readiness. Verify the application's own health/ready condition before browser work. Persistent multi-service dependency orchestration remains project-owned; process-compose is not installed by Workstation.

## Inspect and stop only that task

Reuse the literal UUID and original directory:

```sh
workstation-service status --task "$task_id" --directory "$PWD"
workstation-service logs --task "$task_id" --directory "$PWD" --lines 100
workstation-service stop --task "$task_id" --directory "$PWD"
```

Status exposes selected state/result/PID/limit properties, not environment or complete command lines. Logs explicitly request the task's application output and may contain private data; retain them under the project's artifact policy. Log requests are bounded to 1–1000 entries. Stop targets the exact owned unit and its control group. Cleanup belongs in a task's final path after success, failure or cancellation; report a failure with the exact UUID/unit rather than killing processes by name. The helper refuses an already loaded task UUID and refuses status/log/stop operations whose description or working directory differs. Use a new UUID for a new task.

A forgotten ID can be located with `systemctl --user list-units 'workstation-task-*' --all`; confirm ownership and the original working directory before acting on it. Do not run a broad stop against that pattern. Failed/inactive unit metadata is distinct from running processes. No automatic artifact or unrelated-service cleanup is performed.

UUID/directory checks are ownership conventions within one development account, not a boundary against another process with the same UID. Resource limits do not sandbox filesystem/network access. Keep browser MCP processes under their client's existing lifetime rather than detaching them into these services. The [verification guide](verification.md) records isolated and real-user-manager coverage; [security boundaries](security.md) owns the broader VM/host limits.

## Inspect the agent environment

When a tool is missing or resolves to an unexpected version, run the relevant commands from the active project directory. Project configuration takes precedence over workstation defaults; these commands do not replace project checks.

```sh
command -v node python3 go bun uv codex
mise which node
MISE_AUTO_INSTALL=0 node --version
```

Replace `node` with the affected tool; Go uses `go version`. In a shell without mise shims on PATH, use `~/.local/bin/mise exec -- COMMAND` with `MISE_AUTO_INSTALL=0` to avoid installing a missing runtime during inspection.

For local Docker access issues, explicitly target the VM's daemon:

```sh
docker --host unix:///var/run/docker.sock info --format '{{.ServerVersion}}'
```

This does not inspect rootless or remote Docker daemons. MCP configuration files also cannot establish which tools the current chat exposes; inspect the chat's available tools separately.

## Sudo compatibility

Ubuntu 26.04 uses `sudo-rs` by default, whose password prompt is not understood by some distribution-packaged Ansible versions. The bootstrap package list includes `sudo` so the classic `/usr/bin/sudo.ws` is available. The playbook checks for that executable without privilege escalation and selects it only when no host/CLI `ansible_become_exe`, `ANSIBLE_BECOME_EXE` or configured become executable override was supplied. It leaves the ordinary `sudo` default in place when the classic binary is absent. No sudoers changes or system-wide provider switch are needed.

Use the Ubuntu user's password at the `BECOME password` prompt. Do not run the playbook itself as root: user-local configuration depends on the intended account's `USER` and `HOME`.

To bootstrap an older checkout affected by prompt detection, install classic sudo and select it just for that invocation:

```bash
sudo apt-get install --yes sudo
ANSIBLE_BECOME_EXE=/usr/bin/sudo.ws ansible-playbook ansible/site.yml --ask-become-pass
```

The automatic choice is a compatibility default, not a requirement to replace a working custom escalation setup. See [Ubuntu's sudo-rs notes](https://ubuntu.com/server/docs/reference/other-tools/sudo-rs/) and the [Ansible prompt compatibility issue](https://github.com/ansible/ansible/issues/85837).
