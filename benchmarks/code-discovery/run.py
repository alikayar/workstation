#!/usr/bin/env python3
"""Explicit, synthetic code-discovery comparison. No agents or model calls."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent


class Unsupported(RuntimeError):
    pass


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def local(root, name):
    path = Path(name)
    if path.is_absolute():
        # Backend output may contain an absolute fixture path.
        path = path.relative_to(root)
    if not path.parts or '..' in path.parts:
        raise ValueError(f'Invalid fixture path: {name}')
    return path.as_posix()


def process_table():
    result = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            result[int(entry.name)] = {
                'parent': int(fields[1]), 'start': fields[19], 'state': fields[0],
                'cpu': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                'rss': int(fields[21]) * os.sysconf('SC_PAGE_SIZE'),
            }
        except (OSError, IndexError, ValueError):
            continue
    return result


class Resources:
    """Sample owned process trees; RSS is not PSS or a kernel high-water mark."""
    def __init__(self, output):
        self.roots = set()
        self.seen = {}
        self.phase = 'setup'
        self.rss_peak = 0
        self.observed_samples = 0
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.stream = (output / 'resources.jsonl').open('w')
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()

    def sample(self):
        table = process_table()
        with self.lock:
            owned = {pid for pid, stamp in self.roots if pid in table and table[pid]['start'] == stamp}
            owned |= {pid for (pid, stamp) in self.seen if pid in table and table[pid]['start'] == stamp}
            while True:
                added = {pid for pid, row in table.items() if row['parent'] in owned} - owned
                if not added:
                    break
                owned |= added
            for pid in owned:
                row = table[pid]
                self.seen[(pid, row['start'])] = row['cpu']
            self.observed_samples += bool(owned)
            rss = sum(table[pid]['rss'] for pid in owned)
            self.rss_peak = max(self.rss_peak, rss)
            row = {'seconds': time.monotonic() - self.started, 'phase': self.phase,
                   'rss_bytes': rss, 'sampled_cpu_seconds': sum(self.seen.values())}
            self.stream.write(json.dumps(row) + '\n')
            self.stream.flush()
            return row

    def own(self, process):
        table = process_table()
        if process.pid in table:
            with self.lock:
                self.roots.add((process.pid, table[process.pid]['start']))

    def watch(self):
        while not self.stop.wait(.1):
            self.sample()

    @contextmanager
    def measure(self, label, report):
        with self.lock:
            self.phase, self.rss_peak, self.observed_samples = label, 0, 0
        before = self.sample()
        started = time.monotonic()
        try:
            yield
        finally:
            after = self.sample()
            with self.lock:
                report.update(seconds=time.monotonic() - started,
                              sampled_tree_peak_rss_bytes=self.rss_peak if self.observed_samples else None,
                              samples_with_owned_processes=self.observed_samples,
                              sampled_tree_cpu_seconds=(after['sampled_cpu_seconds'] - before['sampled_cpu_seconds']) if self.observed_samples else None)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)
        # Only descendants observed with this run's original PID/start-time identity.
        for signum in (signal.SIGTERM, signal.SIGKILL):
            table = process_table()
            live = [pid for pid, stamp in self.seen if pid in table and table[pid]['start'] == stamp and table[pid]['state'] != 'Z']
            for pid in live:
                try:
                    os.kill(pid, signum)
                except ProcessLookupError:
                    pass
            if live:
                time.sleep(.2)
        table = process_table()
        remaining = [pid for pid, stamp in self.seen if pid in table and table[pid]['start'] == stamp and table[pid]['state'] != 'Z']
        self.stream.close()
        return remaining


def terminate(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


class Trial:
    def __init__(self, output, root, env, timeout):
        self.output, self.root, self.env, self.timeout = output, root, env, timeout
        self.resources = Resources(output)
        self.sequence = 0
        self.deadline = None

    def remaining(self):
        remaining = self.timeout if self.deadline is None else self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Phase/query deadline exceeded')
        return remaining

    def command(self, argv, accepted=(0,)):
        self.sequence += 1
        prefix = self.output / f'command-{self.sequence:03d}'
        save(prefix.with_suffix('.json'), {'argv': argv})
        with prefix.with_suffix('.stdout').open('w') as out, prefix.with_suffix('.stderr').open('w') as err:
            process = subprocess.Popen(argv, cwd=self.root, env=self.env, stdout=out, stderr=err, start_new_session=True)
            self.resources.own(process)
            try:
                process.wait(timeout=self.remaining())
            finally:
                terminate(process)
        if process.returncode not in accepted:
            raise RuntimeError(f'Command exited {process.returncode}: {prefix.name}; inspect retained stdout/stderr')
        return prefix.with_suffix('.stdout').read_text()

    def seed(self, case):
        result = self.command(['rg', '--json', '-F', '--glob', '*.py', '--', case['symbol'], '.'], accepted=(0, 1))
        files = set()
        for line in result.splitlines():
            item = json.loads(line)
            if item['type'] == 'match':
                files.add(local(self.root, item['data']['path']['text']))
        return files


class Ripgrep:
    def __init__(self, trial):
        self.trial = trial

    def prepare(self):
        return {'version': self.trial.command(['rg', '--version']).splitlines()[0]}

    def query(self, case, seeds):
        if case['operation'] == 'ancestors':
            raise Unsupported('Plain text retrieval has no transitive symbol-reference operation')
        if case['operation'] == 'definitions':
            return seeds & {case['file']} if 'file' in case else seeds
        return seeds - {case['file']}

    def refresh(self, changes):
        pass

    def close(self):
        pass


def graph_query(root, path, case):
    """Query Graphify's native node-link export, without re-extracting source."""
    data = json.loads(path.read_text())
    if not isinstance(data.get('nodes'), list) or not isinstance(data.get('links'), list):
        raise Unsupported('Unsupported Graphify node-link export; expected nodes and links')
    nodes = {n['id']: n for n in data['nodes']}
    def file_of(node):
        return local(root, node['source_file']) if node.get('source_file') else None
    targets = {key for key, node in nodes.items()
               if node.get('_callable') is True and node.get('label') == case['symbol'] + '()' and
               ('file' not in case or file_of(node) == case['file'])}
    if case['operation'] == 'definitions':
        return sorted({file_of(nodes[key]) for key in targets if file_of(nodes[key])})
    found, frontier, visited = set(), targets, set(targets)
    for _ in range(case.get('max_depth', 1)):
        callers = {edge['source'] for edge in data['links']
                   if edge['target'] in frontier and str(edge.get('relation', '')).lower() in {'call', 'calls'}}
        frontier = callers - visited
        visited |= frontier
        for key in frontier:
            if key not in nodes:
                raise Unsupported('Graph edge points to a missing node')
            if file_of(nodes[key]):
                found.add(file_of(nodes[key]))
    return sorted(found - {case['file']})


