"""Test-only stdio MCP client and owned-process cleanup; no browser driver."""
import json
import os
from pathlib import Path
import queue
import pwd
import signal
import subprocess
import threading
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def render_server(output):
    """Render the repository's real Codex template without reading user settings."""
    config = output / 'config'
    config.mkdir(mode=0o700)
    play = [{'hosts': 'localhost', 'connection': 'local', 'gather_facts': True,
             'vars_files': [str(ROOT / 'ansible/roles' / name / 'defaults/main.yml')
                            for name in ['agent_tools', 'codex']],
             'vars': {'workstation_home': str(output / 'home'), 'workstation_user': pwd.getpwuid(os.getuid()).pw_name,
                      'codex_config_dir': str(config), 'codex_config_src': str(ROOT / 'dotfiles/codex/config.toml')},
             'tasks': [{'ansible.builtin.import_role': {'name': str(ROOT / 'ansible/roles/codex')}}]}]
    source = output / 'render.json'
    save(source, play)
    with (output / 'render.log').open('w') as log:
        subprocess.run(['ansible-playbook', '-i', 'localhost,', str(source), '--tags', 'codex_config',
                        '--extra-vars', json.dumps(play[0]['vars'])],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    server = tomllib.loads((config / 'config.toml').read_text())['mcp_servers']['chrome_devtools']
    if not server['enabled']:
        raise RuntimeError('Managed browser is disabled on this architecture; not a passing browser check')
    chrome = next(arg.split('=', 1)[1] for arg in server['args'] if arg.startswith('--executablePath='))
    if not Path(chrome).is_file():
        raise FileNotFoundError('Provision managed Chrome before running browser tests')
    return server


def process_table():
    table = {}
    for path in Path('/proc').iterdir():
        if path.name.isdigit():
            try:
                fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
                table[int(path.name)] = (int(fields[1]), fields[19], fields[0])
            except (OSError, IndexError, ValueError):
                pass
    return table


def runtime_environment(home, offline=True):
    # Reuse package/runtime caches, never copy login state or a user npm config.
    return {'HOME': str(home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LANG': 'C.UTF-8',
            'MISE_DATA_DIR': str(Path.home() / '.local/share/mise'),
            'MISE_CONFIG_FILE': str(Path.home() / '.config/mise/config.toml'),
            'npm_config_cache': str(Path.home() / '.npm'), 'npm_config_offline': str(offline).lower(),
            'npm_config_userconfig': str(home / '.npmrc'), 'NO_COLOR': '1',
            'CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS': '1'}


class ToolError(RuntimeError):
    pass


class MCP:
    def __init__(self, output, server, allowed_url):
        self.output, self.counter = output, 0
        output.mkdir(mode=0o700)
        home = output / 'home'
        home.mkdir(mode=0o700)
        environment = runtime_environment(home)
        # Strictly narrower than normal configuration. Fixture navigation stays on loopback.
        argv = [server['command'], *server['args'], '--allowed-url-pattern=' + allowed_url]
        save(output / 'command.json', {'argv': argv, 'offline_package_resolution': True})
        self.messages = queue.Queue()
        self.protocol = (output / 'mcp.jsonl').open('w')
        self.error = (output / 'mcp.stderr.log').open('w')
        self.seen, self.lock, self.stop = {}, threading.Lock(), threading.Event()
        self.process = subprocess.Popen(argv, cwd=ROOT, env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.error, text=True, start_new_session=True)
        self.root_pid = self.process.pid
        table = process_table()
        self.root_stamp = table.get(self.root_pid, (None, None, None))[1]
        self.sampler = threading.Thread(target=self.watch, daemon=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.sampler.start()
        self.reader.start()

    def sample(self):
        table = process_table()
        with self.lock:
            owned = {pid for pid, stamp in self.seen.items() if pid in table and table[pid][1] == stamp}
            if self.root_pid in table and table[self.root_pid][1] == self.root_stamp:
                owned.add(self.root_pid)
            while True:
                extra = {pid for pid, row in table.items() if row[0] in owned} - owned
                if not extra:
                    break
                owned |= extra
            self.seen.update({pid: table[pid][1] for pid in owned})
            return [pid for pid in owned if table[pid][2] != 'Z']

    def watch(self):
        while not self.stop.wait(.05):
            self.sample()

    def read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(line)
        finally:
            self.messages.put(None)

    def send(self, value):
        self.protocol.write(json.dumps({'sent': value}) + '\n')
        self.protocol.flush()
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def request(self, method, params, timeout=90):
        self.counter += 1
        identity = self.counter
        self.send({'jsonrpc': '2.0', 'id': identity, 'method': method, 'params': params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'MCP {method} deadline exceeded')
            try:
                line = self.messages.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(f'MCP {method} deadline exceeded') from error
            if line is None:
                raise RuntimeError('MCP exited; inspect mcp.stderr.log (missing offline cache is a failure)')
            value = json.loads(line)
            self.protocol.write(json.dumps({'received': value}) + '\n')
            self.protocol.flush()
            if 'method' in value and 'id' in value:
                self.send({'jsonrpc': '2.0', 'id': value['id'], 'error': {'code': -32601, 'message': 'No client callbacks'}})
            if value.get('id') == identity and ('result' in value or 'error' in value):
                if 'error' in value:
                    raise ToolError(str(value['error']))
                return value['result']

    def initialize(self):
        result = self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                              'clientInfo': {'name': 'workstation-browser-tests', 'version': '1'}})
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        tools = self.request('tools/list', {})
        save(self.output / 'initialize.json', result)
        save(self.output / 'tools.json', tools)
        return result, {tool['name']: tool for tool in tools['tools']}

    def tool(self, name, **arguments):
        result = self.request('tools/call', {'name': name, 'arguments': arguments}, timeout=120)
        if result.get('isError'):
            raise ToolError(f'{name}: {result}')
        return result

    def close(self, interrupt=False):
        """Observe natural cleanup first; forced reaping is reported, never a pass."""
        self.sample()
        if interrupt and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        timed_out = False
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            timed_out = True
        deadline = time.monotonic() + 5
        while self.sample() and time.monotonic() < deadline:
            time.sleep(.05)
        before = self.sample()
        # Only exact PID/start-time descendants observed in this run are reaped.
        for signum in (signal.SIGTERM, signal.SIGKILL):
            table = process_table()
            with self.lock:
                targets = [(pid, stamp) for pid, stamp in self.seen.items()]
            for pid, stamp in targets:
                if pid in table and table[pid][1] == stamp and table[pid][2] != 'Z':
                    try:
                        os.kill(pid, signum)
                    except ProcessLookupError:
                        pass
            if self.sample():
                time.sleep(.2)
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        remaining = self.sample()
        self.stop.set()
        self.sampler.join(timeout=2)
        self.reader.join(timeout=2)
        if not self.reader.is_alive():
            self.process.stdout.close()
        self.protocol.close()
        self.error.close()
        result = {'mode': 'SIGTERM-process-group' if interrupt else 'stdin-EOF', 'exit_code': self.process.poll(),
                  'shutdown_timed_out': timed_out, 'before_forced_cleanup': before,
                  'remaining_owned_pids': remaining, 'observed_processes': len(self.seen),
                  'reader_stopped': not self.reader.is_alive(), 'sampler_stopped': not self.sampler.is_alive(),
                  'ownership_limit': '50ms sampled descendants; short-lived/reparented processes can be missed'}
        save(self.output / 'cleanup.json', result)
        return result


def text(result):
    return '\n'.join(item['text'] for item in result.get('content', []) if item.get('type') == 'text')
