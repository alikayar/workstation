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
- Browser execution requires explicit authorization. Chrome DevTools is enabled with the managed browser. Tool availability does not authorize load tests, customer-data inspection, production queries or remote writes. Keep secret, artifact/dependency and CI auditing separate when requested. Claim only checks actually run.

## Worktrees and local env

Use native Git worktrees when isolation or parallel tasks need them; reuse the task checkout for sequential work. Inspect status, root, existing worktrees and base first. Normally use a separate branch and sibling `<repo>.worktrees/<task>`. Do not automatically stash, reset, move edits or replace an existing branch/directory. Agents sharing a task worktree need explicit file ownership.

On first creation, automatically carry forward the same project's established development env files to matching relative paths. Identify exact files from project conventions and a trusted checkout in the same VM; ask once for its path if unclear. Do not read values to classify files. Copy only untracked regular env files ignored in both checkouts, verified with tracking/ignore metadata. Tracked templates arrive through Git. Exclude production/staging envs, `.env.keys`, other projects, authentication stores, private keys and history. Do not blindly recurse `.env*` or change ignore rules to enable copying.

Treat eligible files as opaque bytes: never print, parse, summarize, interpolate or source them. Use exclusive/non-clobber creation, mode 0600 and independent copies; reject symlinks, hard links and path traversal outside approved roots. Preserve existing destination files. Reusing a worktree does not refresh envs without a request. Normal application env loading is allowed only during separately authorized commands. Keep envs ignored and out of commits/logs/artifacts; never force-add them. Do not transfer ignored dependencies, caches, virtualenvs or browser profiles; other configuration needs an explicit convention or instruction.

Worktrees isolate files, not processes, ports, databases or containers. Use supported non-secret task overrides; do not rewrite source envs or use production services. Creation does not authorize installs, checks or service startup. For authorized long-lived development services, use `workstation-service start/status/logs/stop` with a unique task UUID, explicit directory and RAM/CPU/runtime limits; the service command requires an existing systemd user manager and never elevates/enables lingering. Use the project foreground command and verify readiness separately. Stop the exact task unit on success/failure/cancellation. Do not detach client-owned MCP processes into these services. Use `workstation-doctor` only for requested diagnostics; missing providers are UNKNOWN, not healthy. Record owned services/resources, their directory, port/PID or unit, logs and stop command; never stop unidentified processes. Report branch, checkout, changed paths and remaining resources at completion. Cleanup needs authorization and accounting for tracked, untracked and ignored data; never force-remove, broadly clean or delete source checkout/env files.

## Browser lifecycle

Use Chrome DevTools MCP for authorized browser work inside the VM. Workstation's browser guide at https://github.com/alikayar/workstation/blob/main/docs/browser.md owns the managed configuration and capabilities; consuming repositories own application-specific test instructions. Do not connect to host/personal browsers or install another browser driver or extension automatically.

Create a unique task context with `new_page` and `isolatedContext` set to a task UUID; record the returned page IDs and supply `pageId` explicitly on each page-scoped call. Use screenshots for visual verification and explicit observable assertions for user flows. Accessibility snapshots alone do not establish appearance or a passing E2E regression suite; use the consuming project's existing test runner for persistent tests.

On success, failure or cancellation, stop any owned performance trace or screencast and close every page created by this task using `close_page`. Never close another task's pages, kill shared Chrome processes or assume closing a tab shuts down the MCP browser. The client owns the isolated MCP process/browser lifetime; there is no managed five-minute idle timeout. Report incomplete cleanup and retained artifacts. Browser contexts isolate cookies/storage, not VM filesystem or network access.

## Repository discovery and output

Use repository docs and current source/contracts. Prefer direct search for small known changes. When useful, `workstation-graphify info`, `index`, `query "symbol"` and `update` provide a derived local index; update on source changes/staleness, not every turn. Writers wait at most five seconds by default (`--lock-timeout` before the command); queries use the last published immutable snapshot and still reject stale sources. Do not delete active cache generations. `index --docs docs` adds semantic extraction via existing `codex exec` access and remembers that scope for updates. It needs no new API key, provider env or project dependency. Cache stays outside Git; Codex retains its normal model data boundary. Verify graph candidates against current APIs and adopted architecture.

For requested page audits, use Chrome DevTools MCP: `lighthouse_audit` for supported audit categories and performance traces for diagnostics. A trace is not a Lighthouse performance score. Workstation does not provision separate audit/crawler CLIs.

Keep Markdown paragraphs on one line. Update canonical project docs instead of duplicating manuals. Preserve the project's license and required asset notices, preferably with the asset. Avoid blanket third-party notice pages, duplicate license READMEs, theme/provenance reports or license-doc edits for routine visual/copy changes unless an actual license/catalog requires them.
