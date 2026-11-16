#!/usr/bin/env python3
"""Explicit Chrome + DevTools MCP checks against a synthetic loopback application."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import tempfile
import sys
import threading
import urllib.parse
import uuid

from browser_mcp import MCP, ROOT, ToolError, render_server, runtime_environment, save, text


class Browser:
    def __init__(self, client):
        self.client, self.owned, self.sequence = client, set(), 0
        self.tracing = None

    def pages(self):
        result = text(self.client.tool('list_pages'))
        found = {int(value) for value in re.findall(r'^\s*(\d+):', result, re.MULTILINE)}
        if not found:
            raise RuntimeError('Unrecognized page-list protocol; inspect mcp.jsonl')
        return found

    def new(self, url, context):
        before = self.pages()
        self.client.tool('new_page', url=url, isolatedContext=context)
        created = self.pages() - before
        self.owned |= created
        if len(created) != 1:
            raise AssertionError(f'Expected exactly one new page, got {created}')
        return created.pop()

    def evaluate(self, page, function):
        self.sequence += 1
        destination = self.client.output / f'evaluate-{self.sequence:03d}.json'
        self.client.tool('evaluate_script', pageId=page, function=function, filePath=str(destination))
        return json.loads(destination.read_text())

    def uid(self, page, role, label):
        snapshot = text(self.client.tool('take_snapshot', pageId=page))
        matches = re.findall(r'uid=(\S+)\s+' + re.escape(role) + r' "' + re.escape(label) + '"', snapshot)
        if len(matches) != 1:
            raise AssertionError(f'Expected one {role} named {label!r}; inspect snapshot in mcp.jsonl')
        return matches[0]

    def wait(self, page, message):
        self.client.tool('wait_for', pageId=page, text=[message], visible=True, timeout=10000)

    def cleanup(self):
        errors = []
        if self.tracing is not None:
            try:
                self.client.tool('performance_stop_trace', pageId=self.tracing)
                self.tracing = None
            except Exception as error:
                errors.append(str(error))
        for page in sorted(self.owned):
            try:
                self.client.tool('close_page', pageId=page)
            except Exception as error:
                errors.append(str(error))
        return {'owned_pages': sorted(self.owned), 'errors': errors,
                'owned_pages_remaining': sorted(self.owned & self.pages())}


def require(value, message):
    if not value:
        raise AssertionError(message)


def expected_tool_error(action):
    try:
        action()
    except ToolError as error:
        return str(error)
    raise AssertionError('Expected a rejected tool call, but it succeeded')


def audit(client, page, output, broken=False):
    output.mkdir(mode=0o700)
    client.tool('lighthouse_audit', pageId=page, mode='navigation', device='desktop', outputDirPath=str(output))
    reports = []
    for path in output.rglob('*.json'):
        value = json.loads(path.read_text())
        if isinstance(value, dict) and 'audits' in value and 'categories' in value:
            reports.append((path, value))
    require(len(reports) == 1, 'Expected one native Lighthouse JSON report')
    path, report = reports[0]
    require(not report.get('runtimeError'), 'Lighthouse runtime error')
    require('performance' not in report['categories'], 'MCP audit unexpectedly changed performance scope')
    require({'accessibility', 'seo', 'best-practices'} <= set(report['categories']), 'Missing audit categories')
    for name in ['document-title', 'meta-description']:
        require(report['audits'][name]['score'] == 1, f'Known valid fixture failed {name}')
    if broken:
        require(report['audits']['image-alt']['score'] == 0, 'Audit missed the deliberately missing image alt')
    else:
        require(report['audits']['image-alt']['score'] == 1, 'Known labelled image failed its audit')
    require(any(output.rglob('*.html')), 'Native HTML audit report missing')
    return {'report': str(path), 'version': report['lighthouseVersion'], 'known_fault_detected': broken}


def exercise(client, url, output, extended):
    browser = Browser(client)
    report = {'checks': [], 'complete': False}
    try:
        initialization, tools = client.initialize()
        report['server'] = initialization['serverInfo']
        expected_version = next(arg.split('@', 1)[1] for arg in json.loads((client.output / 'command.json').read_text())['argv'] if arg.startswith('chrome-devtools-mcp@'))
        require(report['server']['version'] == expected_version, 'Running MCP version differs from the managed package pin')
        required = {'new_page', 'list_pages', 'close_page', 'navigate_page', 'take_snapshot', 'fill', 'click',
                    'wait_for', 'evaluate_script', 'take_screenshot', 'resize_page', 'list_console_messages',
                    'list_network_requests', 'lighthouse_audit', 'performance_start_trace', 'performance_stop_trace'}
        require(required <= tools.keys(), 'Pinned MCP tool contract is incomplete')
        require(not {'install_extension', 'execute_3p_developer_tool', 'execute_webmcp_tool'} & tools.keys(),
                'Unrequested extension/experimental categories exposed')
        report['checks'].append('MCP initialize, tool discovery and disabled extension categories')
        identity = str(uuid.uuid4())
        page = browser.new(url + '?case=' + identity, identity + '-a')
        browser.wait(page, 'Ready to publish')
        report['browser'] = browser.evaluate(page, '() => navigator.userAgent')
        require(browser.evaluate(page, "() => ({local:localStorage.getItem('fixture-owner'), cookie:document.cookie})") == {'local': None, 'cookie': ''}, 'Fresh task context inherited synthetic session state')
        browser.evaluate(page, "() => { localStorage.setItem('fixture-owner', 'A'); document.cookie='fixture_owner=A; SameSite=Strict; path=/'; return true; }")
        other = browser.new(url + '?case=' + identity + '-b', identity + '-b')
        require(browser.evaluate(other, "() => ({local:localStorage.getItem('fixture-owner'), cookie:document.cookie})") == {'local': None, 'cookie': ''},
                'Storage/cookie leaked into another task context')
        require(browser.evaluate(page, "() => localStorage.getItem('fixture-owner')") == 'A', 'Page routing changed the wrong task')
        shared = browser.new(url + '?case=' + identity + '-shared', identity + '-a')
        require(browser.evaluate(shared, "() => ({local:localStorage.getItem('fixture-owner'), cookie:document.cookie})") == {'local': 'A', 'cookie': 'fixture_owner=A'}, 'Same-task context did not share storage/cookie')
        client.tool('close_page', pageId=shared)
        browser.owned.remove(shared)
        require(browser.evaluate(other, '() => document.title') == 'Workstation browser fixture', 'Closing task A affected task B')
        report['checks'].append('Distinct contexts isolate cookies/storage; explicit page routing; same-context sharing')
        title = browser.uid(page, 'textbox', 'Guide title')
        client.tool('fill', pageId=page, uid=title, value='Fixture guide')
        button = browser.uid(page, 'button', 'Publish')
        client.tool('click', pageId=page, uid=button)
        browser.wait(page, 'Published: Fixture guide')
        require(browser.evaluate(page, "async () => await fetch('/api/state?case=" + identity + "').then(r=>r.json())") == {'title': 'Fixture guide', 'writes': 1},
                'User-visible publish did not commit the expected fixture state exactly once')
        client.tool('navigate_page', pageId=page, type='reload')
        browser.wait(page, 'Published: Fixture guide')
        report['checks'].append('Accessible form interaction, server-side state and persistence after reload')
        screenshots = []
        for width, height in [(1280, 800), (390, 844)]:
            client.tool('resize_page', pageId=page, width=width, height=height)
            metrics = browser.evaluate(page, '() => ({width:innerWidth, overflow:document.documentElement.scrollWidth>innerWidth})')
            require(metrics == {'width': width, 'overflow': False}, 'Fixture viewport/layout contract failed')
            path = output / f'published-{width}.png'
            client.tool('take_screenshot', pageId=page, filePath=str(path), format='png')
            data = path.read_bytes()
            require(data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', data[16:24]) == (width, height),
                    'Screenshot is not a PNG of the requested viewport')
            screenshots.append(str(path))
        report['screenshots'] = screenshots
        report['visual_review'] = 'Required separately; image existence/dimensions do not establish visual correctness'
        report['checks'].append('Desktop/mobile viewport, no horizontal overflow and real screenshot artifacts')
        client.tool('performance_start_trace', pageId=page, reload=False, autoStop=False)
        browser.tracing = page
        require(browser.evaluate(page, "async () => { console.error('fixture-console-marker'); return await fetch('/missing').then(r=>r.status); }") == 404, 'Known missing request did not return 404')
        trace = output / 'trace.json'
        client.tool('performance_stop_trace', pageId=page, filePath=str(trace))
        browser.tracing = None
        require(trace.is_file() and trace.stat().st_size > 100, 'Performance trace artifact missing')
        trace_data = json.loads(trace.read_text())
        require(isinstance(trace_data, dict) and bool(trace_data.get('traceEvents')), 'No native trace events')
        require('fixture-console-marker' in text(client.tool('list_console_messages', pageId=page)), 'Known console error not observed')
        require('/missing' in text(client.tool('list_network_requests', pageId=page)), 'Known failed request not observed')
        report['checks'].append('Performance trace start/stop, native events, known console/network failures')
        report['audit'] = audit(client, page, output / 'audit-good')
        report['checks'].append('Native Lighthouse JSON/HTML report and independently expected passing audits')
        if extended:
            report['expected_error'] = expected_tool_error(lambda: client.tool('click', pageId=page, uid='fixture-invalid-uid'))
            report['missing_page_id_error'] = expected_tool_error(lambda: client.tool('take_snapshot'))
            report['wait_timeout_error'] = expected_tool_error(lambda: client.tool('wait_for', pageId=other, text=['fixture-never-present'], visible=True, timeout=500))
            require(any(marker in report['wait_timeout_error'].lower() for marker in ['timeout', 'timed out']), 'Wait failed for a reason other than its declared timeout')
            browser.wait(other, 'Ready to publish')
            require(browser.evaluate(other, '() => document.title') == 'Workstation browser fixture', 'Expected tool error corrupted another task')
            bad = browser.new(url + 'bad?case=' + identity + '-bad', identity + '-bad')
            browser.wait(bad, 'Ready to publish')
            report['bad_audit'] = audit(client, bad, output / 'audit-bad', broken=True)
            failed = browser.new(url + '?case=fail-' + identity, identity + '-fail')
            browser.wait(failed, 'Ready to publish')
            client.tool('fill', pageId=failed, uid=browser.uid(failed, 'textbox', 'Guide title'), value='Rejected guide')
            client.tool('click', pageId=failed, uid=browser.uid(failed, 'button', 'Publish'))
            browser.wait(failed, 'Publish failed')
            require(browser.evaluate(failed, "async () => await fetch('/api/state?case=fail-" + identity + "').then(r=>r.json())") == {'title': '', 'writes': 0},
                    'Failed publish changed fixture state')
            report['checks'].append('Rejected invalid UID/missing pageId, bounded DOM timeout, continued routing, known audit fault and HTTP 500 without writes')
        report['complete'] = True
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
    finally:
        try:
            report['page_cleanup'] = browser.cleanup()
        except Exception as error:
            report['page_cleanup'] = {'error': str(error)}
        save(output / 'checks.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New/empty private artifact directory outside the checkout.')
    parser.add_argument('--battle', action='store_true', help='Add known-fault audits, rejected calls, SIGTERM and fresh-process recovery.')
    parser.add_argument('--prepare-dependencies', action='store_true', help='Explicitly populate the pinned npm package cache; does not run browser checks.')
    args = parser.parse_args()
    if args.prepare_dependencies and args.battle:
        parser.error('Dependency preparation and browser execution are separate commands')
    os.umask(0o077)
    output = args.output.absolute() if args.output else Path(tempfile.mkdtemp(prefix='ws-browser-'))
    if output.resolve() != output or output.is_relative_to(ROOT):
        parser.error('Use an artifact path outside the checkout without linked ancestors')
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output must be new or empty')
    output.chmod(0o700)
    result = {'mode': 'battle' if args.battle else 'smoke', 'complete': False, 'attempts': [], 'python_version': sys.version,
              'source_hashes': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in [Path(__file__), ROOT / 'tests/browser_mcp.py', ROOT / 'tests/fixtures/browser/index.html', ROOT / 'dotfiles/codex/config.toml', ROOT / 'ansible/roles/agent_tools/defaults/main.yml', ROOT / 'ansible/roles/agent_tools/tasks/chrome.yml']}}
    server, thread, httpd = None, None, None
    print(f'Artifacts: {output}', flush=True)
    try:
        server = render_server(output)
        result['launch_configuration'] = server
        chrome = next(arg.split('=', 1)[1] for arg in server['args'] if arg.startswith('--executablePath='))
        version = subprocess.run([chrome, '--version'], capture_output=True, text=True, check=True, timeout=15).stdout.strip()
        require(Path(chrome).parents[1].name in version, 'Chrome binary version differs from its managed directory pin')
        result['chrome_version'] = version
        version_home = output / 'version-home'
        version_home.mkdir(mode=0o700)
        result['node_version'] = subprocess.run(['node', '--version'], env=runtime_environment(version_home),
                                                capture_output=True, text=True, check=True, timeout=15).stdout.strip()
        if args.prepare_dependencies:
            prepare_home = output / 'prepare-home'
            prepare_home.mkdir(mode=0o700)
            with (output / 'prepare.log').open('w') as log:
                process = subprocess.Popen([server['command'], *server['args'], '--version'], cwd=ROOT,
                                           env=runtime_environment(prepare_home, offline=False),
                                           stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=180)
                    require(code == 0, 'Pinned npm package preparation failed; inspect prepare.log')
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=3)
            result.update(mode='dependency-preparation', complete=True)
            return 0
        html = (ROOT / 'tests/fixtures/browser/index.html').read_bytes()
        states, lock = {}, threading.Lock()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                key = urllib.parse.parse_qs(parsed.query).get('case', ['default'])[0]
                if parsed.path == '/api/state':
                    with lock:
                        value = states.get(key, {'title': '', 'writes': 0}).copy()
                    status, body, kind = 200, json.dumps(value).encode(), 'application/json'
                elif parsed.path in ['/', '/bad']:
                    body = html if parsed.path == '/' else html.replace(b'alt="Fixture marker"', b'')
                    status, kind = 200, 'text/html; charset=utf-8'
                elif parsed.path == '/robots.txt':
                    status, body, kind = 200, b'User-agent: *\nAllow: /\n', 'text/plain'
                else:
                    status, body, kind = 404, b'Fixture missing resource', 'text/plain'
                self.reply(status, body, kind)

            def do_POST(self):
                parsed = urllib.parse.urlsplit(self.path)
                key = urllib.parse.parse_qs(parsed.query).get('case', ['default'])[0]
                length = int(self.headers.get('Content-Length', '0'))
                if parsed.path != '/api/publish' or not 0 < length < 4096:
                    self.reply(400, b'Invalid fixture request', 'text/plain')
                    return
                value = json.loads(self.rfile.read(length))
                if key.startswith('fail-'):
                    self.reply(500, b'Injected fixture failure', 'text/plain')
                    return
                if not isinstance(value.get('title'), str) or not value['title'].strip():
                    self.reply(400, b'Missing title', 'text/plain')
                    return
                with lock:
                    old = states.get(key, {'writes': 0})
                    states[key] = {'title': value['title'], 'writes': old['writes'] + 1}
                self.reply(200, b'{}', 'application/json')

            def reply(self, status, body, kind):
                self.send_response(status)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *values):
                pass

        httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{httpd.server_port}/'
        result['fixture_url'] = url
        cycles = ['normal', 'interrupt', 'restart'] if args.battle else ['normal']
        for cycle in cycles:
            print(f'Browser phase: {cycle}', flush=True)
            client = MCP(output / cycle, server, url + '*')
            attempt = {'cycle': cycle}
            result['attempts'].append(attempt)
            try:
                if cycle == 'interrupt':
                    client.initialize()
                    browser = Browser(client)
                    page = browser.new(url, str(uuid.uuid4()))
                    browser.wait(page, 'Ready to publish')
                    # Deliberately leave an owned page and active recording to the signal path.
                    client.tool('performance_start_trace', pageId=page, reload=False, autoStop=False)
                    attempt['fault'] = 'SIGTERM to this test-owned process group with open page/trace'
                    attempt['complete'] = True
                else:
                    attempt.update(exercise(client, url, output / cycle, args.battle and cycle == 'normal'))
                    if cycle == 'restart':
                        attempt['recovery'] = 'Full scenario passed in a new process with fresh profile/contexts'
            finally:
                attempt['cleanup'] = client.close(interrupt=cycle == 'interrupt')
                save(output / 'result.json', result)
            cleanup = attempt['cleanup']
            require(attempt.get('complete'), f'{cycle} workflow failed; see retained checks.json')
            if cycle != 'interrupt':
                page_cleanup = attempt.get('page_cleanup', {})
                require(not page_cleanup.get('errors') and not page_cleanup.get('owned_pages_remaining') and 'error' not in page_cleanup,
                        'Owned page/trace cleanup failed')
                require(cleanup['exit_code'] == 0, 'MCP graceful exit was nonzero')
            require(not cleanup['shutdown_timed_out'] and not cleanup['before_forced_cleanup'] and not cleanup['remaining_owned_pids'] and cleanup['reader_stopped'] and cleanup['sampler_stopped'],
                    'MCP/Chrome leaked or required forced cleanup; see cleanup.json')
        result['complete'] = True
    except (Exception, KeyboardInterrupt) as error:
        result['error'] = f'{type(error).__name__}: {error}'
        return 1
    finally:
        if httpd:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=3)
        result['fixture_server_stopped'] = thread is None or not thread.is_alive()
        if not result['fixture_server_stopped']:
            result['complete'] = False
            result['fixture_cleanup_error'] = 'Loopback fixture thread did not stop'
        save(output / 'result.json', result)
        print(f'Artifacts retained: {output}', flush=True)
    return 0 if result['complete'] else 1


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    def timed_out(signum, frame):
        raise TimeoutError('Whole browser verification exceeded 15 minutes')
    signal.signal(signal.SIGALRM, timed_out)
    signal.setitimer(signal.ITIMER_REAL, 900)
    raise SystemExit(main())
