# Agent environment

Workstation provides executables, version defaults, launchers and their usage guides. `dotfiles/codex/AGENTS.md` provides portable execution rules and tool entry points; this repository’s `AGENTS.md` describes its maintenance workflow. Consuming projects own their service commands, ports, architecture and evaluation questions. Personal/shared engineering skills are maintained separately; tool installation does not depend on them.

| Task | Section |
| --- | --- |
| Diagnose Ubuntu or manage an owned development service | [Ubuntu operations](operations.md) |
| Review pins and upgrade limits | [Version policy](maintenance.md#version-policy) |
| Run an authorized browser workflow and close its session | [Browser automation](browser.md) |
| Discover code relationships or index documentation | [Repository knowledge indexing](#repository-knowledge-indexing) |
| Inspect a page or run a supported audit | [Browser guide](browser.md) |

## Version policy

The [maintenance guide](maintenance.md#version-policy) owns pin policy, retained environments, dependency proposals and upgrade review. Installed versions can differ from source defaults; inspect command resolution from the active project before changing an environment.

## Browser automation

Chrome for Testing and Chrome DevTools MCP are the single managed browser workflow. The [browser guide](browser.md) owns installation, task isolation, page/screenshot checks, audits and cleanup.

## Repository knowledge indexing

Code discovery uses Graphify plus direct source search without a default language-server MCP. The [comparison and decision](code-discovery.md) records the measured tradeoffs.

The `agent_tools` role provides `workstation-graphify` by default (`agent_tools_graphify_enabled: false` skips provisioning without uninstalling an existing tool). Graphify and its separate mise Python runtime are version-pinned in the role defaults and installed in a user-owned uv tool environment. Project runtimes, manifests and lockfiles are unchanged. The workstation must already provide mise and uv; this scoped apply installs common prerequisites plus the Graphify environment and launcher:

```sh
ansible-playbook ansible/site.yml --tags graphify
```

Provisioning does not index repositories, start a server/watcher, register an MCP or install upstream skills/hooks. The managed global instructions introduce the CLI workflow; this page is its complete installation and usage guide.

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

### Scope and freshness

The adapter calls real Graphify extraction/build/query APIs and bypasses upstream global skill refresh and provider bootstrap. It forces model backends off and query logging off. Git-ignored untracked files, known secret/auth files, linked paths, dependencies and generated output are excluded before extraction; `.graphifyignore` can further narrow included supported files. Both tracked and non-ignored untracked sources can be indexed. Filename/ignore exclusions are not a general secret-content scanner; keep private material outside the allowed source set.

Default indexing extracts code AST relationships and Markdown structure locally. `index` and `update` rebuild from the current included corpus while reusing Graphify's per-file extraction cache; deletion therefore removes old nodes. Queries compare included paths, modification time/size metadata and tool version with the saved index and refuse stale/missing output. Deliberately preserved metadata can defeat this freshness check. Open current source/contracts to verify results; a relationship does not establish an adopted architectural rule. A missing match or same-name ambiguity is a reason to narrow the query or use source search, not evidence that the implementation is absent.

### Concurrent agents and publication

Queries and `info` capture one immutable published generation and do not acquire the writer lock. Index/update operations serialize with a bounded wait: five seconds by default, configurable with the global `--lock-timeout` option (0–300 seconds, before the subcommand). A busy writer yields an explicit timeout; it does not fall back to a different index or silently accept stale data. For example, `workstation-graphify --lock-timeout 0 update --structure-only` refuses immediately if another writer is active.

Each successful build writes graph, semantic content and metadata into one private immutable generation, then atomically replaces `current.json`. Before the atomic pointer replacement, failed publication retains the previous pointer; interruption around that cutover exposes a complete old or new generation, never a mixed snapshot. Queries still refuse stale source metadata while a rebuild is in progress; nonblocking reads do not promise a fresh answer during source edits. Generations remain available for readers that already captured them. Old generations and interrupted unpublished generations are retained, consuming disk space; cache cleanup requires a deliberate idle/exclusive maintenance window, never deleting another agent's active snapshot. There is no background garbage collector.

`info` reports the current generation's graph path, or null before the first publication. Consumers must use the graph path returned after each successful index/update rather than assuming a stable `cache/graph.json` pathname. Older flat-layout caches are not migrated; explicitly rebuild after installing this adapter. The benchmark adapter follows the newly published graph on refresh, and historical benchmark measurements remain tied to their recorded runner source hashes.

### Semantic documentation through Codex

For automated semantic document ingestion, run `workstation-graphify index --docs docs` or name specific Markdown files/directories after `--docs`. With no paths, `--docs` selects all included Markdown. The adapter invokes the workstation's existing `codex exec` using its normal model/configuration and login; it does not request an API key, copy authentication files or add provider env variables. Codex must already be installed through the `codex` role. The subprocess is read-only and ephemeral, with shell, delegation, Workstation-managed MCP servers, app tools and web search disabled for that invocation, and receives complete selected documents through stdin under the installed official extraction spec and a strict JSON output schema. No global Codex configuration or approval rules are changed. This is model processing through Codex's normal data boundary, not offline analysis.

`update` remembers the docs selection. It reuses semantic output when the selected file set and metadata are unchanged; additions, edits and deletions regenerate that selected set in batches. Code-only changes reuse semantic docs without a model call. Generation/coverage/reference failures and timeouts stop publication and retain the prior graph. Actual available Codex token usage, call duration and scope are recorded in private index metadata; missing usage remains unknown. Successful raw CLI events/prompts are not persisted by the adapter. A failed CLI's stderr is retained privately as `codex-error.txt` for diagnosis. Do not inspect auth files to troubleshoot a login failure.

`update --structure-only` explicitly drops semantic coverage and automatic docs selection. Manual import through `index --semantic /path/to/cache/extraction.json` remains available; source paths must belong to the included corpus and semantic provenance is stamped. Manual fragments require explicit regeneration when their contributing sources change. No Graphify Cloud upload or separate Graphify model provider is configured.

### When to use an index

Repository indexing and queries are task-scoped discovery, not application validation. Tool availability grants no permission for tests, builds, browser work, additional model providers, publication or Git actions. Follow the active repository’s instructions and source scope; a small known change can use direct search without building any graph.

## Tool failures and retained state

| Symptom | Next action |
| --- | --- |
| `workstation-graphify` not found | Inspect the active project PATH/mise resolution, then check whether the Graphify scope was selected |
| Index missing or stale | Run the authorized `index`/`update` for the intended checkout; queries deliberately refuse stale state |
| Expected code missing from results | Check the supported source scope and ignore rules, then verify directly in source; a graph is not a complete architectural contract |
| Semantic documentation extraction fails | Preserve the private failure evidence and prior graph; verify Codex availability/sign-in without inspecting auth stores |
| Launcher already exists but provisioning refuses it | Establish ownership and retain the file; do not overwrite an unrelated or linked launcher |

A retained cache or versioned environment can still belong to another process. Removing it is a separate cleanup decision, not a generic response to a failed query. See [maintenance](maintenance.md) for update policy and [security boundaries](security.md#privilege-data-and-maintenance) for artifact/model-processing exposure.
