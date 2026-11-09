# Verify a Workstation change

Run checks from the repository root only when their scope is authorized. Source checks, isolated task regressions, full provisioning and browser execution have different effects; select the level needed for the change. Neither a green source check nor a browser screenshot establishes a clean installation on every supported platform.

| Level | Command or trigger | Effects and evidence |
| --- | --- | --- |
| Source checks | Commands below; automatic `checks` CI job on relevant PRs and pushes to `main` | Ansible syntax/lint and Python test-script syntax. No provisioning or browser startup. |
| Isolated regressions | `python3 tests/regressions.py` | Executes actual Ansible tasks in private disposable homes; verifies CLI ownership, rendered browser guards and Codex configuration. Does not replace the user's settings. |
| Installed-tool regressions | Add `--installed-tools` on a prepared VM | Also exercises SiteOne extraction/custom paths and Lighthouse failure/recovery using native tools. May download pinned vendor packages; no application services or browser execution. |
| Full Ubuntu install | Manually dispatch `CI` on the selected revision | Existing Ubuntu 24.04/26.04 x86_64 jobs provision disposable hosted runners, require `changed=0` on a second apply and run installed-tool regressions. |
| Browser smoke | `python3 tests/browser_smoke.py`, or select the manual CI `browser` input | Starts one temporary loopback fixture, exercises agent-browser, Lighthouse and SiteOne sequentially, saves screenshots/native reports and closes owned resources. No external target site. |

## Local source checks

Install the normal check prerequisites if they are not already present: Ansible, ansible-lint and the Debian support library. The prepared Workstation also supplies actionlint.

```sh
ansible-playbook ansible/site.yml --syntax-check
ansible-lint ansible/site.yml
actionlint
python3 - <<'PY'
from pathlib import Path
for path in Path('tests').glob('*.py'):
    compile(path.read_bytes(), str(path), 'exec')
PY
```

Actionlint's pinned release uses `.github/actionlint.yaml` to recognize the `ubuntu-26.04` runner label. The automatic source-check job does not install actionlint; run it locally for workflow edits. This avoids bootstrapping the full runtime stack merely to check source changes.

## Regressions on a prepared Ubuntu VM

The tests use Python 3.11+ standard-library `unittest` and the installed Ansible CLI, with no test framework dependency. Install Workstation's CLI tools first so `/usr/bin/fdfind` and `/usr/bin/batcat` exist. `--installed-tools` additionally needs the managed mise/Node/Chrome installation and a SiteOne archive from the current checkout's provisioning. Ansible verifies the archive's pinned checksum before extraction; an absent or mismatching cache can require a vendor download.

```sh
python3 tests/regressions.py --installed-tools
```

The suite verifies successful setup and unchanged reapplication, user-file and foreign/broken-symlink collisions, both browser wait-state spellings and forbidden session/state overrides. Installed-tool tests seed an incomplete executable or inject an install-command failure, then verify the actual tasks recover and only mark successful completion. Dependency failure injection is separate from the subsequent real npm repair; it does not claim to reproduce a network outage.

Without `--installed-tools`, those two installation tests are explicitly reported as skipped. Test logs and a machine-readable `result.json` remain in the printed private `/tmp/ws-regressions-*` directory after success or failure. `--output PATH` selects a new or empty artifact directory. Preserve failures before retrying; do not reuse a nonempty output directory or delete evidence to obtain a clean result.

## Explicit browser smoke

Use a prepared x86_64 VM with agent-browser, managed Chrome, Lighthouse, SiteOne and `workstation-browser-task` on PATH. This is an execution check, not a performance benchmark or an application's E2E suite.

```sh
python3 tests/browser_smoke.py
```

The temporary page has a Publish interaction and a deliberately broken internal link. The check verifies the visible interaction, Lighthouse's normal-page audits and SiteOne's broken-link observation. Browser sessions are task-scoped; owned processes and the fixture server are cleaned up. Logs, the published screenshot, native reports and `result.json` remain at the printed path. Inspect the screenshot when assessing appearance; automation alone does not establish visual correctness. A failed run must not be described as a pass, even if a later retry succeeds.

## CI and release evidence

Relevant PRs and pushes to `main` run only the source-check job. The existing full-install jobs remain manual; select **Actions → CI → Run workflow**, choose the exact branch/ref and enable browser smoke only when wanted. The existing Windows parser job retains its manual behavior; no live Windows validation is added here.

Before presenting a revision as installation-verified, dispatch CI for that revision and inspect both Ubuntu jobs, second-apply logs and regression results. Browser smoke is optional and must be reported separately. The workflow retains available Ubuntu evidence for seven days, including on failure, without uploading tool installations, user settings or credential stores. Source checks on a new commit do not reuse an older commit's full-install result as proof. The README badge describes workflow status; use the individual job and revision to establish its coverage.

Local execution does not prove that a newly edited hosted workflow has run. Full CI requires a pushed revision and a separate authorized dispatch. Windows/Hyper-V, ARM64 and a complete WSL installation remain outside these checks.
