#!/usr/bin/env python3
"""Explicit loopback browser/tool smoke check on a prepared Workstation VM."""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time


def process_table():
    processes = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                processes[int(entry.name)] = (int(fields[1]), fields[19], fields[0])
            except (OSError, IndexError, ValueError):
                pass
    return processes


def run(command, output, name, env=None):
    owned = {}
    with (output / f'{name}.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        started = time.monotonic()
        try:
            while process.poll() is None:
                table = process_table()
                known = {process.pid, *owned}
                for _ in range(8):
                    extra = {pid for pid, row in table.items() if row[0] in known} - known
                    if not extra:
                        break
                    known.update(extra)
                owned.update({pid: table[pid][1] for pid in known if pid in table})
                if time.monotonic() - started > 180:
                    raise TimeoutError(name)
                time.sleep(.05)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            deadline = time.monotonic() + 5
            while True:
                table = process_table()
                remaining = [pid for pid, stamp in owned.items() if pid in table and table[pid][1] == stamp and table[pid][2] != 'Z']
                if not remaining or time.monotonic() >= deadline:
                    break
                time.sleep(.1)
            for pid in remaining:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if remaining:
                raise RuntimeError(f'{name}: owned processes leaked: {remaining}; see {output}')
    if process.returncode:
        raise RuntimeError(f'{name}: exit {process.returncode}; see {output / (name + ".log")}')


def agent_child(url, output):
    commands = [['open', url], ['snapshot', '-i'], ['click', '#publish'], ['wait', '#status', '--state=visible'], ['get', 'text', '#status'], ['screenshot', str(output / 'published.png')]]
    for command in commands:
        result = subprocess.run(['agent-browser', *command], capture_output=True, text=True, timeout=45)
        print(json.dumps({'command': command, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}), flush=True)
        if result.returncode:
            raise RuntimeError(command)
        if command[:2] == ['get', 'text'] and 'Published successfully' not in result.stdout:
            raise RuntimeError('Publish action did not update the page')
    print('Session closed by workstation-browser-task on exit', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New or empty private artifact directory.')
    parser.add_argument('--agent-child', metavar='URL', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.agent_child:
        agent_child(args.agent_child, args.output)
        return
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='ws-smoke-'))
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output must be new or empty')
    print(f'Artifacts: {output}', flush=True)
    html = b'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Workstation browser check</title><meta name="description" content="A local fixture for checking publishing and browser tool ownership."><link rel="icon" href="data:,"><style>body{font:18px system-ui;max-width:720px;margin:60px auto;padding:24px;background:#f5f7f5;color:#17372b}button{padding:12px 24px}a{display:block;margin-top:24px}</style></head><body><main><h1>Publish a guide</h1><p>This page exists only for the local Workstation smoke check.</p><button id="publish" onclick="document.querySelector('#status').hidden=false">Publish</button><p id="status" role="status" hidden>Published successfully</p><a href="/broken">Deliberately broken internal link</a></main></body></html>'''

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/':
                status, content, kind = 200, html, 'text/html; charset=utf-8'
            elif self.path == '/robots.txt':
                status, content, kind = 200, b'User-agent: *\nAllow: /\n', 'text/plain'
            else:
                status, content, kind = 404, b'Page not found', 'text/plain'
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.end_headers()
            self.wfile.write(content)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/'
    result = {'url': url, 'checks': [], 'complete': False}
    try:
        run(['workstation-browser-task', sys.executable, str(Path(__file__).resolve()), '--agent-child', url, '--output', str(output)], output, 'agent-browser')
        result['checks'].append('agent-browser publish/wait/screenshot and task cleanup')
        run(['lighthouse', url, '--chrome-flags=--headless', '--no-enable-error-reporting', '--output=json', '--output=html', '--output-path=' + str(output / 'page'), '--save-assets', '--preset=desktop'], output, 'lighthouse')
        report = json.loads((output / 'page.report.json').read_text())
        if report.get('runtimeError') or any(report['audits'][name]['score'] != 1 for name in ['document-title', 'meta-description', 'button-name']):
            raise RuntimeError('Lighthouse normal-page checks failed')
        result['checks'].append('Lighthouse normal page, native JSON/HTML/assets and cleanup')
        run(['siteone-crawler', '--config-file=/dev/null', '--url=' + url, '--workers=1', '--max-reqs-per-sec=1', '--max-visited-urls=10', '--max-queue-length=20', '--max-depth=2', '--no-cache', '--output-json-file=' + str(output / 'crawl.json'), '--output-html-report=' + str(output / 'crawl.html'), '--output-text-file=' + str(output / 'crawl.txt')], output, 'siteone')
        crawl = json.loads((output / 'crawl.json').read_text())
        if not any(page['url'] == url + 'broken' and page['status'] == '404' for page in crawl['results']):
            raise RuntimeError('SiteOne did not find the known broken link')
        result['checks'].append('SiteOne known broken link and native reports')
        result['complete'] = True
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        result['server_stopped'] = not thread.is_alive()
        (output / 'result.json').write_text(json.dumps(result, indent=2))
        print(f'Artifacts retained: {output}', flush=True)
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
