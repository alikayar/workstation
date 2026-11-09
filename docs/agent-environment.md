# Agent environment

Workstation provides executables, version defaults, launchers and their usage guides. `dotfiles/codex/AGENTS.md` provides portable execution rules and tool entry points; this repository’s `AGENTS.md` describes its maintenance workflow. Consuming projects own their service commands, ports, architecture and evaluation questions. The instructions and tool guides shipped here are sufficient to use the environment.

## Version policy

- Mise, runtime tools, Composer, selected binaries and MCP packages use reviewed pins already maintained in their respective defaults. APT packages follow Ubuntu's package updates.
- The Codex role bootstraps a missing CLI through an upstream commit and checksum-pinned installer, but neither pins the resulting CLI release nor upgrades/downgrades an existing executable. The immutable installer URL avoids breaking fresh installs when the public installer endpoint changes. Desktop/CLI updates remain explicit lifecycle decisions; this avoids Ansible fighting the desktop updater. Do not describe the entire environment as bit-for-bit reproducible.
- Update a tool's pin only after reviewing its release and the behavior used here. Apply the relevant role, run authorized checks, and review project overrides before changing an active version.
- Optional Python tools live in separate versioned environments. Top-level packages are pinned; transitive dependencies are not locked. Old environments are retained until deliberately removed, since another process may still use them.
- Agent-browser and Chrome for Testing use explicit version and SHA256 pins. The native CLI has no npm runtime dependency; APT browser libraries follow Ubuntu updates.

## Document conversion

Enable MarkItDown with `agent_tools_markitdown_enabled: true` in the ignored local host variables and apply the `agent_tools` role. The existing mise/uv/Python setup must be installed first.

Use `workstation-markitdown input.pdf -o output.md`. The launcher points to an isolated uv tool environment under `~/.local/share/workstation/markitdown-0.1.9/`, with only the PDF, DOCX, PPTX and XLSX extras requested. It does not enable third-party converter plugins or configure hosted AI services. Text extraction does not prove layout, OCR or complex table fidelity.

Disabling the setting skips future installation; it does not uninstall an existing environment or launcher.

## Browser automation

The Ubuntu `agent_tools` role installs **agent-browser 0.41.2** and **Chrome for Testing 157.0.8103.38** by default on x86_64. Both downloads are versioned and SHA256 checked. Version directories under `/opt/workstation` are root-owned. Chrome's completed extraction is recorded only after unpacking; an interrupted extraction is retried. Old versions, artifacts and the verified archive cache are retained.

Chrome for Testing does not provide a Linux ARM64 download. `agent_tools_browser_enabled` therefore defaults to false on ARM64; explicitly enabling it there stops with an explanation. Other roles retain their ARM64 support. Setting this variable to false skips future installation; it does not uninstall an existing browser.

Full workstation provisioning includes this setup. To apply it separately, run inside Ubuntu from the repository root:

```sh
ansible-playbook ansible/site.yml --tags agent_browser,codex --ask-become-pass
```

The `agent_browser` tag installs only browser dependencies and launchers. The `codex` tag also applies the existing Codex role, including its managed global instructions and configuration; that role remains their single owner. Applying either role does not authorize or run browser verification or install external skills. Browser setup refuses to replace unrelated or linked `~/.local/bin/agent-browser` and `workstation-browser-task` files. Existing user and project browser configuration is not overwritten; the launcher loads a separate managed config. It clears inherited browser settings and refuses session/profile/restore/CDP/provider, config/executable, headed and idle-timeout overrides. These managed commands intentionally expose a subset of upstream CLI flags: use `agent-browser --session TASK COMMAND [FLAGS ...]`, with formatting flags such as `--json` after the command. `connect` and identity/profile overrides are refused; `wait --state` still controls element visibility. `--help` and `--version` remain available without starting a session. Preview mode skips downloads; it does not verify asset availability or checksum bytes.

### One foreground workflow

```sh
workstation-browser-task sh -eu -c '
  agent-browser open http://127.0.0.1:3000
  agent-browser snapshot -i
  agent-browser screenshot
'
```

The helper generates a unique session and a mode-0700 directory under `~/.local/share/workstation/browser-tasks`, prints both to stderr and passes session/output settings to child commands. It clears inherited `AGENT_BROWSER_*` settings first, so profile, CDP and provider settings are not inherited. Cleanup closes only its own session after the foreground command exits, including failures and handled INT/TERM/HUP signals. Artifacts remain for review. A successful workflow with failed cleanup returns nonzero; an already-failed workflow keeps its failure status. Do not detach browser commands or servers from this scope.

