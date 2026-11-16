# Verify a Workstation change

Use separate evidence for source checks, isolated configuration regressions, a clean installation and the real browser workflow. This repository uses Python 3.11+ standard-library tests, Ansible and a dependency-free Windows PowerShell contract runner; the browser suite speaks stdio MCP to the actual managed server. It adds no Playwright/Selenium test dependency or alternate browser driver. Run only the scope explicitly authorized for the task.

## Test levels

| Level | Entry point | Boundary and acceptance |
| --- | --- | --- |
| Source checks | Ansible syntax/lint, actionlint and Python compilation below | Configuration/workflow validity; no browser or provisioning. Automatic PR/push job checks Ansible and Python syntax. |
| Isolated regressions | `python3 tests/regressions.py` | Real Ansible rendering in private homes; language/component selection, rejected input, browser opt-out, ARM64 guard, exact MCP defaults, custom-source ownership and second-render idempotency. No browser or full provisioning; also runs in the automatic PR/push job. |
| Installed-tool regressions | `python3 tests/regressions.py --installed-tools` | Also exercises real Codex plugin registration and idempotency against a disposable Codex home. May fetch pinned plugins; requires separate dependency/network authorization. |
| Windows contracts | `tests/windows/Run-Tests.ps1` on Windows | Real production functions, temporary files, synthetic JSON-RPC peer and mocked Hyper-V inventories. Manual Actions matrix runs Windows PowerShell 5.1 and PowerShell 7; no installed Codex, administrator rights or live VM required. |
| Fresh installation | Manual CI on Ubuntu 24.04/26.04 | Full provisioning, a second apply requiring `changed=0`, and installed-tool regressions on disposable hosted runners. Includes package/network/system changes. |
| Browser smoke | `python3 tests/browser_smoke.py` | Real Chrome and pinned MCP; local fixture, tool contract, form interaction, state after reload, context isolation, screenshots, trace, console/network observations, native audits and graceful cleanup. |
| Browser battle | Same script with `--battle` | Adds deliberately broken audit content, rejected tool calls, bounded DOM timeout, HTTP 500 with no state writes, SIGTERM with an active trace/page, and a fresh-process recovery scenario. Includes smoke; no automatic retry. |

The [browser guide](browser.md) owns operational behavior; this page owns its verification. The local evidence below verifies the bounded test workload. Fresh-install and hosted CI results remain separate.

## Reading path and evidence status

| Boundary | Current evidence | Remaining work |
| --- | --- | --- |
| Linux configuration and helpers | Expanded local installed-tool run: 21 tests, no failures/errors/skips | Hosted checks for the final pushed revision; live security-role application remains separate |
| Chrome/MCP integration | Local standalone smoke and battle normal/SIGTERM/restart phases passed | Hosted fresh-install/browser run; screenshot review for each new visual claim |
| Windows host/VM contracts | 41 cases authored; runner and workflow source-reviewed | First actual Windows PowerShell 5.1/7 execution |
| Fresh Ubuntu install/idempotency | Manual Ubuntu matrix configured | Current revision's hosted full install and second-apply result |
| Hyper-V images/clones/recovery | Source review and authored isolated contracts; older bounded network evidence is documented separately | Fresh live image/clone/recovery validation for both guests |

