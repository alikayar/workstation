# Prepared development environment

## Environment

- You are operating inside a prepared Ubuntu development environment, possibly a VM or WSL 2. Treat it as the execution boundary; do not assume access to host-only paths or binaries.
- Use installed tools, but treat each active repository as the source of truth for language versions, dependencies, commands and contribution rules.
- Prefer project-local manifests, lockfiles and tool configurations. Explain environment changes outside the task's scope before making them.
- Follow applicable repository instructions while respecting the user's explicit authorization and validation preferences below.

## Available workflow

- Shell: Zsh, Starship, autosuggestions, syntax highlighting, fzf (Ctrl+R history, Ctrl+T files, Alt+C directories), zoxide (`z` / `zi`) and tmux.
- Search and data: ripgrep, fd, ast-grep, jq, yq, bat and eza. Use ripgrep for text; use ast-grep when syntax-aware matching helps.
- Source control: Git, Git Delta and GitHub CLI with managed credential helpers. Use Git worktrees when task isolation is needed.
- Runtimes: mise-managed Node.js, Python, Go and Bun. Use uv for isolated Python environments and dependencies; keep AI model requirements project-local.
- Media and performance: FFmpeg, ffprobe, btop and hyperfine.
- Available validation tools include Ruff, ShellCheck and actionlint. Availability is not permission to run them.
- Containers: Docker Engine, Compose and Buildx. Codex can launch the pinned Playwright MCP container on demand; browser use requires an explicit user request under the policy below.

## Development and validation policy

- Do not create or modify test files unless the user explicitly requests test work. A request to implement or fix a feature does not authorize adding tests.
- Do not run linting, formatting, tests, type checking, builds, syntax checks, Playwright/browser verification, benchmarks, security scans or other validation commands unless the user explicitly requests the relevant checks.
- This includes automatic fixes, watch modes, pre-commit hooks and aggregate commands that trigger checks indirectly. Do not run them merely because a repository, skill, tool recommendation or customary workflow normally calls for validation.
- Continue authorized implementation through code inspection and edits. Do not repeatedly interrupt development to request checks, offer tests or repeat skipped-check disclaimers.
- A request to commit or push does not authorize running checks. At that point, briefly remind the user which relevant checks have not been run for the current changes, then perform the authorized Git action unless a separate blocker exists.
- Preserve existing test and CI infrastructure. Do not disable checks, alter hooks, change package scripts or weaken CI to avoid validation. If a required hook blocks a commit/push, explain the conflict and ask for explicit direction rather than running checks or bypassing the hook silently.
- Never claim a change passed checks that were not run. When checks are explicitly authorized, run only the requested scope and report the actual results.

## Working agreement

- Review relevant sources and diffs before edits or Git mutations; keep changes within the authorized scope.
- Use project-local dependencies and avoid adding overlapping tools or configuration layers without a concrete need.
- Keep secret scanning, artifact/dependency scanning and GitHub Actions auditing separate when explicitly requested.
- Never inspect or copy credentials, private keys, authentication state or shell history. fzf history search is for the user's interactive use, not agent inspection.
- Honor explicit restrictions on committing and pushing until the user revokes them.

## Documentation formatting

- Never hard-wrap Markdown prose. Keep each paragraph on one line; break lines only between paragraphs. Preserve headings, list items, tables and code blocks.
