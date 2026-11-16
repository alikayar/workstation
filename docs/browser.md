# Chrome browser workflow

Workstation provides Chrome for Testing and Chrome DevTools MCP as its single agent browser workflow. Use the MCP for navigation, interaction, screenshots, DOM/CSS inspection, console/network debugging and supported page audits. Consuming projects own their persistent E2E tests and assertions; a successful agent interaction is not a test-suite pass.

## Installation and configuration

The `agent_tools` role installs Chrome for Testing 157.0.8103.38 on x86_64, with its version/SHA256 in the role defaults and download URL in the Chrome task. Runtime libraries and the versioned Chrome directory under `/opt/workstation` are root-owned. The verified archive cache is retained. An extraction-completion marker is written only after success; an interrupted extraction is retried. No repositories are indexed, checks executed or browsers started by provisioning.

From the Workstation checkout inside Ubuntu, apply only when provisioning is authorized:

```sh
ansible-playbook ansible/site.yml --tags chrome,codex --ask-become-pass
```

The `chrome` tag installs Chrome, its libraries and AppArmor policy. The `codex` tag applies the managed Codex configuration, instructions, rules and plugins; it replaces the managed config file. It requires the prepared mise/Node/Python environment. A standalone `codex` tag does not install Chrome. See [Ubuntu setup](getting-started.md) for runtime and configuration prerequisites.

The Codex template pins `chrome-devtools-mcp@1.12.0`, runs it through `npx`, points it at the managed Chrome executable and uses `--headless --isolated`. Native flags disable MCP usage statistics and CrUX URL lookups. Restart Codex after applying configuration. Configured MCP availability is distinct from tools exposed in a current chat; listing a server does not verify that it starts successfully.

`agent_tools_browser_enabled` defaults to true on x86_64 and false on ARM64, which has no managed Chrome for Testing asset. It controls both Chrome provisioning and the MCP's enabled value. Explicitly enabling Chrome on an unsupported architecture fails with an explanation. The Windows component selector sets this value from the `browser` choice; DevTools is configured when Codex is also selected. Omitting a component skips its provisioning and does not uninstall existing software.

To disable the MCP for a new CLI session:

```sh
codex -c 'mcp_servers.chrome_devtools.enabled=false'
```

Workstation does not provision another browser-control CLI, a separate Lighthouse CLI, a site crawler, browser extensions or a personal browser profile. Existing installations are not automatically deleted.

## Task isolation and cleanup

Browser execution requires task authorization. Use only the VM-local managed MCP; do not attach to a host/personal browser or reuse another task's pages. The server uses a temporary browser profile; this is separate from the task contexts inside that browser.

1. Choose a unique task UUID and call `new_page` with `isolatedContext` set to it. Record the returned page IDs. Reuse that context name only for this task's additional pages; contexts separate cookies and storage.
2. Pass the intended `pageId` explicitly on page-scoped calls. Do not depend on whichever tab is currently selected. Record additional pages opened by the task, including popups.
3. Check navigation results and explicit observable outcomes. For visual work, capture and inspect screenshots at the required viewport sizes. Accessibility/DOM snapshots establish structure, not visual correctness. Retain relevant artifacts under the consuming project's private/ignored artifact policy.
4. On success, failure or cancellation, stop any performance trace or screencast started by this task and close all pages it created using `close_page`. Do not close pre-existing or other tasks' pages, kill shared processes or stop another task's recordings. Coordinate concurrent tracing/recording work rather than assuming contexts isolate every diagnostic facility.
5. Report incomplete cleanup with the owned page IDs and recording state. The client owns the stdio MCP process and its browser lifetime. Closing task pages does not establish browser-process shutdown or immediate context-memory reclamation. There is no managed five-minute idle timeout or replacement cleanup daemon.

The tool does not allow closing the browser's last page. Leave the initial blank page available and create task pages separately; do not turn a cleanup error into shutting down a shared browser. These ownership rules are instructions, not an enforced per-task permission boundary.

## Audits and performance

Use `lighthouse_audit` for accessibility, SEO, best practices and agentic-browsing audits. It can audit navigation or the current page state and save full reports. Its performance category is excluded. Use `performance_start_trace`, `performance_stop_trace` and `performance_analyze_insight` to investigate loading and interaction performance; those diagnostics are not a standard Lighthouse performance score.

A site-wide crawl is outside this workflow. A project that needs a crawler or standardized performance-score regression should declare and manage that dependency locally. Do not recreate a crawler by asking the agent to follow every link, or add a browser extension to duplicate an existing native audit. A screenshot or automated audit alone does not establish accessibility compliance.

## Security boundary

On AppArmor-enabled Ubuntu, the role grants user namespaces to the exact root-owned Chrome executable using a dedicated policy. It reloads that policy after each apply, including recovery from an interrupted apply. It does not disable AppArmor globally, add a SUID executable or pass `--no-sandbox`. Namespace permission is not full filesystem/network confinement or an executed sandbox guarantee.

The MCP can inspect page content and run page JavaScript; outputs may be processed by the agent's model. Temporary profiles and browser contexts are not VM security boundaries. Keep host credentials and personal browsing data outside this workflow. Extension-management and experimental third-party-tool categories remain disabled in the managed configuration.

## Troubleshooting

| Symptom | Inspect or recover |
| --- | --- |
| Chrome MCP absent from this chat | Confirm the actual exposed tools and restart after configuration changes; a stored server entry cannot add tools to an existing chat |
| Server startup fails before navigation | Confirm the VM-local Node/npx resolution, managed Chrome path and installed runtime prerequisites; retain the startup error rather than switching browsers |
| Pinned npm package unavailable offline | Distinguish package-cache preparation from browser execution; the [test guide](verification.md#browser-setup-and-execution) makes that network step explicit |
| Chrome namespace/AppArmor error | Review the managed executable path and exact policy/task failure; reapply the reviewed Chrome scope when authorized, without `--no-sandbox` or disabling AppArmor globally |
| Page command targets the wrong task | Use the recorded task context and explicit page ID; do not recover by selecting or closing unrelated pages |
| Closing a task page fails | Keep the initial blank page, retry only owned pages and report unresolved IDs; do not terminate a shared browser |
| Native audit lacks a performance score | This workflow excludes Lighthouse's performance category; use traces for diagnosis or a project-owned score runner |
| Entire-site coverage requested | A native page audit is bounded to the page/state; declare a separately scoped project crawler rather than presenting it as a full crawl |

## References and verification

The versioned [tool reference](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/chrome-devtools-mcp-v1.12.0/docs/tool-reference.md) owns exact arguments and tool capabilities; [MCP configuration](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/chrome-devtools-mcp-v1.12.0/docs/configuration.md) owns server options. The Chrome namespace policy follows [Chromium's AppArmor guidance](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md).

Use the [verification guide](verification.md) for smoke/battle commands, prerequisites and acceptance criteria, and its [recorded results](verification.md#recorded-results-2026-11-16) for tested revisions and limits.
