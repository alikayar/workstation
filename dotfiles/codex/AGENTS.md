# Prepared development environment

## Work within the task

- Work inside the prepared Ubuntu VM/WSL boundary. The active repository's instructions, manifests, lockfiles and configuration govern its architecture, dependencies and commands.
- Carry authorized work to a reviewable result. Read affected sources and Git status/diff, preserve unrelated edits and follow existing primitives. Add dependencies/configuration only for a concrete need. Keep the original goal when receiving corrections; ask only for material missing information or authorization not already given.
- Match the user's language. Report changed behavior, actual verification and limitations concisely. For long work, keep a short handoff; avoid routine planning files. When delegation is requested, bound ownership and review agents' changes before integrating them.

## Tools and data

- Zsh loads mise shims noninteractively. Otherwise use `~/.local/bin/mise exec -- COMMAND` from the project directory. Inspect command resolution before installing tools. Node, Python, Go, Bun and PHP are mise-managed; Composer is pinned beside PHP. Use uv for isolated Python dependencies.
- Prefer `rg`, ast-grep for structural matching, local sources and available semantic navigation. Use Context7 for external library docs. Configured MCPs and installed CLIs are distinct from tools exposed in the current chat.
- Never inspect credentials, private keys, authentication state or shell history, request secrets from tools or expose private env values. Use only the task's authorized environment/data. The opaque same-project env transfer below is the only exception for copying secret-bearing files.

## Execution permissions

- Creating/editing tests and running lint, format, tests, type checks, builds, syntax checks, browser verification, benchmarks, security scans or other validation require an explicit request for that scope. This includes automatic fixes, watch modes, aggregate commands and hooks. Continue implementation by source inspection without repeatedly asking for checks.
- Commit/push requests authorize those Git actions, not checks. Briefly identify relevant unrun checks, then proceed. Preserve test/CI infrastructure. If a required hook blocks progress, explain and request direction; never silently execute or bypass it.
- Commit, push, merge, PR creation, deployment, publication, messages to others and repository visibility changes require authorization. Honor existing restrictions and inspect intended diffs. Never bypass approval/command rules through alternate wrappers or spellings; prefix rules are only one safeguard.
- Browser execution requires explicit authorization. Chrome DevTools, Grafana and PostgreSQL are opt-in; availability does not authorize load tests, customer-data inspection, production queries or remote writes. Keep secret, artifact/dependency and CI auditing separate when requested. Claim only checks actually run.

## Worktrees and local env

Use native Git worktrees when isolation or parallel tasks need them; reuse the task checkout for sequential work. Inspect status, root, existing worktrees and base first. Normally use a separate branch and sibling `<repo>.worktrees/<task>`. Do not automatically stash, reset, move edits or replace an existing branch/directory. Agents sharing a task worktree need explicit file ownership.

On first creation, automatically carry forward the same project's established development env files to matching relative paths. Identify exact files from project conventions and a trusted checkout in the same VM; ask once for its path if unclear. Do not read values to classify files. Copy only untracked regular env files ignored in both checkouts, verified with tracking/ignore metadata. Tracked templates arrive through Git. Exclude production/staging envs, `.env.keys`, other projects, authentication stores, private keys and history. Do not blindly recurse `.env*` or change ignore rules to enable copying.

Treat eligible files as opaque bytes: never print, parse, summarize, interpolate or source them. Use exclusive/non-clobber creation, mode 0600 and independent copies; reject symlinks, hard links and path traversal outside approved roots. Preserve existing destination files. Reusing a worktree does not refresh envs without a request. Normal application env loading is allowed only during separately authorized commands. Keep envs ignored and out of commits/logs/artifacts; never force-add them. Do not transfer ignored dependencies, caches, virtualenvs or browser profiles; other configuration needs an explicit convention or instruction.

Worktrees isolate files, not processes, ports, databases or containers. Use supported non-secret task overrides; do not rewrite source envs or use production services. Creation does not authorize installs, checks or service startup. Record owned services/resources, their directory, port/PID or unit, logs and stop command; never stop unidentified processes. Report branch, checkout, changed paths and remaining resources at completion. Cleanup needs authorization and accounting for tracked, untracked and ignored data; never force-remove, broadly clean or delete source checkout/env files.

## Browser lifecycle

Use VM-local `agent-browser` with a unique task session; never `default`, another task's session or a host/personal browser. Read installed help rather than installing/upgrading tools. For one foreground workflow, prefer `workstation-browser-task COMMAND [ARG ...]`, which owns its session/artifact directory and cleanup; do not detach commands from it.

Across tool calls, generate and record one task UUID and use `agent-browser --session TASK_ID COMMAND [FLAGS ...]` every time; other flags follow the command. Exported shell variables do not persist across calls. Always close that session on success, failure or cancellation; never `close --all` or kill unrelated processes. Retry failed cleanup for that exact session and report it. The five-minute idle timeout is a fallback. Retain screenshots/failure artifacts and paths; inspect screenshots for visual correctness. Session separation is not VM security isolation.

## Repository discovery and output

Use repository docs and current source/contracts. Prefer direct search for small known changes. When useful, `workstation-graphify info`, `index`, `query "symbol"` and `update` provide a derived local index; update on source changes/staleness, not every turn. `index --docs docs` adds semantic extraction via existing `codex exec` access and remembers that scope for updates. It needs no new API key, provider env or project dependency. Cache stays outside Git; Codex retains its normal model data boundary. Verify graph candidates against current APIs and adopted architecture.

Keep Markdown paragraphs on one line. Update canonical project docs instead of duplicating manuals. Preserve the project's license and required asset notices, preferably with the asset. Avoid blanket third-party notice pages, duplicate license READMEs, theme/provenance reports or license-doc edits for routine visual/copy changes unless an actual license/catalog requires them.
