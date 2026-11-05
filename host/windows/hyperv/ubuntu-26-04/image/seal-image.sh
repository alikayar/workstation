#!/bin/sh
# Runs only in the isolated Packer builder, over its pinned temporary SSH session.
set -eu
set +x
image=$1
token=$2
user=$3
case "$image:$token:$user" in *[!a-z0-9:]*) exit 20;; esac
[ "$user" = wvmimage ] || exit 20
[ "$(cat /etc/workstation-bootstrap-id)" = "$token" ] || exit 20
cloud-init status --wait >/dev/null
passwd -l root >/dev/null
rm -f /etc/sudoers.d/90-workstation /etc/sudoers.d/91-workstation-admin
# Delete the builder identity; the already-authenticated root session can finish sealing.
userdel --force --remove "$user"
rm -f /etc/ssh/ssh_host_* /etc/ssh/sshd_config.d/00-workstation.conf
rm -f /etc/workstation-bootstrap-id /var/lib/workstation/account-ready
rm -rf /var/log/installer
rm -f /etc/cloud/cloud-init.disabled /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -f /etc/netplan/*.yaml
printf 'datasource_list: [ NoCloud ]\n' > /etc/cloud/cloud.cfg.d/99-workstation-datasource.cfg
cloud-init clean --logs --machine-id --seed
case "$(cat /etc/machine-id)" in ''|uninitialized) ;; *) exit 20;; esac
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed /var/lib/dhcp/*.leases /var/lib/systemd/network/*.lease
printf 'localhost\n' > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts
rm -f "$0"
test -z "$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit)"
! getent passwd wvmimage >/dev/null
test ! -e /etc/sudoers.d/90-workstation
sync
printf 'WORKSTATION-IMAGE-SEALED:%s:%s\n' "$image" "$token"
shutdown -P now
