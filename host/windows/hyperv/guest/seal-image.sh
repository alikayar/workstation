#!/bin/sh
# Runs only in the dedicated image-builder VM, before copying its powered-off disk.
set -eu
expected=$1
user=$2
case "$expected" in ''|*[!a-f0-9]*) exit 20;; esac
case "$user" in ''|root|*[!a-z0-9_]*) exit 20;; esac
[ "$(id -u)" = 0 ]
[ "$(cat /etc/workstation-bootstrap-id)" = "$expected" ]
home=$(getent passwd "$user" | cut -d: -f6)
[ "$home" = "/home/$user" ]
# A fresh factory build has never signed into external services. Refuse a used builder.
for file in "$home/.codex/auth.json" "$home/.git-credentials" "$home/.config/gh/hosts.yml"; do
    [ ! -e "$file" ] || { echo 'Image builder contains account state; do not publish this image.' >&2; exit 1; }
done
# New VMs have fresh UEFI NVRAM; keep Ubuntu's installed signed loaders bootable.
[ -s /boot/efi/EFI/ubuntu/shimx64.efi ]
[ -s /boot/efi/EFI/ubuntu/grubx64.efi ]
install -d /boot/efi/EFI/BOOT
install -m 644 /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
install -m 644 /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
if [ -f /boot/efi/EFI/ubuntu/grub.cfg ]; then
    install -m 644 /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg
fi
usermod --password '!' "$user"
usermod --password '!' root
rm -f /etc/ssh/ssh_host_* /etc/sudoers.d/90-workstation /etc/sudoers.d/91-workstation-admin /etc/sudoers.d/90-cloud-init-users
rm -f /var/lib/workstation/account-ready "$home/.ssh/authorized_keys"
rm -f /etc/cloud/cloud-init.disabled /etc/cloud/cloud.cfg.d/99-installer.cfg /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -f /etc/netplan/00-installer-config.yaml /etc/netplan/50-cloud-init.yaml
printf 'datasource_list: [ NoCloud, None ]\n' > /etc/cloud/cloud.cfg.d/90-workstation-image.cfg
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service >/dev/null
cloud-init clean --logs --machine-id --seed
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
printf '%s\n' "$expected" > /var/lib/workstation/image-sealed
sync
printf 'WORKSTATION_IMAGE_SEALED=%s\n' "$expected"
shutdown -P now
