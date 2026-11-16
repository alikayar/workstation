"""Shared regression cases for workstation prerequisites, diagnostics and ownership."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]


class WorkstationContracts:
    def graphify_source(self):
        directory = self.base / 'adapter'
        directory.mkdir()
        self.apply('agent_tools', {'agent_tools_graphify_dir': str(directory),
                                  'codex_config_src': str(ROOT / 'dotfiles/codex/config.toml')}, tags='graphify_config')
        return directory / 'workstation-graphify.py'

    def service(self, *arguments):
        module = self.load_source('ansible/roles/cli_tools/files/workstation-service.py', 'service_contract')
        return module, mock.patch.object(sys, 'argv', ['workstation-service', *arguments])

    def test_base_prerequisites_and_native_selection(self):
        # Ansible source contracts verify role order and declared prerequisites without installing.
        command = ['ansible-playbook', 'ansible/site.yml', '--list-tasks', '--tags', 'base,codex,mise',
                   '--extra-vars', '{"workstation_languages": ["node"]}']
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index('base : Install common'), result.stdout.index('codex : Install Codex'))
        self.assertLess(result.stdout.index('base : Install native'), result.stdout.index('mise : Install mise'))
        # Read role vars through Ansible, not a duplicate package list in a mock installer.
        play = [{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                 'vars_files': [str(ROOT / 'ansible/roles/base/defaults/main.yml')],
                 'tasks': [{'ansible.builtin.copy': {'content': '{{ {"common": base_packages, "native": base_native_packages} | to_json }}',
                                                     'dest': str(self.base / 'packages.json'), 'mode': '0600'}}]}]
        path = self.base / 'base-play.json'
        path.write_text(json.dumps(play))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(path)], cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = json.loads((self.base / 'packages.json').read_text())
        self.assertTrue({'curl', 'ca-certificates', 'unzip', 'python3', 'dbus-user-session'} <= set(packages['common']))
        self.assertTrue({'build-essential', 'pkg-config'} <= set(packages['native']))

    def test_cli_helpers_install_idempotently_and_preserve_foreign_commands(self):
        self.apply('cli_tools', tags='cli_tools_config')
        for name in ('workstation-doctor', 'workstation-service'):
            path = self.home / '.local/bin' / name
            self.assertTrue(os.access(path, os.X_OK))
            self.assertIn('Workstation managed', path.read_text()[:256])
        self.apply('cli_tools', tags='cli_tools_config', unchanged=True)
        command = self.home / '.local/bin/workstation-doctor'
        command.write_text('user owned command')
        self.apply('cli_tools', tags='cli_tools_config', success=False)
        self.assertEqual(command.read_text(), 'user owned command')

    def test_graphify_publication_failure_retains_snapshot_and_bounds_writer_wait(self):
        source = self.graphify_source()
        spec = __import__('importlib.util', fromlist=['spec_from_file_location'])
        module_spec = spec.spec_from_file_location('graphify_contract', source)
        module = spec.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        cache = self.base / 'cache'; cache.mkdir()
        old = module.publish_index(cache, {'nodes': []}, {'nodes': ['before']}, {'files': {'old.py': [1, 1]}})
        pointer = (cache / 'current.json').read_bytes()
        real_write = module.write_json
        def fail_publication(path, value):
            if path == cache / 'current.json':
                raise OSError('synthetic interrupted pointer publication')
            return real_write(path, value)
        with mock.patch.object(module, 'write_json', side_effect=fail_publication):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                module.publish_index(cache, {}, {'nodes': ['after']}, {'files': {'new.py': [2, 2]}})
        self.assertEqual((cache / 'current.json').read_bytes(), pointer)
        self.assertEqual(module.current_index(cache)[0], old)
        self.assertEqual(json.loads((old / 'graph.json').read_text())['nodes'], ['before'])
        with module.writer_lock(cache, 0):
            # Readers use immutable generations even while a writer is active.
            self.assertEqual(module.current_index(cache)[0], old)
            began = time.monotonic()
            with self.assertRaisesRegex(ValueError, 'writer lock timed out'):
                with module.writer_lock(cache, .05):
                    self.fail('A second writer acquired the same lock')
            self.assertLess(time.monotonic() - began, 2)
        with module.writer_lock(cache, 0):
            new = module.publish_index(cache, {}, {'nodes': ['after']}, {'files': {}})
        self.assertNotEqual(new, old)
        self.assertEqual(module.current_index(cache)[0], new)
        (cache / 'current.json').write_text('{"generation":"../outside"}')
        with self.assertRaisesRegex(ValueError, 'Invalid index generation'):
            module.current_index(cache)

    def test_doctor_reports_unknown_without_sensitive_or_mutating_commands(self):
        module = self.load_source('ansible/roles/cli_tools/files/workstation-doctor.py', 'doctor_contract')
        commands = []
        def probe(argv):
            commands.append(argv)
            if argv[:2] == ['getent', 'passwd']:
                return 0, 'fixture:x:1000:1000:Fixture:/fixture:/usr/bin/zsh'
            return 1, 'synthetic inaccessible provider'
        with mock.patch.object(module, 'command', side_effect=probe), mock.patch.object(module.shutil, 'which', return_value=None), mock.patch.object(module.Path, 'is_socket', return_value=False):
            findings = module.diagnose(['missing-fixture-command'], ['node'], self.base / 'missing-chrome')
        values = {entry['check']: entry for entry in findings}
        self.assertEqual(values['command:missing-fixture-command']['status'], 'WARN')
        self.assertEqual(values['user-service-manager']['status'], 'UNKNOWN')
        self.assertEqual(values['login-shell']['detail'], '/usr/bin/zsh')
        self.assertEqual(values['project-node']['status'], 'UNKNOWN')
        self.assertEqual(values['chrome-executable']['status'], 'WARN')
        self.assertFalse(any(token in {'start','stop','enable','install','show-environment'} for argv in commands for token in argv))
        completed = subprocess.CompletedProcess([], 0, '/fixture/node\n', '')
        with mock.patch.object(module.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(module.command(['mise', 'which', 'node']), (0, '/fixture/node'))
        self.assertEqual(run.call_args.kwargs['env']['MISE_AUTO_INSTALL'], '0')

    def test_service_refuses_foreign_units_and_invalid_limits(self):
        task = str(uuid.uuid4())
        module, arguments = self.service('stop', '--task', task, '--directory', str(self.base))
        foreign = {'LoadState': 'loaded', 'Description': 'Unrelated service', 'WorkingDirectory': str(self.base)}
        with arguments, mock.patch.object(module, 'inspect', return_value=foreign), mock.patch.object(module, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'ownership'):
                module.main()
            self.assertFalse(any('stop' in args[0] for args, _ in run.call_args_list))
        with mock.patch.object(sys, 'argv', ['workstation-service', 'start', '--task', task, '--memory', '0G', '--', 'true']), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                module.main()
            self.assertEqual(raised.exception.code, 2)

    def test_service_launch_enforces_limits_and_preserves_command_arguments(self):
        task = str(uuid.uuid4())
        module, arguments = self.service('start', '--task', task, '--directory', str(self.base), '--memory', '128M', '--cpu', '25', '--seconds', '30',
                                         '--', sys.executable, '-c', 'print("$LITERAL")')
        own = {'LoadState':'loaded', 'Description':f'Workstation task {task}', 'WorkingDirectory':str(self.base), 'ActiveState':'active'}
        with arguments, mock.patch.object(module, 'inspect', side_effect=[None, own]), mock.patch.object(module, 'run') as run, redirect_stdout(io.StringIO()):
            module.main()
        launch = run.call_args_list[-1].args[0]
        for option in ['--property=MemoryMax=128M','--property=CPUQuota=25%','--property=RuntimeMaxSec=30',
                       '--property=KillMode=control-group','--expand-environment=no']:
            self.assertIn(option, launch)
        self.assertEqual(launch[-3:], [sys.executable, '-c', 'print("$LITERAL")'])

    def test_graphify_real_index_refresh_and_concurrent_reads(self):
        from __main__ import OPTIONS
        if not OPTIONS.installed_tools:
            self.skipTest('requires --installed-tools and the prepared Graphify environment')
        launcher = shutil.which('workstation-graphify')
        self.assertIsNotNone(launcher)
        executable = shlex.split(next(line for line in Path(launcher).read_text().splitlines() if line.startswith('exec ')))[1]
        self.assertTrue(Path(executable).is_file())
        source = self.graphify_source()
        repository = self.base / 'repository'; repository.mkdir()
        subprocess.run(['git', 'init', '-q', str(repository)], check=True, timeout=10)
        (repository / 'main.py').write_text('def entry():\n    return 42\n')
        # Only child process HOME changes; installed runtime is explicit, no resolver/install.
        environment = {**os.environ, 'HOME': str(self.home)}
        def invoke(*args, success=True):
            result = subprocess.run([executable, str(source), '--root', str(repository), *args], cwd=repository,
                                    env=environment, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            return result
        built = json.loads(invoke('index', '--structure-only').stdout)
        graph = Path(built['graph'])
        self.assertTrue(graph.is_file())
        invoke('query', 'entry')
        cache = Path(built['cache'])
        import fcntl
        with (cache / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            invoke('info')
            invoke('query', 'entry')
            blocked = invoke('--lock-timeout', '0', 'update', '--structure-only', success=False)
            self.assertIn('writer lock timed out', blocked.stderr)
        (repository / 'other.py').write_text('from main import entry\ndef caller():\n    return entry()\n')
        stale = invoke('query', 'caller', success=False)
        self.assertIn('stale', stale.stderr)
        updated = json.loads(invoke('update', '--structure-only').stdout)
        self.assertNotEqual(updated['graph'], built['graph'])
        self.assertTrue(graph.is_file(), 'Old reader snapshot must remain available')
        invoke('query', 'caller')
        self.assertIn('other.py', json.loads((Path(updated['graph']).parent / 'index.json').read_text())['files'])

    def test_service_real_user_unit_lifecycle_and_child_cleanup(self):
        from __main__ import OPTIONS
        if not OPTIONS.installed_tools:
            self.skipTest('requires --installed-tools and a working systemd user manager')
        manager = subprocess.run(['systemctl','--user','show','--property=Version','--value'], capture_output=True, text=True, timeout=5)
        if manager.returncode:
            self.skipTest('systemd user manager unavailable; live lifecycle not exercised')
        task = str(uuid.uuid4())
        self.apply('cli_tools', tags='cli_tools_config')
        script = self.home / '.local/bin/workstation-service'
        unit = f'workstation-task-{task}.service'
        ready = self.base / 'child.pid'
        program = self.base / 'service-fixture.py'
        program.write_text('import subprocess,sys,time\nfrom pathlib import Path\n'
                           'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(90)"])\n'
                           f'Path({str(ready)!r}).write_text(str(child.pid))\n'
                           'time.sleep(90)\n')
        def invoke(action, *args, success=True):
            result = subprocess.run([str(script), action, '--task', task, '--directory', str(self.base), *args],
                                    capture_output=True, text=True, timeout=25)
            (self.base / (action + '.log')).write_text(result.stdout + result.stderr)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            return result
        child = None
        try:
            properties = json.loads(invoke('start', '--memory','128M','--cpu','25','--seconds','45','--',sys.executable,str(program)).stdout)
            self.assertEqual(int(properties['MemoryMax']), 128*1024**2)
            self.assertEqual(properties['CPUQuotaPerSecUSec'], '250ms')
            self.assertEqual(properties['RuntimeMaxUSec'], '45s')
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(ready.exists())
            child = int(ready.read_text())
            self.assertTrue(Path(f'/proc/{child}').exists())
            duplicate = invoke('start','--',sys.executable,'-c','raise SystemExit(99)', success=False)
            self.assertIn('already exists', duplicate.stderr)
            self.assertEqual(json.loads(invoke('status').stdout)['ActiveState'], 'active')
            invoke('logs','--lines','5')
        finally:
            # Stop only this exact task unit, even if an assertion or launch failed.
            result = subprocess.run([str(script),'stop','--task',task,'--directory',str(self.base)],
                                    capture_output=True,text=True,timeout=25)
            (self.base / 'cleanup.log').write_text(result.stdout + result.stderr)
        state = subprocess.run(['systemctl','--user','show',unit,'--property=ActiveState','--value'], capture_output=True,text=True,timeout=5)
        self.assertNotEqual(state.stdout.strip(), 'active')
        if child:
            deadline = time.monotonic() + 3
            while Path(f'/proc/{child}').exists() and time.monotonic() < deadline:
                # A zombie cannot execute; a live descendant must disappear.
                if Path(f'/proc/{child}/stat').read_text().split(') ',1)[1].split()[0] == 'Z':
                    break
                time.sleep(.05)
            self.assertTrue(not Path(f'/proc/{child}').exists() or Path(f'/proc/{child}/stat').read_text().split(') ',1)[1].split()[0]=='Z')

    def test_graphify_benchmark_refresh_tracks_new_generation(self):
        module = self.load_source('benchmarks/code-discovery/run.py', 'discovery_contract')
        first, second = self.home / 'generation-one.json', self.home / 'generation-two.json'
        trial = mock.Mock()
        trial.env = {'HOME': str(self.home)}
        trial.command.side_effect = [json.dumps({'graph': str(first)}), json.dumps({'graph': str(second)})]
        adapter = module.Graphify(trial, 'fixture-graphify')
        adapter.prepare()
        self.assertEqual(adapter.graph, first)
        adapter.refresh([])
        self.assertEqual(adapter.graph, second)
