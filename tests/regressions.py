#!/usr/bin/env python3
"""Exercise Workstation tasks in disposable homes; never apply the full playbook."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--installed-tools', action='store_true', help='Also exercise real SiteOne extraction and Lighthouse npm recovery on a prepared VM; may download pinned packages.')
parser.add_argument('--output', type=Path, help='New or empty artifact directory; defaults to a private directory under /tmp.')
OPTIONS = parser.parse_args()
OUTPUT = OPTIONS.output.resolve() if OPTIONS.output else Path(tempfile.mkdtemp(prefix='ws-regressions-'))
OUTPUT.mkdir(mode=0o700, parents=True, exist_ok=True)
if any(OUTPUT.iterdir()):
    parser.error('--output must be a new or empty directory')
print(f'Artifacts: {OUTPUT}', flush=True)


class Regressions(unittest.TestCase):
    def setUp(self):
        self.base = OUTPUT / self._testMethodName
        self.base.mkdir()
        self.home = self.base / 'home'
        (self.home / '.local/bin').mkdir(parents=True)
        self.calls = 0

    def apply(self, role, variables=None, tags=None, success=True, unchanged=False, tasks_from='main'):
        self.calls += 1
        values = {
            'workstation_home': str(self.home),
            'workstation_user': pwd.getpwuid(os.getuid()).pw_name,
            'ansible_facts': {'architecture': platform.machine()},
            **(variables or {}),
        }
        play = [{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': values,
            'vars_files': [str(ROOT / 'ansible/roles' / name / 'defaults/main.yml') for name in ['agent_tools', 'mise', 'codex']],
            'tasks': [{'ansible.builtin.import_role': {'name': str(ROOT / 'ansible/roles' / role), 'tasks_from': tasks_from}}],
        }]
        path = self.base / f'play-{self.calls}.json'
        path.write_text(json.dumps(play))
        command = ['ansible-playbook', '-i', 'localhost,', str(path), '--extra-vars', json.dumps(values)]
        if tags:
            command += ['--tags', tags]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
        log = self.base / f'apply-{self.calls}.log'
        log.write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode == 0, success, str(log))
        if unchanged:
            self.assertRegex(result.stdout, r'localhost\s*:\s*ok=\d+\s+changed=0\b', str(log))
        return result

    def prepare_cli_migration(self):
        commands = ['yq', 'bat', 'fd', 'gh', 'rg', 'delta', 'shellcheck', 'hyperfine']
        installs = self.home / '.local/share/mise/installs'
        for command in commands:
            binary = installs / command / 'bin' / command
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
        mise = self.base / 'mise'
        mise.write_text(f'#!{sys.executable}\nimport pathlib,sys\n'
                        f'root = pathlib.Path({str(installs)!r})\n'
                        'if len(sys.argv) != 3 or sys.argv[1] != "which": sys.exit(1)\n'
                        'print(root / sys.argv[2] / "bin" / sys.argv[2])\n')
        mise.chmod(0o755)
        legacy_yq = b'fixture: former Workstation yq binary\n'
        return {
            'mise_binary': str(mise),
            'mise_config_dest': str(self.base / 'mise.toml'),
            'cli_tools_legacy_yq_checksums': [hashlib.sha256(legacy_yq).hexdigest()],
        }, legacy_yq

    def test_cli_migration_ownership(self):
        values, legacy_yq = self.prepare_cli_migration()
        directory = self.home / '.local/bin'
        (directory / 'fd').symlink_to('/usr/bin/fdfind')
        (directory / 'bat').symlink_to('/usr/bin/batcat')
        (directory / 'yq').write_bytes(legacy_yq)
        self.apply('cli_tools', values, tags='cli_tools_legacy_launchers')
        for name in ['fd', 'bat', 'yq']:
            self.assertFalse((directory / name).exists())
            self.assertFalse((directory / name).is_symlink())
        self.apply('cli_tools', values, tags='cli_tools_legacy_launchers', unchanged=True)
        for name in ['fd', 'bat', 'yq']:
            for kind in ['file', 'foreign-link', 'broken-link']:
                with self.subTest(name=name, collision=kind):
                    entry = directory / name
                    foreign = self.base / f'{name}-{kind}'
                    if kind == 'file':
                        entry.write_text('user-owned sentinel')
                    else:
                        if kind == 'foreign-link':
                            foreign.write_text('user-owned target')
                        entry.symlink_to(foreign)
                    result = self.apply('cli_tools', values, tags='cli_tools_legacy_launchers', success=False)
                    self.assertIn('retained; review its ownership', result.stdout)
                    if kind == 'file':
                        self.assertEqual(entry.read_text(), 'user-owned sentinel')
                    else:
                        self.assertEqual(os.readlink(entry), str(foreign))
                    entry.unlink()

    def test_cli_migration_requires_installed_replacements(self):
        values, _ = self.prepare_cli_migration()
        legacy = self.home / '.local/bin/bat'
        legacy.symlink_to('/usr/bin/batcat')
        (self.home / '.local/share/mise/installs/gh/bin/gh').unlink()
        self.apply('cli_tools', values, tags='cli_tools_legacy_launchers', success=False)
        self.assertEqual(os.readlink(legacy), '/usr/bin/batcat')

    def test_browser_wrapper_guards(self):
        native = self.base / 'native'
        native.mkdir()
        executable = native / 'agent-browser'
        executable.write_text(f'#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        executable.chmod(0o755)
        self.apply('agent_tools', {'agent_tools_browser_install_dir': str(native)}, tags='agent_browser_launcher', tasks_from='agent-browser')
        wrapper = self.home / '.local/bin/agent-browser'
        environment = {key: value for key, value in os.environ.items() if not key.startswith('AGENT_BROWSER_')}
        for flags in [['--state', 'visible'], ['--state=visible']]:
            result = subprocess.run([str(wrapper), '--session', 'fixture', 'wait', '#status', *flags], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)[-len(flags):], flags)
        for args in [['open', 'about:blank', '--state=saved.json'], ['open', 'about:blank', '--state', 'saved.json'], ['connect', '9222'], ['close', '--all']]:
            result = subprocess.run([str(wrapper), '--session', 'fixture', *args], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, args)
        result = subprocess.run([str(wrapper), '--session', 'other', 'snapshot'], env={**environment, 'AGENT_BROWSER_SESSION': 'fixture'}, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)

    def test_codex_browser_configuration(self):
        config = self.base / 'codex'
        config.mkdir()
        chrome = self.base / 'managed chrome'
        values = {'codex_config_dir': str(config), 'codex_config_src': str(ROOT / 'dotfiles/codex/config.toml'), 'agent_tools_browser_chrome_dir': str(chrome)}
        self.apply('codex', values, tags='codex_config')
        self.apply('codex', values, tags='codex_config', unchanged=True)
        data = tomllib.loads((config / 'config.toml').read_text())
        server = data['mcp_servers']['chrome_devtools']
        self.assertFalse(server['enabled'])
        self.assertIn(f'--executablePath={chrome}/chrome-linux64/chrome', server['args'])
        self.assertIn('--no-usage-statistics', server['args'])
        self.assertIn('--no-performance-crux', server['args'])
        self.assertNotIn('playwright', data['mcp_servers'])

    @unittest.skipUnless(OPTIONS.installed_tools, 'requires --installed-tools on a prepared VM')
    def test_codex_plugin_configuration_idempotency(self):
        codex = shutil.which('codex')
        self.assertIsNotNone(codex, 'Install Codex before exercising plugin configuration')
        config = self.home / '.codex'
        config.mkdir(mode=0o700)
        wrapper = self.base / 'isolated-codex'
        wrapper.write_text(f'#!{sys.executable}\nimport os,sys\n'
                           f'os.environ["HOME"] = {str(self.home)!r}\n'
                           f'os.environ["CODEX_HOME"] = {str(config)!r}\n'
                           f'os.execv({codex!r}, [{codex!r}, *sys.argv[1:]])\n')
        wrapper.chmod(0o755)
        values = {'codex_binary': str(wrapper), 'codex_config_dir': str(config),
                  'codex_config_src': str(ROOT / 'dotfiles/codex/config.toml')}
        self.apply('codex', values, tags='codex_config')
        expected = (config / 'config.toml').read_bytes()
        self.apply('codex', values, tasks_from='plugins')
        self.assertEqual((config / 'config.toml').read_bytes(), expected)
        self.apply('codex', values, tags='codex_config', unchanged=True)
        self.apply('codex', values, tasks_from='plugins', unchanged=True)

    @unittest.skipUnless(OPTIONS.installed_tools, 'requires --installed-tools on a prepared VM')
    def test_siteone_recovery_and_custom_directory(self):
        # The real pinned archive from provisioning is reused without copying user configuration.
        cache = Path.home() / '.local/share/workstation'
        candidates = sorted(cache.glob('siteone-crawler-*/archive.tar.gz'))
        self.assertTrue(candidates, 'Install SiteOne with the current checkout first')
        archive = candidates[-1]
        first = self.home / 'custom/siteone-a'
        first.mkdir(parents=True)
        (first / 'archive.tar.gz').write_bytes(archive.read_bytes())
        binary = first / 'siteone-crawler'
        binary.write_text('interrupted extraction')
        binary.chmod(0o755)
        values = {'agent_tools_siteone_dir': str(first)}
        self.apply('agent_tools', values, tasks_from='siteone')
        self.assertTrue(list(first.glob('.workstation-siteone-ready-*')))
        result = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=10)
        self.assertIn('Version:', result.stdout)  # Upstream prints version with exit 2.
        self.apply('agent_tools', values, tasks_from='siteone', unchanged=True)
        binary.unlink()
        self.apply('agent_tools', values, tasks_from='siteone')
        self.assertTrue(os.access(binary, os.X_OK))
        second = self.home / 'custom/siteone-b'
        second.mkdir()
        (second / 'archive.tar.gz').write_bytes(archive.read_bytes())
        values = {'agent_tools_siteone_dir': str(second)}
        self.apply('agent_tools', values, tasks_from='siteone')
        self.assertEqual((self.home / '.local/bin/siteone-crawler').resolve(), second / 'siteone-crawler')
        self.apply('agent_tools', values, tasks_from='siteone', unchanged=True)

    @unittest.skipUnless(OPTIONS.installed_tools, 'requires --installed-tools on a prepared VM')
    def test_lighthouse_failed_install_and_repair(self):
        mise = shutil.which('mise')
        self.assertIsNotNone(mise, 'Install the workstation runtimes first')
        prefix = self.home / 'custom/lighthouse'
        cli = prefix / 'node_modules/lighthouse/cli/index.js'
        fake = self.base / 'failing-mise'
        fake.write_text(f'''#!{sys.executable}
import os,sys
from pathlib import Path
if sys.argv[1:]==['where','node']:
 os.execv({mise!r}, [{mise!r}, 'where', 'node'])
p=Path({str(cli)!r});p.parent.mkdir(parents=True,exist_ok=True);p.write_text('partial npm install')
sys.exit(42)
''')
        fake.chmod(0o755)
        values = {'agent_tools_lighthouse_dir': str(prefix), 'mise_binary': str(fake)}
        failed = self.apply('agent_tools', values, tasks_from='lighthouse', success=False)
        self.assertIn('42', failed.stdout)
        self.assertTrue(cli.exists())
        self.assertFalse(list(prefix.glob('.workstation-ready-*')))
        values['mise_binary'] = mise
        self.apply('agent_tools', values, tasks_from='lighthouse')
        self.assertTrue(list(prefix.glob('.workstation-ready-*')))
        subprocess.run([str(self.home / '.local/bin/lighthouse'), '--version'], check=True, capture_output=True, timeout=15)
        self.apply('agent_tools', values, tasks_from='lighthouse', unchanged=True)
        cli.unlink()
        values['mise_binary'] = str(fake)
        self.apply('agent_tools', values, tasks_from='lighthouse', success=False)
        self.assertFalse(list(prefix.glob('.workstation-ready-*')), 'Old marker must be invalidated before repairing')
        values['mise_binary'] = mise
        self.apply('agent_tools', values, tasks_from='lighthouse')
        subprocess.run([str(self.home / '.local/bin/lighthouse'), '--version'], check=True, capture_output=True, timeout=15)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Regressions))
    (OUTPUT / 'result.json').write_text(json.dumps({'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'skipped': len(result.skipped)}, indent=2))
    print(f'Artifacts retained: {OUTPUT}', flush=True)
    sys.exit(not result.wasSuccessful())