class Graphify:
    def __init__(self, trial, executable):
        self.trial, self.executable = trial, executable

    def prepare(self):
        metadata = json.loads(self.trial.command([self.executable, 'index', '--structure-only']))
        self.graph = Path(metadata['graph']).resolve()
        self.graph.relative_to(Path(self.trial.env['HOME']))
        return metadata

    def query(self, case, seeds):
        # A separate worker includes Python startup and graph loading on every query.
        result = self.trial.command([sys.executable, str(Path(__file__).resolve()), '--graph-worker',
                                     str(self.trial.root), str(self.graph), json.dumps(case)])
        value = json.loads(result)
        if isinstance(value, dict) and 'unsupported' in value:
            raise Unsupported(value['unsupported'])
        return set(value)

    def refresh(self, changes):
        metadata = json.loads(self.trial.command([self.executable, 'update', '--structure-only']))
        self.graph = Path(metadata['graph']).resolve()
        self.graph.relative_to(Path(self.trial.env['HOME']))

    def close(self):
        pass


class MCP:
    """Sequential JSON-RPC over MCP stdio; never reuse the chat's live server."""
    def __init__(self, trial, command):
        self.trial, self.counter, self.messages = trial, 0, queue.Queue()
        self.log = (trial.output / 'mcp.jsonl').open('w')
        self.error = (trial.output / 'mcp.stderr').open('w')
        self.process = subprocess.Popen(command, cwd=trial.root, env=trial.env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.error, text=True, start_new_session=True)
        trial.resources.own(self.process)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def send(self, message):
        self.log.write(json.dumps({'sent': message}) + '\n')
        self.log.flush()
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.counter += 1
        request_id = self.counter
        self.send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params})
        deadline = time.monotonic() + self.trial.remaining()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'MCP {method} timed out')
            try:
                line = self.messages.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(f'MCP {method} timed out') from error
            if line is None:
                raise RuntimeError(f'MCP exited during {method}; inspect mcp.stderr')
            message = json.loads(line)
            self.log.write(json.dumps({'received': message}) + '\n')
            self.log.flush()
            if 'method' in message and 'id' in message:
                self.send({'jsonrpc': '2.0', 'id': message['id'],
                           'error': {'code': -32601, 'message': 'Benchmark has no sampling/elicitation callbacks'}})
            if message.get('id') == request_id and ('result' in message or 'error' in message):
                if 'error' in message:
                    raise RuntimeError(f'MCP error: {message["error"]}')
                return message['result']

    def tool(self, name, arguments):
        result = self.request('tools/call', {'name': name, 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError(f'Serena tool failed: {name}; inspect mcp.jsonl')
        return result

    def close(self):
        terminate(self.process)
        self.reader.join(timeout=2)
        self.log.close()
        self.error.close()


def symbols(result):
    """Only structured symbol records count; never scrape names from prose/snippets."""
    found = []
    def walk(value, inherited_file=None):
        if isinstance(value, list):
            for child in value:
                walk(child, inherited_file)
        elif isinstance(value, dict):
            path = value.get('relative_path', inherited_file)
            if isinstance(path, str) and isinstance(value.get('name_path'), str):
                found.append((path, value['name_path']))
            for key, child in value.items():
                if isinstance(child, (list, dict)):
                    walk(child, key if key.endswith('.py') else path)
    texts = [item['text'] for item in result.get('content', []) if item.get('type') == 'text']
    if not texts:
        raise Unsupported('Serena returned no textual JSON result')
    for text in texts:
        # A shortened/prose response is incompatible, not a successful empty result.
        walk(json.loads(text))
    if not found and any(json.loads(text) not in ([], {}) for text in texts):
        raise Unsupported('Unrecognized Serena symbol result; inspect mcp.jsonl')
    return found


class Serena:
    def __init__(self, trial, command, language_server):
        self.trial, self.command, self.language_server, self.client = trial, command, language_server, None

    def prepare(self):
        if not self.command or not self.language_server:
            raise FileNotFoundError('Serena requires --serena and --python-language-server; no installer is run')
        if not Path(self.language_server).is_absolute():
            raise ValueError('--python-language-server must be absolute')
        executable = Path(self.command[0])
        if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise FileNotFoundError('--serena must be an absolute path to an installed executable')
        server = Path(self.language_server).resolve(strict=True)
        if not server.is_file() or not os.access(server, os.X_OK):
            raise FileNotFoundError('Python language server is not executable')
        directory = self.trial.root / '.serena'
        directory.mkdir()
        save(directory / 'project.yml', {'project_name': 'discovery-fixture', 'language_servers': ['python'],
                                        'read_only': True, 'ignored_paths': []})
        # The runner, not the analyzed project, owns the executable choice. Keep
        # project trust restrictions intact; never edit the user's Serena config.
        config_home = Path(self.trial.env['SERENA_HOME'])
        config_home.mkdir(mode=0o700)
        save(config_home / 'serena_config.yml', {'projects': [], 'trusted_project_path_patterns': [],
                                               'ls_specific_settings': {'python': {'ls_path': str(server)}}})
        argv = [*self.command, '--project', str(self.trial.root), '--context', 'codex',
                '--agent-interface', 'tools', '--open-web-dashboard', 'false']
        save(self.trial.output / 'serena-command.json', argv)
        self.client = MCP(self.trial, argv)
        initialization = self.client.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                                            'clientInfo': {'name': 'workstation-discovery-benchmark', 'version': '1'}})
        self.client.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        tools = self.client.request('tools/list', {})['tools']
        self.tools = {tool['name'].rsplit('.', 1)[-1]: tool['name'] for tool in tools}
        save(self.trial.output / 'tools.json', tools)
        if not {'find_symbol', 'find_referencing_symbols'} <= self.tools.keys():
            raise Unsupported('Serena tools interface is incompatible; inspect tools.json')
        if 'initial_instructions' in self.tools:
            self.client.tool(self.tools['initial_instructions'], {})
        return {'server': initialization.get('serverInfo'), 'language_server': str(server), 'command': argv}

    def runtime_identity(self):
        # The server starts lazily during queries. Capture its own startup
        # announcement, rather than inferring the runtime from a wrapper pin.
        log = (self.trial.output / 'mcp.stderr').read_text()
        versions = set(re.findall(r'Pyright language server ([0-9]+\.[0-9]+\.[0-9]+) starting', log))
        if len(versions) != 1:
            raise RuntimeError('Expected one runtime Pyright version in mcp.stderr; comparison provenance is incomplete')
        return {'name': 'pyright', 'version': versions.pop(),
                'source': 'Language-server startup announcement in mcp.stderr'}

    def call(self, tool, args):
        return symbols(self.client.tool(self.tools[tool], {**args, 'max_answer_chars': 200000}))

    def query(self, case, seeds):
        if case['operation'] == 'definitions':
            result = self.call('find_symbol', {'name_path_pattern': case['symbol'], 'relative_path': case.get('file', '')})
            return {local(self.trial.root, path) for path, _ in result}
        frontier = [(case['file'], case['symbol'])]
        visited, files, calls = set(frontier), set(), 0
        for _ in range(case.get('max_depth', 1)):
            following = []
            for path, name in frontier:
                calls += 1
                if calls > 64:
                    raise Unsupported('Reference traversal exceeded the 64-call fixture bound')
                arguments = {'relative_path': path, 'name_path': name}
                if case['operation'] == 'ancestors':
                    # Follow callable referrers, not import/module pseudo-symbols.
                    arguments['include_kinds'] = [6, 12]  # LSP Method / Function
                result = self.call('find_referencing_symbols', arguments)
                for source, symbol in result:
                    source = local(self.trial.root, source)
                    files.add(source)
                    if (source, symbol) not in visited:
                        following.append((source, symbol))
                        visited.add((source, symbol))
            frontier = following
        return files - {case['file']}

    def refresh(self, changes):
        for change in changes:
            self.call('find_symbol', {'name_path_pattern': change['symbol'], 'relative_path': change['path']})

    def close(self):
        if self.client:
            self.client.close()


