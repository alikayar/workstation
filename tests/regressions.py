#!/usr/bin/env python3
"""Exercise Workstation tasks in disposable homes; never apply the full playbook."""
import argparse
import base64
import importlib.util
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
import stat
import zipfile
import xml.etree.ElementTree as ET
import unittest

from browser_mcp import MCP, ToolError, text
from workstation_contracts import WorkstationContracts

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--installed-tools', action='store_true', help='Also exercise real Codex plugin registration in a disposable configuration on a prepared VM.')
parser.add_argument('--output', type=Path, help='New or empty artifact directory; defaults to a private directory under /tmp.')
OPTIONS = parser.parse_args()
OUTPUT = OPTIONS.output.resolve() if OPTIONS.output else Path(tempfile.mkdtemp(prefix='ws-regressions-'))
OUTPUT.mkdir(mode=0o700, parents=True, exist_ok=True)
if any(OUTPUT.iterdir()):
    parser.error('--output must be a new or empty directory')
print(f'Artifacts: {OUTPUT}', flush=True)


class Regressions(WorkstationContracts, unittest.TestCase):
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

    def load_source(self, relative, name):
        spec = importlib.util.spec_from_file_location(name, ROOT / relative)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def merge_settings(self, path, defaults, *flags, success=True):
        result = subprocess.run([sys.executable, str(ROOT / 'ansible/roles/vscode/files/merge-settings.py'),
                                 str(path), str(defaults), *flags], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_remote_settings_jsonc_merge_backup_and_idempotency(self):
        path, defaults = self.home / 'settings.json', self.base / 'defaults.json'
        original = '{/* comment */"editor":{"fontSize":17},"url":"https://example.invalid/a//b","quoted":"/* literal */,}","items":[1,2,],}'
        path.write_text(original)
        defaults.write_text('{"editor":{"fontSize":14,"tabSize":4},"items":[3],"newSetting":true}')
        self.assertEqual(self.merge_settings(path, defaults, '--check').stdout.strip(), 'changed')
        self.assertEqual(path.read_text(), original)
        self.assertFalse(path.with_name('settings.json.workstation.bak').exists())
        self.merge_settings(path, defaults)
        expected = {'editor': {'fontSize': 17, 'tabSize': 4}, 'url': 'https://example.invalid/a//b',
                    'quoted': '/* literal */,}', 'items': [1, 2], 'newSetting': True}
        self.assertEqual(json.loads(path.read_text()), expected)
        backup = path.with_name('settings.json.workstation.bak')
        self.assertEqual(backup.read_text(), original)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(self.merge_settings(path, defaults).stdout.strip(), 'unchanged')
        self.assertEqual(backup.read_text(), original)

    def test_remote_settings_reject_bad_json_and_linked_ancestors(self):
        path, defaults = self.home / 'settings.json', self.base / 'defaults.json'
        defaults.write_text('{"added":true}')
        for bad in ['[]', 'null', '{"unfinished":']:
            path.write_text(bad)
            self.merge_settings(path, defaults, success=False)
            self.assertEqual(path.read_text(), bad)
            self.assertFalse(path.with_name('settings.json.workstation.bak').exists())
        target = self.base / 'outside'
        target.mkdir()
        untouched = target / 'settings.json'
        untouched.write_text('{"retained":true}')
        link = self.home / 'linked'
        link.symlink_to(target, target_is_directory=True)
        self.merge_settings(link / 'settings.json', defaults, success=False)
        self.assertEqual(untouched.read_text(), '{"retained":true}')
        self.assertEqual(sorted(p.name for p in target.iterdir()), ['settings.json'])
        path.unlink()
        path.symlink_to(untouched)
        self.merge_settings(path, defaults, success=False)
        self.assertEqual(untouched.read_text(), '{"retained":true}')

    def test_bootstrap_archive_rejects_escape_links_and_private_variables(self):
        runner = self.load_source('host/windows/hyperv/ubuntu-26-04/configure-workstation.py', 'archive_bootstrap')
        cases = [('../escaped.txt', None), ('/absolute.txt', None), ('ansible/../../escaped.txt', None),
                 ('ansible\\linked', None), ('ansible/host_vars/localhost.yml', None), ('unrelated/file', None),
                 ('ansible/link', stat.S_IFLNK | 0o777)]
        for index, (name, mode) in enumerate(cases):
            with self.subTest(name=name):
                archive, destination = self.base / f'bad-{index}.zip', self.base / f'unpack-{index}'
                destination.mkdir()
                entry = zipfile.ZipInfo(name)
                if mode:
                    entry.create_system = 3
                    entry.external_attr = mode << 16
                with zipfile.ZipFile(archive, 'w') as output:
                    output.writestr(entry, 'synthetic untrusted archive member')
                with self.assertRaises(RuntimeError):
                    runner.unpack(archive, destination)
                self.assertEqual(list(destination.iterdir()), [])
        self.assertFalse((self.base / 'escaped.txt').exists())

    def test_bootstrap_archive_extracts_only_declared_sources(self):
        runner = self.load_source('host/windows/hyperv/ubuntu-26-04/configure-workstation.py', 'valid_bootstrap')
        archive, destination = self.base / 'source.zip', self.base / 'unpacked'
        destination.mkdir()
        members = {'ansible/site.yml': '---\n', 'dotfiles/example.txt': 'fixture',
                   'ansible.cfg': '[defaults]\n', 'configure-workstation.py': '# fixture'}
        with zipfile.ZipFile(archive, 'w') as output:
            for name, content in members.items():
                output.writestr(name, content)
        runner.unpack(archive, destination)
        self.assertEqual({str(p.relative_to(destination)): p.read_text() for p in destination.rglob('*') if p.is_file()}, members)

    def test_static_appearance_catalog_has_only_local_passive_assets(self):
        root = ROOT / 'host/windows/vscode/appearance'
        manifest = json.loads((root / 'package.json').read_text())
        forbidden = {'main', 'browser', 'scripts', 'dependencies', 'extensionDependencies', 'extensionPack', 'activationEvents'}
        self.assertFalse(forbidden & manifest.keys())
        self.assertEqual(manifest['extensionKind'], ['ui'])
        def asset(parent, relative):
            self.assertFalse(Path(relative).is_absolute())
            self.assertNotIn('..', Path(relative).parts)
            path = (parent / relative).resolve()
            self.assertTrue(path.is_relative_to(root))
            self.assertTrue(path.is_file(), str(path))
            self.assertFalse(path.is_symlink())
            return path
        themes = manifest['contributes']['themes']
        self.assertEqual({theme['uiTheme'] for theme in themes}, {'vs', 'vs-dark'})
        for theme in themes:
            value = json.loads(asset(root, theme['path']).read_text())
            self.assertTrue(value['colors'])
            self.assertTrue(value['tokenColors'])
        for theme in manifest['contributes']['iconThemes']:
            path = asset(root, theme['path'])
            data = json.loads(path.read_text())
            definitions = data['iconDefinitions']
            for value in definitions.values():
                if value.get('iconPath'):
                    ET.parse(asset(path.parent, value['iconPath']))
            def references(value):
                for key, child in value.items():
                    if key == 'iconDefinitions':
                        continue
                    if isinstance(child, dict):
                        references(child)
                    elif isinstance(child, str):
                        self.assertIn(child, definitions)
            references({key: value for key, value in data.items() if key not in {'fonts', 'hidesExplorerArrows', 'showLanguageModeIcons'}})
        for path in root.rglob('*'):
            self.assertFalse(path.is_symlink())
            if path.is_file():
                self.assertIn(path.suffix.lower(), {'.json', '.svg', '.png', '.txt'})

    def test_runtime_selection(self):
        config = self.home / '.config/mise'
        config.mkdir(parents=True)
        for languages in [[], ['node', 'python'], ['php'], ['node', 'python', 'go', 'bun', 'php']]:
            with self.subTest(languages=languages):
                values = {
                    'workstation_languages': languages,
                    'mise_config_dir': str(config),
                    'mise_config_src': str(ROOT / 'dotfiles/mise/config.toml'),
                }
                self.apply('mise', values, tags='mise_config')
                tools = tomllib.loads((config / 'config.toml').read_text())['tools']
                self.assertEqual(set(tools) & {'node', 'python', 'go', 'bun', 'php'}, set(languages))
                self.assertTrue({'uv', 'ruff', 'aqua:cli/cli', 'aqua:BurntSushi/ripgrep'} <= set(tools))
                self.apply('mise', values, tags='mise_config', unchanged=True)

    def test_workstation_component_scope(self):
        path = ROOT / 'host/windows/hyperv/ubuntu-26-04/configure-workstation.py'
        spec = importlib.util.spec_from_file_location('workstation_bootstrap', path)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        base = {'git_user_name': 'Fixture', 'git_user_email': 'fixture@example.invalid'}
        core_tags = {'base', 'security', 'shell', 'git', 'mise', 'cli_tools'}
        cases = [
            ([], [], set()),
            (['php'], [], set()),
            ([], ['browser'], {'chrome'}),
            (['node', 'python'], ['codex', 'browser'], {'codex', 'chrome'}),
            (['node', 'python'], ['codex'], {'codex'}),
            ([], ['graphify'], {'graphify'}),
            (['node', 'python', 'go', 'bun', 'php'],
             ['codex', 'docker', 'vscode', 'browser', 'graphify'],
             {'codex', 'docker', 'vscode', 'chrome', 'graphify'}),
        ]
        for languages, components, optional_tags in cases:
            with self.subTest(languages=languages, components=components):
                encoded = base64.b64encode(json.dumps({**base, 'languages': languages, 'components': components}).encode())
                settings, tags = runner.read_configuration(encoded)
                self.assertEqual(settings['workstation_languages'], languages)
                self.assertEqual(set(tags), core_tags | optional_tags)
                self.assertEqual(len(tags), len(set(tags)))
                self.assertEqual(settings['agent_tools_browser_enabled'], 'browser' in components)
                self.assertNotIn('components', settings)
        for overrides in [
            {'languages': ['unknown']}, {'languages': 'python'}, {'components': ['unknown']},
            {'components': 'codex'}, {'components': ['codex'], 'languages': ['node']},
            {'components': ['audit']}, {'components': ['markitdown'], 'languages': ['python']}, {'unexpected': True},
        ]:
            with self.subTest(invalid=overrides):
                payload = {**base, 'languages': [], 'components': [], **overrides}
                with self.assertRaises(RuntimeError):
                    runner.read_configuration(base64.b64encode(json.dumps(payload).encode()))

    def test_chrome_architecture_guard(self):
        values = {'ansible_facts': {'architecture': 'aarch64'},
                  'agent_tools_browser_chrome_dir': str(self.home / 'chrome')}
        self.apply('agent_tools', values, tags='chrome')
        self.assertFalse((self.home / 'chrome').exists())
        failed = self.apply('agent_tools', {**values, 'agent_tools_browser_enabled': True},
                            tags='chrome', success=False)
        self.assertIn('available only on x86_64', failed.stdout)
        self.assertFalse((self.home / 'chrome').exists())

    def test_mcp_rejects_callbacks_and_tool_errors_and_recovers_after_timeout(self):
        client = MCP(self.base / 'protocol-peer', {'command': sys.executable,
                     'args': [str(ROOT / 'tests/fixtures/mcp_peer.py')]}, 'http://127.0.0.1:1/*')
        try:
            self.assertEqual(client.request('fixture/callback', {}), {'callback_rejected': True})
            self.assertEqual(client.request('fixture/roots', {}), {'roots': [
                {'uri': client.output.resolve().as_uri(), 'name': 'Workstation task artifacts'}]})
            with self.assertRaisesRegex(ToolError, 'Known fixture tool failure'):
                client.tool('reject')
            with self.assertRaises(TimeoutError):
                client.request('fixture/no-response', {}, timeout=.1)
            self.assertEqual(text(client.tool('recover')), 'Fixture recovered')
        finally:
            cleanup = client.close()
        self.assertEqual(cleanup['exit_code'], 0)
        self.assertEqual(cleanup['before_forced_cleanup'], [])
        self.assertEqual(cleanup['remaining_owned_pids'], [])

    def test_mcp_early_exit_cleanup(self):
        client = MCP(self.base / 'exited-mcp',
                     {'command': sys.executable, 'args': ['-c', 'raise SystemExit(23)']},
                     'http://127.0.0.1:1/*')
        try:
            self.assertEqual(client.process.wait(timeout=5), 23)
            with self.assertRaises(BrokenPipeError):
                client.send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}})
        finally:
            cleanup = client.close()
        self.assertEqual(cleanup['exit_code'], 23)
        self.assertEqual(cleanup['before_forced_cleanup'], [])
        self.assertEqual(cleanup['remaining_owned_pids'], [])
        self.assertTrue(cleanup['reader_stopped'])
        self.assertTrue(cleanup['sampler_stopped'])

    def test_codex_browser_configuration(self):
        config = self.base / 'codex'
        config.mkdir()
        chrome = self.base / 'managed chrome'
        values = {'codex_config_dir': str(config), 'codex_config_src': str(ROOT / 'dotfiles/codex/config.toml'), 'agent_tools_browser_chrome_dir': str(chrome)}
        self.apply('codex', values, tags='codex_config')
        self.apply('codex', values, tags='codex_config', unchanged=True)
        data = tomllib.loads((config / 'config.toml').read_text())
        server = data['mcp_servers']['chrome_devtools']
        self.assertEqual(server['enabled'], platform.machine() == 'x86_64')
        self.assertIn('--headless', server['args'])
        self.assertIn('--isolated', server['args'])
        self.assertIn('--page-id-routing', server['args'])
        self.assertFalse(server['required'])
        self.assertIn(f'--executablePath={chrome}/chrome-linux64/chrome', server['args'])
        self.assertIn('--no-usage-statistics', server['args'])
        self.assertIn('--no-performance-crux', server['args'])
        self.assertEqual(set(data['mcp_servers']), {'context7', 'chrome_devtools'})
        for enabled in [False, True]:
            self.apply('codex', {**values, 'agent_tools_browser_enabled': enabled}, tags='codex_config')
            rendered = tomllib.loads((config / 'config.toml').read_text())
            self.assertEqual(rendered['mcp_servers']['chrome_devtools']['enabled'], enabled)
            self.apply('codex', {**values, 'agent_tools_browser_enabled': enabled}, tags='codex_config', unchanged=True)

        # A custom source owns its marketplace table; provisioning must not append another.
        custom = self.base / 'custom-codex.toml'
        contents = 'model = "fixture"\n[marketplaces.drawio]\nsource_type = "git"\nsource = "https://example.invalid/reviewed.git"\nref = "reviewed"\n'
        custom.write_text(contents)
        self.apply('codex', {**values, 'codex_config_src': str(custom)}, tags='codex_config')
        self.assertEqual((config / 'config.toml').read_text(), contents)
        self.assertEqual(tomllib.loads((config / 'config.toml').read_text())['marketplaces']['drawio']['ref'], 'reviewed')

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



if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Regressions))
    (OUTPUT / 'result.json').write_text(json.dumps({'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'skipped': len(result.skipped)}, indent=2))
    print(f'Artifacts retained: {OUTPUT}', flush=True)
    sys.exit(not result.wasSuccessful())
