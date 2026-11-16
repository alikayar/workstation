#!/usr/bin/python3
# Workstation managed workstation-service v1
"""Manage only explicitly named Workstation task services in the user manager."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

PROPERTIES = ['Id', 'LoadState', 'ActiveState', 'SubState', 'Description', 'WorkingDirectory',
              'MainPID', 'Result', 'ExecMainStatus', 'MemoryMax', 'CPUQuotaPerSecUSec', 'RuntimeMaxUSec']


def run(argv, *, check=True):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    if check and result.returncode:
        # Do not echo command lines or arbitrary service payloads on startup failure.
        raise ValueError(f'{Path(argv[0]).name} failed (exit {result.returncode}); user manager may be unavailable')
    return result


def inspect(unit):
    result = run(['systemctl', '--user', 'show', unit, '--property=' + ','.join(PROPERTIES)], check=False)
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if properties.get('LoadState') == 'not-found':
        return None
    if result.returncode or not properties.get('LoadState'):
        raise ValueError('Cannot inspect the user service manager; no operation was attempted')
    return properties


def owned(properties, task, directory):
    if properties.get('Description') != f'Workstation task {task}' or properties.get('WorkingDirectory') != str(directory):
        raise ValueError('Service ownership/directory differs; retained without changes')


def memory(value):
    if not re.fullmatch(r'[1-9][0-9]*[MG]', value):
        raise argparse.ArgumentTypeError('Use a positive integer with M or G, for example 512M or 2G')
    amount = int(value[:-1]) * (1024 ** (2 if value[-1] == 'M' else 3))
    if not 64 * 1024**2 <= amount <= 1024**4:
        raise argparse.ArgumentTypeError('Memory must be between 64M and 1024G')
    return value


def bounded_int(low, high):
    def parse(value):
        try:
            value = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError('Expected an integer') from None
        if not low <= value <= high:
            raise argparse.ArgumentTypeError(f'Expected {low}..{high}')
        return value
    return parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for action in ('start', 'status', 'logs', 'stop'):
        command = commands.add_parser(action)
        command.add_argument('--task', required=True, help='Unique UUID for this task')
        command.add_argument('--directory', type=Path, default=Path.cwd(), help='Original task working directory')
        if action == 'start':
            command.add_argument('--memory', type=memory, default='2G')
            command.add_argument('--cpu', type=bounded_int(1, 10000), default=100, help='Percent; 100 equals one CPU')
            command.add_argument('--seconds', type=bounded_int(1, 86400), default=3600)
            command.add_argument('command', nargs=argparse.REMAINDER)
        if action == 'logs':
            command.add_argument('--lines', type=bounded_int(1, 1000), default=100)
    args = parser.parse_args()
    try:
        task = str(uuid.UUID(args.task))
    except ValueError:
        parser.error('--task must be a UUID')
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir():
        parser.error('--directory must be a directory')
    unit = f'workstation-task-{task}.service'
    # A manager read is the prerequisite; never start a bus or enable lingering.
    run(['systemctl', '--user', 'show', '--property=Version', '--value'])
    properties = inspect(unit)
    if args.action == 'start':
        if properties is not None:
            raise ValueError('Task unit already exists; inspect/stop the original task or choose a new UUID')
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('Supply a foreground command after --')
        executable = command[0]
        if '/' in executable:
            executable = str((directory / executable).resolve()) if not Path(executable).is_absolute() else executable
        else:
            executable = shutil.which(executable)
        if not executable or not Path(executable).is_file():
            raise ValueError('Task executable was not found; inspect command resolution')
        run(['systemd-run', '--user', '--quiet', '--expand-environment=no', '--unit=' + unit,
             '--description=Workstation task ' + task, '--working-directory=' + str(directory),
             '--property=Type=exec', '--property=KillMode=control-group',
             '--property=RemainAfterExit=yes', '--property=MemoryMax=' + args.memory,
             '--property=CPUQuota=' + str(args.cpu) + '%', '--property=RuntimeMaxSec=' + str(args.seconds),
             '--', executable, *command[1:]])
        properties = inspect(unit)
        if properties is None:
            raise ValueError('Task unit disappeared after launch; startup is unverified')
        owned(properties, task, directory)
        if properties['ActiveState'] == 'failed':
            raise ValueError('Task failed immediately; inspect status and its task-owned logs')
        print(json.dumps(properties, indent=2))
        return
    if properties is None:
        raise ValueError('Task unit is not loaded; no operation was attempted')
    owned(properties, task, directory)
    if args.action == 'status':
        print(json.dumps(properties, indent=2))
    elif args.action == 'logs':
        result = run(['journalctl', '--user', '--unit=' + unit, '--lines=' + str(args.lines), '--no-pager'])
        print(result.stdout, end='')
    else:
        run(['systemctl', '--user', 'stop', unit])
        print(json.dumps({'unit': unit, 'stopped': True}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'workstation-service: {error}', file=sys.stderr)
        raise SystemExit(1)
