# Code discovery comparison

This is an explicit Linux experiment, separate from `tests/` and CI. It compares deterministic `rg`, `graphify+rg` and `serena+rg` workflows on independent copies of a selected Python corpus. No agent solves the tasks and no model is called. It does not establish which tool makes an agent implement features better, nor predict large-repository behavior.

The [recorded comparison and workstation decision](../../docs/code-discovery.md) links to the retained large-profile results. Serena is no longer a workstation default; its adapter remains here for an explicitly requested comparison using separately available prerequisites.

## Workload and scoring

`cases.json` owns the independently specified expected file sets. The fixture has two unrelated functions with the same name, a billing import alias, a three-step caller chain, misleading comments/strings and an absent symbol. Declared source additions introduce new aliased callers. Fixture functions are analyzed, never executed.

Every query starts with the same literal `rg --json` seed search. The plain `rg` arm returns those textual file candidates (with the supplied target-file filter). The other arms use their backend to resolve definitions/references. Only query inputs are passed to adapters; expected answers remain in the scorer. Files are the scoring unit: multiple references in one file count once, and reference queries exclude the target definition file. This does not measure exact reference locations, dynamic dispatch or safe rename behavior.

Graphify builds the real managed AST/Markdown-structure index with `index --structure-only`. A separate Python worker loads its native node-link export for each query, selects callable symbol nodes by their `name()` label and source file, and traverses incoming call edges for caller questions. It does not reconstruct an index from source. Python startup and graph loading are included in query time. This is an **export-based Graphify workflow**, not a benchmark of its natural-language `query` ranking, terminal output or stale-index check. Adapter/schema errors are retained instead of silently switching to text search.

Serena runs a private stdio MCP server using its `tools` interface and the real `find_symbol` / `find_referencing_symbols` operations. Direct reference queries include import/module references. The ancestor workflow restricts each traversal step to callable referrers (LSP Method/Function kinds), avoiding module pseudo-symbols that cannot be queried as definitions. Callable references can still be non-call usages; the deliberately small fixture makes that distinction inspectable. The plain `rg` transitive operation is reported as unsupported, rather than pretending lexical matches establish a caller chain. Unsupported outcomes reduce coverage; they are never scored as correct empty answers.

Each scored response retains actual/expected files, missing/extra candidates, precision, recall and exact-set equality. An empty expected set requires an empty result for an exact match. There is no combined winner score or arbitrary speed threshold.

## Generated profiles

`generate.py` writes a deterministic corpus into the selected run's artifact directory. Generated source files are never added to this repository. `profiles.json` contains only dimensions; `--seed` controls extra local edges and import styles. The eight-file calibration fixture and its five cases remain included in every profile.

| Profile | Domain pairs | Modules per domain/half | Service modules, both halves | Service fanout |
| --- | ---: | ---: | ---: | ---: |
| `smoke` (default) | — | — | Original calibration fixture only | — |
| `small` | 3 | 16 | 96 | Up to 2 local + one bridge |
| `medium` | 4 | 64 | 512 | Up to 3 local + one bridge |
| `large` | 8 | 128 | 2,048 | Up to 4 local + one bridge |

Each generated domain is a connected DAG: every non-leaf service calls the preceding service, with seeded additional dependencies among the preceding eight modules. Every eighth module imports a matching service from the preceding domain. A shared typed dataclass model and one application entrypoint connect the services to an application shape. Repeated `Validator` classes/methods and `render_result` helpers create realistic scoped-name collisions. Text-only distractors mention actual query targets.

One half uses only direct imports, including its application-entrypoint bindings; the other has the exact same service relation model with seeded direct, aliased and namespace imports. This gives paired cases for comparing import-resolution behavior at the same corpus size. Both halves live in one workspace; they do not isolate the resident-memory cost of each import style. Source generation does not execute these deep/branching call chains.

Eighteen additional cases sample early, middle and late domains in both halves: unique-definition lookup, direct referrers and three-/six-level incoming reachability. Together with calibration there are 23 cases. Added-source queries include a second caller addition affecting a sampled mixed-import target. Expected file sets are computed from the generator's explicitly declared service-call model before tool execution, never from Graphify/Serena output or parsing their emitted source. No expected-answer manifest is placed inside the analyzed corpus.

`workload.json` records the realized cases, seed, dimensions, source file/line/byte counts, import-style and declared-edge counts. The main result records source hashes as well. Generation and fixture copying are outside timed backend phases; generation duration is reported separately. Package markers, the shared entrypoint and calibration/distractor files are additional to the service-module counts above. The existing 64-reference-call and per-query time bounds still apply; reaching a budget must be reported, not treated as an exact empty result.

