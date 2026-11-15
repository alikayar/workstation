# Code discovery: decision and measurements

Workstation uses Graphify for repository relationships and `rg` / ast-grep for direct source discovery. Serena is removed from the managed Codex MCP configuration. This favors an on-demand index without a resident language-server process, accepting explicit refresh work after source changes. It does not establish that Graphify replaces every language-server capability.

For installation, query commands, cache ownership and freshness behavior, use the [repository indexing guide](agent-environment.md#repository-knowledge-indexing). The [benchmark guide](../benchmarks/code-discovery/README.md) owns the runner, prerequisites and scoring contract.

## Recorded experiment

The completed run on 2026-11-15 used the `large` profile, seed 42 and generator schema 2: 2,079 Python files, 65,770 lines, 2,048 generated service modules and 8,272 declared service-call edges. Paired domain graphs use direct imports in one half and mixed direct, aliased and namespace imports in the other. Twenty-three cases cover definitions, direct references, caller chains, same-name collisions and a missing symbol. Two source additions exercise refresh behavior.

Each arm received a private fixture copy and tool cache. Two rounds reversed arm order. Each round had a first pass, two warm passes, a two-second idle observation and a changed-source pass: 184 query observations per arm, repeating 23 distinct cases. Expected file sets came from the fixture declarations and generator relation model, independently of tool output. No model or agent solved the tasks.

Versions were Graphify (`graphifyy`) 0.9.103 with Python 3.12.15, Serena 2.1.0 and ripgrep 15.2.0; the runner used Python 3.15.2. Serena used Pyright 1.1.403. Both rounds' original runtime logs announce `Pyright language server 1.1.403 starting`; this version evidence was recovered during documentation review and added to the retained summary. Installed bundled package metadata independently agrees. The retained [machine-readable summary](../benchmarks/code-discovery/results/large-seed-42.json) contains source hashes, workload dimensions, settings, per-case measurement distributions and per-trial completion/cleanup outcomes. The source hashes identify the code at measurement time; subsequent runner edits add mandatory runtime-version recording and have not been exercised by this run. Machine-local paths, private runtime configuration, commands and raw protocol logs are excluded.

## Results

Times below are medians across rounds; the warm definition row uses the same `generated-0-direct-definition` case in every arm.

| Measurement | Graphify + rg | Serena + rg | rg baseline |
| --- | ---: | ---: | ---: |
| Exact file sets / scored observations | 184 / 184 | 152 / 184 | 40 / 128 |
| Unsupported observations | 0 | 0 | 56 |
| Preparation + first 23 queries | 30.590 s | 16.527 s | 0.234 s |
| Refresh + changed-source 23 queries | 27.400 s | 11.301 s | 0.274 s |
| Refresh alone | 22.848 s | 0.356 s | 0.003 s |
| Warm sampled definition query | 189.17 ms | 245.16 ms | 19.72 ms |
| Idle sampled process-tree RSS | No owned process observed | 1,327.2 MiB | No owned process observed |

All six trials completed without errors or timeouts and reported no remaining owned processes after cleanup. The literal rg baseline does not implement transitive caller traversal; those observations are unsupported, not correct empty results. Its lower latency accompanies a different level of discovery capability.

Serena's non-exact observations came from four distinct caller-chain cases: the calibration alias chain and the three generated mixed-import chains. Direct-import chain cases passed. These failures describe the benchmark's fixed `find_symbol` / `find_referencing_symbols` traversal workflow; they do not prove that another Serena workflow or a reasoning agent cannot recover those relationships.

Graphify preparation alone took 26.102 s with a median sampled peak process-tree RSS of 274.8 MiB. Refresh peaked at 301.4 MiB. Its index survives process exit on disk. Serena preparation reported MCP readiness after 1.024 s, but language-server work is lazy and continues during initial queries; that number is not a fully indexed cold-start time. The combined preparation/first-pass row is the more useful comparison.

## Interpretation and limits

The measured Graphify workflow found the expected file sets and avoided persistent process memory in this workload. Serena answered the first batch sooner and refreshed substantially faster, while retaining roughly 1.30 GiB during idle observation. Workstation prioritizes low idle resource use over immediate semantic refresh, so Graphify plus source search is the selected default. A disk cache is not free updating: unchanged sources reuse the index; source changes require an explicit rebuild using the extraction cache, and managed queries refuse stale indexes.

Graphify queries in this experiment load its native graph export in a separate Python worker and traverse incoming call edges. They include process startup and graph loading, but do not measure native natural-language query ranking or the managed launcher's freshness scan. File-set accuracy does not establish exact reference locations, safe renaming or better agent implementation outcomes. The literal rg arm is a baseline, not an agent making several intelligent searches.

Process-tree RSS was sampled every 100 ms; shared pages can be counted twice and short-lived peaks can be missed. No observed idle process is distinct from a measured zero-byte peak. Runs used fresh tool caches without evicting the operating system's filesystem cache. Two rounds on one VM do not establish a capacity limit or portable latency guarantee.

The generated corpus is a synthetic Python DAG with no external dependencies, cycles or dynamic dispatch. Paired import styles share the same workspace; their memory costs are not isolated. Earlier diagnostic attempts and the schema-1 large run remain local artifacts; this retained result uses schema 2, which corrected the direct-import entrypoint without changing the expected answer sets. There is no aggregate winner score.

## Applying the decision

The repository template no longer registers Serena or tracks its package in Renovate. Applying the existing [Codex configuration procedure](mcp.md#apply-and-inspect) updates the managed VM configuration; restart Codex afterward. Editing this repository does not change an already running chat's exposed tools. Existing uv caches, private Serena state and unrelated language-server installations are not automatically deleted.

The Serena benchmark adapter remains available for an explicitly requested comparison, using separately available executables; normal workstation provisioning no longer supplies its MCP registration. Revisit this decision when representative real repositories show missing discovery capability, refresh delays become disruptive, language-server refactoring is needed, or tool upgrades materially change the measured tradeoff.