def score(actual, expected):
    actual, expected = set(actual), set(expected)
    matched = actual & expected
    return {'actual_files': sorted(actual), 'expected_files': sorted(expected),
            'missing': sorted(expected - actual), 'extra': sorted(actual - expected),
            'precision': len(matched) / len(actual) if actual else (1.0 if not expected else 0.0),
            'recall': len(matched) / len(expected) if expected else 1.0,
            'exact': actual == expected}


def outcome(action, trial, label):
    row = {'label': label}
    trial.deadline = time.monotonic() + trial.timeout
    with trial.resources.measure(label, row):
        try:
            row['value'] = action()
            row['status'] = 'ok'
        except (Exception, KeyboardInterrupt) as error:
            row['status'] = ('interrupted' if isinstance(error, KeyboardInterrupt) else
                             'unsupported' if isinstance(error, Unsupported) else
                             'unavailable' if isinstance(error, FileNotFoundError) else
                             'timeout' if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)) else 'error')
            row['error'] = f'{type(error).__name__}: {error}'
            if isinstance(error, KeyboardInterrupt):
                raise
        finally:
            trial.deadline = None
    return row


def trial_run(output, arm, spec, fixture, options):
    output.mkdir(mode=0o700)
    root, home = output / 'fixture', output / 'home'
    home.mkdir(mode=0o700)
    shutil.copytree(fixture, root)
    env = {'HOME': str(home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LANG': 'C.UTF-8',
           'UV_OFFLINE': '1', 'UV_CACHE_DIR': str(Path.home() / '.cache/uv'),
           'MISE_DATA_DIR': str(Path.home() / '.local/share/mise'),
           'MISE_CONFIG_FILE': str(Path.home() / '.config/mise/config.toml'),
           'SERENA_HOME': str(home / 'serena'), 'PYTHONDONTWRITEBYTECODE': '1',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
    trial = Trial(output, root, env, options.timeout)
    report = {'arm': arm, 'phases': [], 'queries': [], 'complete': False}
    adapter = Ripgrep(trial) if arm == 'rg' else Graphify(trial, options.graphify) if arm == 'graphify+rg' else Serena(trial, [str(options.serena), 'start-mcp-server'] if options.serena else None, options.python_language_server)
    def queries(phase):
        for case in spec['cases']:
            def query():
                request = {key: case[key] for key in ('operation', 'symbol', 'file', 'max_depth') if key in case}
                seeds = trial.seed(request)
                actual = adapter.query(request, seeds)
                expected = case.get('after_change_files', case['expected_files']) if phase == 'changed' else case['expected_files']
                return score(actual, expected)
            row = outcome(query, trial, phase + '/' + case['id'])
            report['queries'].append(row)
            save(output / 'result.json', report)
            if row['status'] not in {'ok', 'unsupported'}:
                return False
        return True
    try:
        trial.command(['git', 'init', '--quiet'])
        setup = outcome(adapter.prepare, trial, 'prepare-new-process-and-tool-cache')
        report['phases'].append(setup)
        if setup['status'] != 'ok':
            return report
        if not queries('first-pass'):
            return report
        if arm == 'serena+rg':
            report['language_server'] = adapter.runtime_identity()
        for number in range(options.warm):
            if not queries(f'warm-{number + 1}'):
                return report
        report['phases'].append(outcome(lambda: time.sleep(options.idle_seconds), trial, 'idle'))
        for change in spec['changes']:
            path = root / local(root, change['path'])
            if path.exists():
                raise ValueError('Source-addition workload must not overwrite an existing file')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(change['content'])
        refresh = outcome(lambda: adapter.refresh(spec['changes']), trial, 'refresh-after-source-addition')
        report['phases'].append(refresh)
        # Never silently query a known stale index after a failed refresh.
        report['complete'] = refresh['status'] == 'ok' and queries('changed')
        return report
    except KeyboardInterrupt:
        report['interrupted'] = True
        raise
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        return report
    finally:
        try:
            adapter.close()
        finally:
            report['remaining_owned_pids'] = trial.resources.close()
            save(output / 'result.json', report)


def summarize(trials):
    groups = {}
    for trial in trials:
        for item in trial['phases'] + trial['queries']:
            phase, _, case = item['label'].partition('/')
            if phase.startswith('warm-'):
                phase = 'warm'
            groups.setdefault((trial['arm'], phase, case), []).append(item)
    rows = []
    for (arm, phase, case), items in sorted(groups.items()):
        statuses = {status: sum(item['status'] == status for item in items)
                    for status in sorted({item['status'] for item in items})}
        scored = [item['value'] for item in items if item['status'] == 'ok' and
                  isinstance(item.get('value'), dict) and 'exact' in item['value']]
        row = {'arm': arm, 'phase': phase, 'case': case or None, 'attempts': len(items),
               'statuses': statuses, 'scored_results': len(scored),
               'exact_matches': sum(value['exact'] for value in scored) if scored else None}
        for metric in ('seconds', 'sampled_tree_peak_rss_bytes', 'sampled_tree_cpu_seconds'):
            values = [item[metric] for item in items if item['status'] == 'ok' and item.get(metric) is not None]
            row[metric] = ({'observations': len(values), 'median': statistics.median(values),
                            'min': min(values), 'max': max(values)} if values else None)
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New/empty artifact directory outside this checkout.')
    parser.add_argument('--profile', choices=['smoke', 'small', 'medium', 'large'], default='smoke',
                        help='Keep smoke lightweight; generate larger connected corpora only when selected.')
    parser.add_argument('--seed', type=int, default=42, help='Deterministic topology/import-style seed for generated profiles.')
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--warm', type=int, default=2)
    parser.add_argument('--idle-seconds', type=float, default=2)
    parser.add_argument('--timeout', type=float, default=120, help='Whole phase/query deadline, seconds.')
    parser.add_argument('--arms', nargs='+', choices=['rg', 'graphify+rg', 'serena+rg'], default=['rg', 'graphify+rg', 'serena+rg'])
    parser.add_argument('--graphify', default='workstation-graphify')
    parser.add_argument('--serena', type=Path, help='Absolute path to the installed Serena executable; package resolvers are not invoked.')
    parser.add_argument('--python-language-server', help='Absolute path to an installed pyright-langserver; bypasses managed installation.')
    options = parser.parse_args()
    if options.rounds < 1 or options.warm < 0 or options.idle_seconds < 0 or options.idle_seconds > options.timeout or options.timeout <= 0:
        parser.error('Invalid count/duration')
    output = options.output.expanduser().absolute()
    if output.resolve() != output:
        parser.error('--output and its ancestors must not contain symlinks or parent traversals')
    repository = HERE.parents[1]
    if output.is_relative_to(repository) or output.is_symlink():
        parser.error('--output must be outside the checkout and not a symlink')
    output.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output must be empty')
    os.umask(0o077)
    spec = json.loads((HERE / 'cases.json').read_text())
    fixture = HERE / 'fixtures' / spec['fixture']
    workload = {'profile': options.profile, 'seed': options.seed if options.profile != 'smoke' else None}
    if options.profile != 'smoke':
        from generate import build
        profiles = json.loads((HERE / 'profiles.json').read_text())
        generated = output / 'corpus'
        started = time.monotonic()
        spec, dimensions = build(generated, fixture, spec, profiles[options.profile], options.seed)
        workload.update(dimensions, generation_seconds=time.monotonic() - started)
        fixture = generated
    save(output / 'workload.json', {'dimensions': workload, 'spec': spec})
    paths = sorted(p for p in fixture.rglob('*') if p.is_file())
    if any(p.is_symlink() for p in fixture.rglob('*')):
        parser.error('Linked fixture paths are refused')
    manifest = {str(p.relative_to(fixture)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    results = {'scope': 'Synthetic Python file-candidate retrieval; no agent/model or refactor measurement',
               'fixture_sha256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
               'fixture_manifest': manifest, 'workload': workload, 'python': sys.version,
               'benchmark_sources': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                                     for name in ('run.py', 'generate.py', 'cases.json', 'profiles.json')}, 'options': vars(options) | {'output': str(output), 'serena': str(options.serena) if options.serena else None},
               'resource_semantics': '100ms sampled process-tree RSS and CPU; shared pages may be counted twice; short-lived processes/peaks may be missed; no OS-cache eviction',
               'trials': [], 'collection_complete': False}
    try:
        for number in range(options.rounds):
            order = list(dict.fromkeys(options.arms))
            if number % 2:
                order.reverse()
            for arm in order:
                print(f'Round {number + 1}: {arm}', flush=True)
                result = trial_run(output / f'round-{number + 1}-{arm}', arm, spec, fixture, options)
                results['trials'].append(result)
                save(output / 'result.json', results)
        results['collection_complete'] = True
    except KeyboardInterrupt:
        results['interrupted'] = True
        raise
    finally:
        save(output / 'result.json', results)
        save(output / 'summary.json', summarize(results['trials']))
        print(f'Artifacts retained: {output}', flush=True)
    # Retrieval misses are measured outcomes, not hidden. Infrastructure failures fail the run.
    failed = any(not t['complete'] or t['remaining_owned_pids'] or
                 any(q['status'] not in {'ok', 'unsupported'} for q in t['queries']) for t in results['trials'])
    return int(failed)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--graph-worker']:
        try:
            print(json.dumps(graph_query(Path(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4]))))
        except Unsupported as error:
            print(json.dumps({'unsupported': str(error)}))
    else:
        def interrupt(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupt)
        signal.signal(signal.SIGHUP, interrupt)
        raise SystemExit(main())
