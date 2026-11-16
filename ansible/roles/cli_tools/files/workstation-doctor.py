#!/usr/bin/python3
# Workstation managed workstation-doctor v1
"""Read-only Ubuntu diagnostics; no credentials, config contents, repairs or installs."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys


def command(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=5,
                                env={**os.environ, 'MISE_AUTO_INSTALL': '0'})
        return result.returncode, result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None, ''


def diagnose(required, runtimes=(), chrome=None):
    findings = []
    def add(status, check, detail):
        findings.append({'status': status, 'check': check, 'detail': detail})
    for name in sorted(set(required)):
        resolved = shutil.which(name)
        add('OK' if resolved else 'WARN', 'command:' + name, resolved or 'Not found on this project PATH')
    rc, shell = command(['getent', 'passwd', str(os.getuid())])
    add('OK' if rc == 0 else 'UNKNOWN', 'login-shell', shell.rsplit(':', 1)[-1] if rc == 0 else 'Account metadata unavailable')
    for name in runtimes:
        rc, runtime = command(['mise', 'which', name])
        add('OK' if rc == 0 else 'UNKNOWN', 'project-' + name, runtime if rc == 0 else 'No installed runtime selected or mise unavailable; no installation attempted')
    if chrome is not None:
        available = chrome.is_file() and os.access(chrome, os.X_OK)
        add('OK' if available else 'WARN', 'chrome-executable', str(chrome) if available else 'Requested Chrome executable unavailable; no browser was started')
    rc, manager = command(['systemctl', '--user', 'show', '--property=Version', '--value'])
    add('OK' if rc == 0 else 'UNKNOWN', 'user-service-manager', manager if rc == 0 else 'User bus/manager unavailable; no startup or linger change attempted')
    rc, apparmor = command(['systemctl', 'is-active', 'apparmor'])
    add('OK' if rc == 0 else 'UNKNOWN', 'apparmor-service', apparmor if rc == 0 else 'Service not reported active; this does not inspect browser sandbox enforcement')
    disk = shutil.disk_usage(Path.cwd())
    add('WARN' if disk.free < 2 * 1024**3 else 'OK', 'project-disk', {'free_bytes': disk.free, 'total_bytes': disk.total})
    try:
        available = next(int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:'))
        add('WARN' if available < 512 * 1024**2 else 'OK', 'memory', {'available_bytes': available})
    except (OSError, StopIteration, ValueError):
        add('UNKNOWN', 'memory', 'MemAvailable unavailable')
    docker = Path('/var/run/docker.sock')
    if docker.is_socket():
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(.5)
                connection.connect(str(docker))
            add('OK', 'local-docker-socket', 'Local socket connect succeeded; no API request or container operation sent')
        except OSError:
            add('UNKNOWN', 'local-docker-socket', 'Local socket unavailable to this user')
    else:
        add('UNKNOWN', 'local-docker-socket', 'No local system socket; rootless/remote Docker is not inspected')
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require', nargs='+', default=['git', 'mise', 'curl', 'python3', 'rg', 'workstation-service'],
                        help='Commands expected for this task; omitted components need not be required')
    parser.add_argument('--runtime', action='append', choices=['node','python','go','bun','php'], default=[], help='Inspect selected project runtime without installing')
    parser.add_argument('--chrome', type=Path, help='Inspect an explicitly supplied managed Chrome executable without launching it')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    findings = diagnose(args.require, args.runtime, args.chrome)
    if args.json:
        print(json.dumps({'directory': str(Path.cwd()), 'findings': findings}, indent=2))
    else:
        for item in findings:
            print(f"{item['status']:7} {item['check']}: {item['detail']}")
    return 1 if any(item['status'] == 'WARN' for item in findings) else (2 if any(item['status'] == 'UNKNOWN' for item in findings) else 0)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f'workstation-doctor: {error}', file=sys.stderr)
        raise SystemExit(2)
