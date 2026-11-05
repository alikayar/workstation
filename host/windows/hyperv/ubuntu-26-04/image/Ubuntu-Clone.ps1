function New-WVMUbuntuCloneSeed([object]$Record, [string]$Directory, [string]$PublicKey, [string]$HostKeyPath) {
    $user = $Record.UserName; $token = $Record.Token
    $configuration = @{
        hostname = $Record.Name; manage_etc_hosts = $true; preserve_hostname = $false
        disable_root = $true; ssh_pwauth = $false; ssh_deletekeys = $false; ssh_genkeytypes = @('ed25519')
        ssh_keys = @{ ed25519_private = [IO.File]::ReadAllText($HostKeyPath); ed25519_public = [IO.File]::ReadAllText($HostKeyPath + '.pub').Trim() }
        users = @(@{ name=$user; groups=@('sudo'); shell='/bin/bash'; lock_passwd=$true; ssh_authorized_keys=@($PublicKey) })
        growpart = @{ mode='auto'; devices=@('/'); ignore_growroot_disabled=$true }; resize_rootfs=$true
        write_files = @(
            @{path='/etc/cloud/cloud.cfg.d/99-workstation-instance.cfg';owner='root:root';permissions='0644';content="manual_cache_clean: true`n"},
            @{path='/etc/workstation-bootstrap-id';owner='root:root';permissions='0644';content=($token + "`n")},
            @{path='/etc/sudoers.d/90-workstation';owner='root:root';permissions='0440';content=("$user ALL=(ALL) NOPASSWD:ALL`n")},
            @{path='/etc/ssh/sshd_config.d/00-workstation.conf';owner='root:root';permissions='0600';content=("PermitRootLogin no`nPasswordAuthentication no`nKbdInteractiveAuthentication no`nAllowAgentForwarding no`nX11Forwarding no`nAllowUsers $user`n")}
        )
        # install -d assigns ownership only to explicit operands, not implicit parents.
        runcmd = @('passwd -l root', "install -d -o $user -g $user /home/$user/.local /home/$user/.local/state /home/$user/.local/state/workstation-bootstrap /home/$user/.local/state/workstation-bootstrap/$token", 'systemctl restart hv-kvp-daemon', 'systemctl is-active --quiet hv-kvp-daemon', 'systemctl restart ssh')
    }
    $source = Join-Path $Directory 'source'
    if (Test-Path -LiteralPath $source) { throw 'Incomplete clone seed source retained; inspect before retrying.' }
    New-Item -ItemType Directory -Path $source | Out-Null
    try {
        Save-UbuntuText (Join-Path $source 'user-data') ("#cloud-config`n" + ($configuration | ConvertTo-Json -Depth 16))
        Save-UbuntuText (Join-Path $source 'meta-data') ("instance-id: $token`nlocal-hostname: $($Record.Name)`n")
        $network = @{version=2;ethernets=@{ethernet=@{match=@{name='e*'};dhcp4=$true;dhcp6=$false;'accept-ra'=$false}}}
        Save-UbuntuText (Join-Path $source 'network-config') ($network | ConvertTo-Json -Depth 8)
        New-VMSeedISO -Directory $source -Destination (Join-Path $Directory 'seed.iso')
    } finally {
        foreach ($name in @('user-data','meta-data','network-config')) { $path=Join-Path $source $name; if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path} }
        Remove-Item -LiteralPath $source
    }
}
