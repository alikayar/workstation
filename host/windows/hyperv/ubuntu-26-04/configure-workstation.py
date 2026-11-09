#!/usr/bin/env python3
"""Apply the uploaded Workstation source as the Ubuntu development user."""
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import resource
import stat
import subprocess
import sys
import tempfile
import zipfile


def unpack(bundle, destination):
    with zipfile.ZipFile(bundle) as archive:
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if (not name.parts or name.is_absolute() or ".." in name.parts or "\\" in entry.filename
                    or stat.S_ISLNK(entry.external_attr >> 16)):
                raise RuntimeError("Unsafe source archive entry")
            if not (entry.filename in ("ansible.cfg", "configure-workstation.py")
                    or name.parts[0] in ("ansible", "dotfiles")):
                raise RuntimeError("Unexpected source archive entry")
            if name == PurePosixPath("ansible/host_vars/localhost.yml"):
                raise RuntimeError("Local host variables must not be bundled")
            target = destination.joinpath(*name.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))


def sudo(password, *command):
    subprocess.run(
        ["sudo", "-k", "-S", "-p", "", "--", *command],
        input=password + b"\n", check=True,
    )


def apply(bundle, expected_hash, installation_id, encoded_settings):
    if os.geteuid() == 0:
        raise RuntimeError("Run Workstation as the development user, not root")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    if Path("/etc/workstation-bootstrap-id").read_text().strip() != installation_id:
        raise RuntimeError("Guest installation identity differs")
    if hashlib.sha256(bundle.read_bytes()).hexdigest() != expected_hash:
        raise RuntimeError("Uploaded Workstation source hash differs")
    settings = json.loads(base64.b64decode(encoded_settings))
    if set(settings) != {"git_user_name", "git_user_email"}:
        raise RuntimeError("Unexpected configuration settings")
    if not all(isinstance(value, str) and value.strip() for value in settings.values()):
        raise RuntimeError("Git identity is required")
    # Keep each run separate from user repositories and earlier interrupted runs.
    parent = Path.home() / ".local/share/workstation/provision"
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=parent) as temporary:
        source = Path(temporary)
        unpack(bundle, source)
        variables = source / "wvm-vars.json"
        variables.write_text(json.dumps(settings), encoding="utf-8")
        password = getpass.getpass("Ubuntu sudo password for Workstation: ").encode()
        try:
            sudo(password, "/usr/bin/true")
            sudo(password, "/usr/bin/apt-get", "update")
            sudo(password, "/usr/bin/env", "DEBIAN_FRONTEND=noninteractive",
                 "/usr/bin/apt-get", "install", "--yes",
                 "ansible-core", "python3-debian", "sudo")
            environment = os.environ.copy()
            environment["ANSIBLE_CONFIG"] = str(source / "ansible.cfg")
            # Ansible's "-" password source reads stdin; no password file or argv value.
            subprocess.run(
                ["ansible-playbook", "ansible/site.yml",
                 "--become-password-file", "-", "--extra-vars", f"@{variables}"],
                cwd=source, env=environment, input=password + b"\n", check=True,
            )
        finally:
            password = None
            subprocess.run(["sudo", "-k"], check=False)


if __name__ == "__main__":
    try:
        apply(Path(sys.argv[1]), *sys.argv[2:])
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Workstation configuration failed: {error}", file=sys.stderr)
        sys.exit(1)