### Agent steps across tool calls

Generate a unique ID once:

```sh
printf 'task-%s\n' "$(cat /proc/sys/kernel/random/uuid)"
```

Record the printed ID and pass that literal value on every subsequent command, replacing `TASK_ID` below:

```sh
agent-browser --session TASK_ID open http://127.0.0.1:3000
agent-browser --session TASK_ID snapshot -i
agent-browser --session TASK_ID screenshot /absolute/project/artifacts/page.png
agent-browser --session TASK_ID close
```

Managed Codex instructions require explicit close at task completion, including failure/cancellation. There is no reliable OS event for the end of an arbitrary agent chat, so this multi-call workflow still requires agent cleanup. Never close all sessions. SIGKILL, power loss and disconnected agents can bypass cleanup; the five-minute native idle timeout is a fallback for local headless sessions. Keep headed, remote-attached and restored personal profiles outside this workflow.

The browser runs inside Ubuntu and reaches the application's VM-local address. Inspect screenshots for layout checks; accessibility snapshots alone do not prove visual correctness. Session separation is not a security boundary against processes running as the same Unix user. Browser execution still needs the user's authorization.

On AppArmor-enabled Ubuntu, a profile permits user namespaces for the exact root-owned Chrome executable, following [Chromium's documented approach](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md). The exact policy is reloaded on each apply so a previously interrupted apply can recover even when its file is unchanged. File changes carry the Ansible change report; the derived kernel reload does not restart the AppArmor service. The role does not disable AppArmor globally, add a SUID executable or pass `--no-sandbox`. This grants namespace use; it is not full filesystem/network confinement. Upstream agent-browser itself disables Chrome sandboxing under root, `CI` and container environments; use the intended non-root native VM and do not treat CI/container launches as sandbox verification.

Upstream: [installation](https://agent-browser.dev/installation), [sessions](https://agent-browser.dev/sessions), [commands](https://agent-browser.dev/commands). The CLI digest comes from upstream v0.41.2 release asset metadata; the Chrome SHA256 was calculated from Google's version-specific archive. Checksums freeze these bytes; they are not vendor signatures.

## Repository knowledge indexing

The `agent_tools` role provides `workstation-graphify` by default (`agent_tools_graphify_enabled: false` skips provisioning without uninstalling an existing tool). Graphify and its separate mise Python runtime are version-pinned in the role defaults and installed in a user-owned uv tool environment. Project runtimes, manifests and lockfiles are unchanged. The workstation must already provide mise and uv; this scoped apply installs only the Graphify environment and launcher:

```sh
ansible-playbook ansible/site.yml --tags graphify
```

Provisioning does not index repositories, start a server/watcher, register an MCP or install upstream skills/hooks. The managed global instructions introduce the CLI workflow; this page is its complete installation and usage guide. This page covers scope selection, index creation/update and queries.

From a Git checkout, use:

```sh
workstation-graphify info
workstation-graphify index
workstation-graphify index --docs docs
workstation-graphify query "request" --budget 1200 --depth 2
workstation-graphify explain "packages/api/request.ts::request"
workstation-graphify path "OrdersPage" "request"
workstation-graphify update
```

Use `workstation-graphify --root /path/to/checkout <command>` from elsewhere. The Git top-level directory is the index scope. A SHA256 of its canonical path selects a private directory under `~/.cache/workstation/graphify/`, separating repositories and worktrees. `info` shows the exact cache, graph, package version, prior scope and official semantic extraction-spec path. Nothing is written into the checkout or its Git ignore configuration. Cache artifacts describe repository contents; keep them local unless their publication is explicitly requested. Cache cleanup is a separate deliberate action.

The adapter calls real Graphify extraction/build/query APIs and bypasses upstream global skill refresh and provider bootstrap. It forces model backends off and query logging off. Git-ignored untracked files, known secret/auth files, linked paths, dependencies and generated output are excluded before extraction; `.graphifyignore` can further narrow included supported files. Both tracked and non-ignored untracked sources can be indexed. Filename/ignore exclusions are not a general secret-content scanner; keep private material outside the allowed source set.

Default indexing extracts code AST relationships and Markdown structure locally. `index` and `update` rebuild from the current included corpus while reusing Graphify's per-file extraction cache; deletion therefore removes old nodes. Queries compare included paths, modification time/size metadata and tool version with the saved index and refuse stale/missing output. Deliberately preserved metadata can defeat this freshness check. Open current source/contracts to verify results; a relationship does not establish an adopted architectural rule. A missing match or same-name ambiguity is a reason to narrow the query or use source search, not evidence that the implementation is absent.

For automated semantic document ingestion, run `workstation-graphify index --docs docs` or name specific Markdown files/directories after `--docs`. With no paths, `--docs` selects all included Markdown. The adapter invokes the workstation's existing `codex exec` using its normal model/configuration and login; it does not request an API key, copy authentication files or add provider env variables. Codex must already be installed through the `codex` role. The subprocess is read-only and ephemeral, with shell, delegation, Workstation-managed MCP servers, app tools and web search disabled for that invocation, and receives complete selected documents through stdin under the installed official extraction spec and a strict JSON output schema. No global Codex configuration or approval rules are changed. This is model processing through Codex's normal data boundary, not offline analysis.

`update` remembers the docs selection. It reuses semantic output when the selected file set and metadata are unchanged; additions, edits and deletions regenerate that selected set in batches. Code-only changes reuse semantic docs without a model call. Generation/coverage/reference failures and timeouts stop publication and retain the prior graph. Actual available Codex token usage, call duration and scope are recorded in private index metadata; missing usage remains unknown. Successful raw CLI events/prompts are not persisted by the adapter. A failed CLI's stderr is retained privately as `codex-error.txt` for diagnosis. Do not inspect auth files to troubleshoot a login failure.

`update --structure-only` explicitly drops semantic coverage and automatic docs selection. Manual import through `index --semantic /path/to/cache/extraction.json` remains available; source paths must belong to the included corpus and semantic provenance is stamped. Manual fragments require explicit regeneration when their contributing sources change. No Graphify Cloud upload or separate Graphify model provider is configured.

Repository indexing and queries are task-scoped discovery, not application validation. Tool availability grants no permission for tests, builds, browser work, additional model providers, publication or Git actions. Follow the active repository’s instructions and source scope; a small known change can use direct search without building any graph.

## Website audits

The `agent_tools` role installs Lighthouse 13.6.0 on supported browser hosts (`agent_tools_lighthouse_enabled` follows `agent_tools_browser_enabled` by default). The official npm package lives in a versioned Workstation tool directory. Its `lighthouse` entry point selects the installed workstation Node and managed Chrome; application manifests/runtimes stay unchanged. The five-line launcher only supplies executable paths, including Lighthouse's native `CHROME_PATH` internally. No user env export, custom collector or Docker image is needed.

The same role installs SiteOne Crawler 2.5.1 from checksum-pinned upstream static Linux archives for x64 and ARM64. A direct `siteone-crawler` symlink selects its versioned user-local installation, retaining the upstream license. It has no wrapper, service, database, additional AI provider or application dependency. HTTP crawling works without Chrome; optional rendering needs an explicitly selected existing browser and browser authorization. `--tags siteone` installs only the crawler. Installation does not start a crawl, and the CLI's native AI/upload/browser-download features are not configured or enabled by Workstation.

A full apply installs managed Chrome before Lighthouse. On an existing prepared VM, install the audit tools:

```sh
ansible-playbook ansible/site.yml --tags lighthouse,siteone
lighthouse --version
```

If managed Chrome is absent, apply `--tags agent_browser,lighthouse` with the normal become authorization. This reuses the existing browser libraries/AppArmor policy; it does not disable Chrome sandboxing. Installation starts no browser or service.

Use native JSON/HTML reports, plus Lighthouse `--save-assets` for traces/devtools logs. `lighthouse --help`, `siteone-crawler --help`, the [Lighthouse CLI documentation](https://github.com/GoogleChrome/lighthouse#using-the-node-cli) and [SiteOne documentation](https://github.com/janreges/siteone-crawler/tree/v2.5.1) define their interfaces. Keep reports under the consuming project's ignored-results policy or a private temporary directory. Browser execution, application startup and repeated measurements require their applicable task authorization.

Workstation installs the tools independently of agent skills. Audit workflows and interpretation guidance belong to separately managed skills or the consuming project; provisioning does not inspect or modify those sources.
