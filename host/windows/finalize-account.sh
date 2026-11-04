#!/bin/sh
# Invoked over authenticated SSH as root. passwd owns the hidden password prompt.
set -eu
set +x
umask 077
user=$1
id=$2
case "$user" in ''|root|*[!a-z0-9_]*) echo 'Invalid account.' >&2; exit 1;; esac
[ "$(cat /etc/workstation-bootstrap-id)" = "$id" ] || exit 20
directory=/var/lib/workstation
marker="$directory/account-ready"
if [ -f "$marker" ] && [ "$(cat "$marker")" = "$id" ] && [ ! -e /etc/sudoers.d/90-workstation ]; then
    exit 0
fi
/usr/bin/passwd "$user"
/usr/bin/passwd -l root >/dev/null
/usr/sbin/usermod -aG sudo "$user"
# These groups can bypass password-protected sudo on a development server.
for group in docker lxd incus-admin disk; do
    if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
        /usr/bin/gpasswd -d "$user" "$group" >/dev/null
    fi
done
temporary=$(mktemp /etc/sudoers.d/.workstation-admin.XXXXXX)
trap 'rm -f "$temporary"' EXIT HUP INT TERM
printf '%s ALL=(ALL:ALL) ALL\n' "$user" > "$temporary"
chmod 440 "$temporary"
/usr/sbin/visudo -cf "$temporary" >/dev/null
mv "$temporary" /etc/sudoers.d/91-workstation-admin
install -d -m 755 "$directory"
printf '%s\n' "$id" > "$directory/.account-ready.tmp"
chmod 644 "$directory/.account-ready.tmp"
mv "$directory/.account-ready.tmp" "$marker"
# Last operation: a reboot before this point can still resume with sudo -n.
rm -f /etc/sudoers.d/90-workstation