This table records the prepared work and observed local runs, not the status badge of an unexecuted workflow. The [Windows network evidence](windows.md#network-validation-evidence) predates the current image/clone changes and does not validate those changes. Retain each run's result/artifacts with its tested source revision.

## Local evidence: 2026-11-16

The final installed-tool/configuration regression run passed 21 cases with zero failures/errors/skips. It includes the reduced MCP/component catalog, security/base tag selection, settings/archive/appearance protections, actual Codex plugin idempotency, rendered Graphify indexing and real user-service lifecycle. Ansible syntax, production-profile lint (27 files, no failures/warnings), actionlint, compilation of 19 Python sources, Renovate JSON parsing and diff whitespace checks passed. Local file/heading review checked 194 links across 21 Markdown files. A separate real doctor invocation returned OK for all 13 requested observations. These runs did not apply full provisioning or establish live SSH/UFW behavior.

An earlier standalone browser smoke run and browser battle passed their normal, SIGTERM and fresh-process restart phases. They verified the declared interaction/isolation/audit/error cases, native trace/report artifacts and graceful EOF cleanup. No observed process required forced reaping and no owned PIDs remained after any phase. Desktop and mobile screenshots from the normal phase were visually inspected without clipping or overlap. This browser evidence predates the later component removals, default security enablement and Ubuntu operations changes; it is not clean-install evidence for those changes.

Browser-run versions were Python 3.15.2, Node 26.13.0, Chrome for Testing 157.0.8103.38, Chrome DevTools MCP 1.12.0 and bundled Lighthouse 13.5.0. Initial failed attempts were retained separately: template-variable precedence, missing offline npm cache and a shared negative-fixture state key. The renderer, early-exit cleanup and fixture isolation were corrected before the passing run; package-cache preparation remained explicit.

The local suites did not replace active Codex configuration or apply the full workstation playbook. They do not simulate SIGKILL or power loss. Raw results and protocol/screenshot/trace/audit evidence remain in private run directories. Keep failed attempts separate when repeating. Hosted Windows and clean-install outcomes must be recorded independently against their tested commit.

## Ubuntu operations coverage

`tests/workstation_contracts.py` supplies regression cases to the existing `tests/regressions.py` runner; it is not a second test entry point. Source contracts inspect Ansible's task order and prerequisite declarations without installing APT packages. Actual role tasks install the two command files in private fixture homes, verify unchanged reapplication and reject foreign commands. Doctor cases cover unavailable providers, missing runtime/browser inputs and disabling mise auto-install. Service boundary cases reject foreign units and malformed limits and preserve literal command arguments without shell expansion.

Graphify cases render the actual adapter through Ansible. Private-cache cases inject a failed pointer publication, verify that the prior immutable snapshot remains available, bound writer lock contention and reject generation traversal. `--installed-tools` additionally uses the already installed Graphify environment against a disposable Git fixture: index/query, info/query while another writer holds the lock, immediate writer timeout, stale-source rejection, update and query of the new generation. No semantic model call or code-discovery performance benchmark is run. A separate contract ensures the benchmark adapter captures the new graph pathname on refresh.

On a machine with a working systemd user manager, `--installed-tools` also starts a synthetic foreground service with a child process. It verifies the real unit's memory/CPU/runtime properties, duplicate-ID rejection, status/log access and exact stop/control-group cleanup. Only the generated UUID unit is touched. Missing user-manager access is recorded as an explicit skip rather than replaced by a privileged/system-wide launch; the local prepared VM run had no skips. These checks establish the bounded service scenario, not live application readiness, OOM/load capacity or filesystem/network confinement.

The [local evidence](#local-evidence-2026-11-16) records the passing prepared-VM run. Source contract coverage does not replace the hosted fresh-install matrix or live SSH/UFW verification; doctor observations do not establish browser sandbox enforcement or application readiness.

## Source checks

These commands require the installed Ansible/lint toolchain, Debian support library and actionlint. Installing prerequisites is a separate environment change.

```sh
ansible-playbook ansible/site.yml --syntax-check
ansible-lint ansible/site.yml
actionlint
python3 - <<'PY'
from pathlib import Path
for root in ['tests', 'ansible/roles/cli_tools/files', 'ansible/roles/vscode/files', 'host/windows/hyperv/ubuntu-26-04', 'benchmarks/code-discovery']:
    for path in Path(root).rglob('*.py'):
        compile(path.read_bytes(), str(path), 'exec')
PY
```

The hosted source job does not install actionlint; run it locally when workflow checks are authorized. Its pinned version recognizes the Ubuntu 26.04 runner label through `.github/actionlint.yaml`. Source checks alone establish neither installation nor browser compatibility.

## Isolated regressions

The default regression suite invokes actual role tasks with disposable homes and explicit tags. It does not apply the full workstation playbook. Browser-disabled and unsupported-architecture cases must finish before installing system packages or creating a browser directory. Configuration cases verify the managed executable path, headless/isolated/page-routing flags, privacy flags, enabled/disabled settings, server set and unchanged reapplication. A custom template remains authoritative without an appended marketplace table.

`--installed-tools` additionally uses the existing Codex executable to configure the pinned plugin in a private home. Missing tools cause failures; opt-in installed-tool cases are explicitly skipped in the default run. Logs and `result.json` remain under the printed private artifact path. `--output PATH` selects a new or empty directory. A skipped case is not a pass, and earlier plugin checks do not establish current browser behavior.

## Windows contracts

`tests/windows/Run-Tests.ps1` owns execution and assertions; `Host.Contracts.ps1` owns host configuration, selection, dispatcher and diagnostic contracts; `VM.Contracts.ps1` owns image, ownership, network-rule and lifecycle contracts. Synthetic inputs stay under `tests/fixtures/`; the existing Linux entry points and shared MCP helper remain directly under `tests/`. Fixtures contain generated example identities and content, not copied machine configuration. Code-discovery benchmarks remain outside the regression suite under `benchmarks/`.

The Windows suite registers 41 cases covering selection/consent, resource bounds, JSONC conflict handling, passive appearance installation, linked paths, permission profiles, versioned config writes and redacted API failures, managed instructions, answer XML escaping, Terminal preservation/idempotency, dispatcher argument rejection and diagnostic UNKNOWN/WARN behavior. VM cases cover disk chains, shared-resource deletion refusal, ownership identity, recorded resources, IPv4/ACL recipes, image ACLs/hashes, frozen recovery payloads, WhatIf and power-operation identity rechecks.

The runner extracts exact top-level function definitions from production scripts through the PowerShell AST. It does not execute installer entry points or their bootstrap/import statements. Fixture-owned library directories supply safe `$PSScriptRoot` inputs. External Hyper-V/network operations are substituted at command boundaries; files and junctions belong to a new run directory. These substitutions are test isolation conventions, not an operating-system sandbox. Dispatcher cases execute only help and arguments that must be rejected before worker dispatch.

A small C# JSON-RPC peer is compiled with the existing Windows .NET Framework compiler. It exercises the real host config subprocess/client and backup logic with synthetic responses, stale-version errors and an unexpected authentication request. It never launches Codex, inspects login state, calls a model or changes user configuration. No Pester package or downloaded test dependency is needed.

Run on a Windows x64 machine in each shell, with a distinct new artifact directory:

```powershell
& .\tests\windows\Run-Tests.ps1 -Output (Join-Path $env:TEMP 'ws-windows-contracts-001')
```

On **Actions → CI → Run workflow**, choose `scope=windows` to run only the Windows matrix, without Ubuntu provisioning or browser jobs. The default `scope=all` keeps the full manual workflow.

The manual `windows-powershell` Actions job performs source parsing and runs this suite independently with `powershell` and `pwsh`. Failures are not skipped or retried. `result.json` records shell/OS/compiler versions, production/test source hashes, case outcomes and durations; per-case logs are retained. Only result/log files are uploaded, excluding compiled peers and generated configuration. PowerShell is unavailable in the current Ubuntu VM: these Windows cases have been authored and source-reviewed, **not executed**. The first hosted run must establish their Windows runtime compatibility.

This suite does not build an image, boot a guest, mount a real VHD, install host applications, change a network policy or prove live Hyper-V isolation. Fresh image/clone/recovery coverage remains the separate work listed in the [Windows guide](windows.md#recovery-compatibility-and-validation).

## Browser setup and execution

Use a prepared Linux x86_64 workstation with the current checkout's managed Chrome, Ansible, Node/npm and Python. The browser suite renders the real Codex template into its artifact directory and reads only that generated configuration. It does not read a user's Codex configuration, copy login state, run Codex model calls or use the current chat's MCP connection. It checks the actual Chrome version and the MCP's runtime version against the managed pins.

Package preparation is a separate explicit action. If the pinned MCP package is already available in the normal npm cache, skip preparation. Otherwise, when dependency installation/network use is authorized, run:

```sh
python3 tests/browser_smoke.py --prepare-dependencies --output /tmp/ws-browser-dependencies-001
```

This asks the configured `npx` command to resolve the pinned package and report its version; it does not navigate a page or run browser scenarios. It may download npm packages. Actual smoke/battle runs use a private HOME, a private npm user-config path and `npm_config_offline=true`, reusing the established package/runtime caches. Missing cache entries fail instead of silently installing or skipping. Offline package resolution is not a network sandbox for third-party processes.

For separately authorized browser execution, use one of:

```sh
python3 tests/browser_smoke.py --output /tmp/ws-browser-smoke-001
python3 tests/browser_smoke.py --battle --output /tmp/ws-browser-battle-001
```

Each command needs a new or empty artifact directory outside the checkout, without linked ancestors. Outputs are private and retained after failure. Each MCP process has a new HOME and the managed isolated-browser configuration. A loopback-only allowed URL pattern further restricts fixture navigation; it is a test restriction and is not claimed as a general host sandbox. There are no personal accounts, remote target sites or external application services in this workload.

The fixture at `tests/fixtures/browser/index.html` is a small form served by the runner's loopback HTTP server. Publish goes through a real POST endpoint and records fixture state; the test checks exactly one write and the visible state after a reload. It also creates two coexisting task contexts, interleaves page-specific operations, checks cookie/localStorage separation and same-context sharing, and verifies that closing a task-owned page leaves the other context usable. This is a browser-integration fixture with an in-memory server, not an application's database E2E test or a concurrent load experiment.

Desktop and mobile screenshots must be valid PNGs with the requested dimensions, and the fixture must have no horizontal overflow. Inspect both screenshots separately before claiming visual correctness; dimensions and DOM geometry do not establish a correct design. The suite records that visual review remains pending.

Audit assertions use known fixture properties rather than a blanket score of 100: valid title/description/labelled image in the normal page, and a deliberately missing image alt in battle mode. Both require native JSON/HTML reports and no Lighthouse runtime error. Performance traces require native trace events; they are not Lighthouse performance scores or performance-budget results. Console/network checks observe an explicitly generated error and 404 response.

## Failure and cleanup acceptance

A valid battle run must reject an invalid element UID and a missing page ID, report a bounded wait timeout, remain usable afterward, detect the deliberately missing image alt, and show a failed publish without server-state writes. Expected failures are recorded as such in the protocol/check report; an unrelated startup failure cannot satisfy them. SIGTERM targets only this run's process group, with an open page and active trace, followed by a full scenario in a fresh process. It does not simulate SIGKILL, power loss or an operating-system crash.

Normal completion and caught failures attempt to stop the owned trace and close every recorded task page. The test then closes MCP stdin and observes server/browser exit. It records page cleanup and process cleanup separately. Process ownership uses sampled PID/start-time descendant identity, never process-name matching, environment inspection or a broad kill. If the harness must force-reap descendants, the run fails even if the environment is ultimately cleaned. Remaining PIDs and cleanup errors stay in the report. A 50 ms process sampler can miss short-lived or reparented children; it is not cgroup-level process accounting.

Tool calls have finite deadlines and the entire Linux run has a fifteen-minute deadline. The fixture server is stopped in final cleanup. No whole-scenario retry hides a failure. Preserve each failed artifact directory before a new attempt. A zero exit requires successful assertions and observed cleanup; it still does not replace screenshot review or establish security isolation.

## CI and evidence

PRs and pushes run source checks and the default isolated configuration regressions. Windows parsing/contracts and full Ubuntu install jobs remain manual. On **Actions → CI → Run workflow**, choose the exact ref and select `browser` for smoke or `browser_battle` for the expanded run; battle includes smoke. Package preparation is an explicit CI step before the selected browser run. The Ubuntu matrix remains 24.04 and 26.04 with fail-fast disabled so a failure on one does not erase the other's evidence.

Artifact retention is seven days. CI uploads selected regression logs, browser results, protocol/startup logs, screenshots, trace and native audit reports, including on failure. It does not upload private HOME directories, browser profiles, runtime caches or generated user configuration. The main result records workload source hashes, launch configuration, Python/Node/Chrome versions, per-attempt checks and cleanup; server initialization and native audit reports record MCP/Lighthouse versions. No model/token-usage estimates are produced.

Full installation and second-apply idempotency are tested by the hosted workflow, not by applying provisioning on the user's current VM. Results belong to the exact tested revision. A workflow edit that has only been source-reviewed has not been exercised by GitHub Actions. Do not bypass failed assertions, mark unavailable tools as passes or cite an older run as verification of new code.

These suites do not establish live Windows/Hyper-V lifecycle behavior, a complete WSL installation, ARM64 browser support, native-VM sandbox enforcement, extension compatibility, screencast codecs, third-party framework debugging, long-duration resource behavior or production capacity. Any such claim needs a separately scoped experiment. Persistent application E2E tests remain owned by the consuming project.
