#!/bin/sh
set -eu

bootstrap_id=$1
revision=$2
payload="$HOME/.local/state/workstation-bootstrap/$bootstrap_id"
repo="$HOME/projects/workstation"

# The guest marker comes from the installer, not from the SSH upload.
[ "$(cat /etc/workstation-bootstrap-id)" = "$bootstrap_id" ] || {
    echo 'This guest does not belong to the requested workstation installation.' >&2
    exit 1
}
exec 9>"$payload/provision.lock"
flock -n 9 || { echo 'Another provisioning process is still running in this VM.' >&2; exit 1; }
if [ -f "$payload/complete" ] && [ "$(cat "$payload/complete")" = "$revision" ]; then
    echo "Workstation installation already completed ($revision)."
    exit 0
fi
sudo cloud-init status --wait
mkdir -p "$HOME/projects"
if [ ! -e "$repo" ]; then
    # A failed clone stays separate from the user's working repository.
    staging=$(mktemp -d "$HOME/projects/.workstation-clone.XXXXXX")
    trap 'rm -rf "$staging"' EXIT HUP INT TERM
    git clone "$payload/workstation.bundle" "$staging"
    mv "$staging" "$repo"
    trap - EXIT HUP INT TERM
fi
cd "$repo"
[ "$(git rev-parse HEAD)" = "$revision" ] && [ -z "$(git status --porcelain --untracked-files=no)" ] || {
    echo 'Workstation checkout has changed. Preserve your work and finish provisioning manually.' >&2
    exit 1
}
git remote set-url origin https://github.com/alikayar/workstation.git
if [ -e ansible/host_vars/localhost.yml ]; then
    cmp -s "$payload/workstation-vars.json" ansible/host_vars/localhost.yml || {
        echo 'Local Ansible variables have changed; finish provisioning manually.' >&2
        exit 1
    }
else
    install -m 600 "$payload/workstation-vars.json" ansible/host_vars/localhost.yml
fi
ansible-playbook ansible/site.yml
# Remove only our temporary bootstrap key; preserve other authorized keys.
python3 - "$payload/bootstrap-key.pub" <<'PY'
import os
import pathlib
import sys
import tempfile
key = pathlib.Path(sys.argv[1]).read_text().split()[:2]
authorized = pathlib.Path.home() / '.ssh/authorized_keys'
lines = authorized.read_text().splitlines()
kept = [line for line in lines if line.split()[:2] != key]
if kept != lines:
    descriptor, name = tempfile.mkstemp(prefix='.workstation-keys-', dir=authorized.parent)
    temporary = pathlib.Path(name)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write('\n'.join(kept) + '\n')
        temporary.replace(authorized)
    finally:
        temporary.unlink(missing_ok=True)
PY
printf '%s\n' "$revision" > "$payload/complete.tmp"
mv "$payload/complete.tmp" "$payload/complete"
echo "Workstation installation completed ($revision)."
