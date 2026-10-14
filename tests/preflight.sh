#!/usr/bin/env bash
# This test provisions only a disposable Docker container, never a workstation.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install --yes --no-install-recommends ansible-core sudo >/dev/null
useradd --create-home --groups sudo --shell /bin/bash workstation-test
# Copy only public test inputs; host checkout permissions need not grant this user access.
install -d -m 755 /tmp/workstation-preflight/{tests,ansible/tasks,ansible/group_vars}
install -m 644 /workstation/tests/preflight.yml /tmp/workstation-preflight/tests/
install -m 644 /workstation/ansible/tasks/preflight.yml /tmp/workstation-preflight/ansible/tasks/
install -m 644 /workstation/ansible/group_vars/all.yml /tmp/workstation-preflight/ansible/group_vars/
# A public, disposable test password exercises prompt detection; no real credentials are used.
printf 'workstation-test:container-test-only\n' | chpasswd
if test -x /usr/bin/sudo.ws; then
  selected_sudo=/usr/bin/sudo.ws
else
  selected_sudo=sudo
fi
ln -s "$(command -v "$selected_sudo")" /usr/local/bin/workstation-test-sudo
run_test() {
  su --login workstation-test --command "cd /tmp/workstation-preflight && ansible-playbook -i localhost, tests/preflight.yml -e ansible_become_password=container-test-only $*"
}
run_test "-e expected_become_exe=$selected_sudo"
run_test "--check --tags shell -e expected_become_exe=$selected_sudo"
run_test '-e ansible_become_exe=/usr/local/bin/workstation-test-sudo -e expected_become_exe=/usr/local/bin/workstation-test-sudo'
su --login workstation-test --command 'cd /tmp/workstation-preflight && ANSIBLE_BECOME_EXE=/usr/local/bin/workstation-test-sudo ansible-playbook -i localhost, tests/preflight.yml -e ansible_become_password=container-test-only -e expected_become_exe=/usr/local/bin/workstation-test-sudo'
# Removing the optional classic binary must retain the ordinary sudo default.
if test -x /usr/bin/sudo.ws; then
  mv /usr/bin/sudo.ws /usr/bin/sudo.ws-test-backup
  run_test '--skip-tags probe -e expected_become_exe=sudo'
fi