To select a larger corpus during an authorized run, add these options to the command below:

```sh
--profile medium --seed 42
```

Compare profiles with the same seed, tool versions, query settings and VM resources. Because both corpus size and fanout vary between these named profiles, they measure the named workload rather than isolating file count alone. Keep the dimension manifest when interpreting results. These generated DAGs do not establish performance on real monorepos, external dependencies, cycles, dynamic dispatch or languages other than Python.

## Prerequisites and execution

Use Python 3.11+, Git and ripgrep. The Graphify arm needs the installed `workstation-graphify` launcher. The Serena arm needs an absolute path to an already installed Serena executable and an explicit absolute path to an installed `pyright-langserver`. No package-resolver/installer command is run. `UV_OFFLINE=1` prevents uv package downloads, and the explicit language-server path bypasses Serena's managed Python server installation. Offline uv resolution alone is insufficient because it can attempt builds; use the existing executable instead. This is not a network sandbox; third-party subprocess behavior remains part of the installed tools' trust boundary.

For an explicitly authorized run:

```sh
python3 benchmarks/code-discovery/run.py \
  --output /tmp/workstation-discovery-001 \
  --serena /absolute/path/to/serena \
  --python-language-server /absolute/path/to/pyright-langserver
```

The runner starts that executable with `start-mcp-server`, the fixture project, Codex context, tools interface and disabled dashboard arguments. Its private global Serena configuration owns the explicit language-server executable choice; project-supplied settings remain untrusted. Existing user configuration and trust patterns are not changed. After the first query pass starts the language server, the runner records the runtime Pyright version from its startup announcement in `mcp.stderr`; a missing or conflicting version makes the trial incomplete. Do not put credentials in that argv: commands and protocol traffic are retained. Missing prerequisites appear as unavailable and make the run exit nonzero; they are not installed or reported as passes. `--arms rg graphify+rg` explicitly selects a partial comparison without Serena.

The output must be a new/empty directory outside the Workstation checkout, without symlinked ancestors. Each round/arm gets its own fixture copy, Git root, HOME, Serena home and Graphify cache. Existing tool/runtime caches are reused to locate installed dependencies; existing projects, credentials and live MCP sessions are not copied or activated. The fixture repositories receive no commits and have no remotes.

## Measurement boundaries

The default is two rounds with reversed arm order in the second, one first query pass, two warm passes, a two-second idle observation, declared source additions, backend refresh and another query pass. Each phase/query has a configurable deadline (120 seconds by default). Serena refresh explicitly opens each added symbol before measuring changed-source queries; Graphify refresh explicitly updates the index and captures its returned graph pathname, so changed-source queries use the newly published generation. Backend preparation combines startup and index/project readiness because these backends cannot expose equivalent independent boundaries. Lazy work can still appear in the first query.

A new process and private tool cache do **not** mean cold filesystem or dependency caches. The runner does not drop OS caches, control unrelated VM workloads or launch concurrent agents. Generated profiles expose controlled scaling effects; a separately approved representative real-repository workload and concurrent-session experiment are still needed before generalizing the recorded default choice to other workloads. Do not infer monorepo or non-Python results from this fixture.

Resources are sampled every 100 ms across the owned process tree, including Serena's observed language-server descendants. CPU is the sum of sampled per-process user/system CPU counters; short-lived children may be missed. RSS sums can double-count shared pages, miss short peaks and exclude Python runner/normalization overhead. Values with no observed processes are null, not proof of zero usage. Timing includes normalization and literal seed searches. Raw sampling and elapsed time must be interpreted together; this is not cgroup/PSS accounting or a statistically powered benchmark.

## Evidence and cleanup

`result.json` retains fixture hashes, options, runtime/tool metadata, phases, every query outcome and completion state. `summary.json` aggregates comparable arm/phase/case observations with status counts and successful-observation timing ranges/medians. Keep first attempts and errors. Per-trial artifacts include command argv/stdout/stderr, MCP exchanges, the private fixture/index and `resources.jsonl`. No token-usage estimate is fabricated.

The runner stops only its own server/process groups and sampled descendants, recording any remaining owned PIDs. Artifact directories are retained after success, error or interruption. Do not remove evidence automatically. Exit zero means the selected workflows completed without infrastructure failures; it does not mean every answer was exact or that unsupported operations passed. Read coverage and correctness separately.

Normal source/regression commands do not invoke this experiment. Running the comparison requires authorization for that scope.
