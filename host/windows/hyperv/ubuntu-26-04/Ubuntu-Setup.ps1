function Assert-UbuntuPath([string]$Path) {
    if ($Path -match '["`$\r\n]') { throw 'Use local paths without quotes, dollar signs, backticks or line breaks for Packer.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked path refused: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Save-UbuntuText([string]$Path, [string]$Content) {
    Assert-UbuntuPath $Path
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Get-UbuntuMedia([string]$IsoPath) {
    # Canonical's published SHA256SUMS, pinned independently of future point releases.
    $sha256 = 'cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927'
    if ($IsoPath) {
        $path = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
        Assert-UbuntuPath $path
        if ([IO.Path]::GetExtension($path) -ine '.iso' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $sha256) { throw 'Expected the pinned Ubuntu Server 26.04.1 amd64 ISO.' }
        return $path
    }
    $cache = Join-Path $env:ProgramData 'Workstation\Media'
    $path = Join-Path $cache 'ubuntu-26.04.1-live-server-amd64.iso'
    Assert-UbuntuPath $path
    $mutex = New-Object Threading.Mutex($false, 'Global\Workstation-Ubuntu2604-Media')
    $locked = $false; $partial = $null
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is preparing Ubuntu media. Retry when it finishes.' }
        if (Test-Path -LiteralPath $path) {
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $sha256) { throw 'Cached Ubuntu ISO differs from its pin; file preserved for inspection.' }
            return $path
        }
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        if ((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($cache).Substring(0, 1))).SizeRemaining -lt 6GB) { throw 'Leave 6 GiB free for Ubuntu installation media.' }
        $partial = $path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Write-Host 'Downloading pinned Ubuntu Server 26.04.1 amd64 media from Canonical...'
        Invoke-WebRequest -Uri 'https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.iso' -OutFile $partial -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3600
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $sha256) { throw 'Ubuntu ISO SHA256 mismatch; no VM was started.' }
        [IO.File]::Move($partial, $path)
        return $path
    } finally {
        try { if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial } }
        finally { [Net.ServicePointManager]::SecurityProtocol = $protocol; if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
}

function New-UbuntuKey([string]$Path) {
    Assert-UbuntuPath $Path
    Assert-UbuntuPath ($Path + '.pub')
    if ((Test-Path -LiteralPath ($Path + '.pub')) -or (Test-Path -LiteralPath $Path)) { throw 'Existing key files retained; inspect the interrupted key creation.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh-keygen.exe'
    $start.Arguments = '-q -t ed25519 -N "" -f "' + $Path + '"'
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    try { $process.WaitForExit(); if ($process.ExitCode -ne 0) { throw 'SSH key generation failed.' } } finally { $process.Dispose() }
}

function New-UbuntuSeed([object]$Record, [string]$Directory, [string]$PublicKey, [string]$HostKeyPath) {
    $hostPrivate = [IO.File]::ReadAllText($HostKeyPath)
    $hostPublic = [IO.File]::ReadAllText($HostKeyPath + '.pub').Trim()
    $user = $Record.UserName; $token = $Record.Token
    $configuration = @{
        autoinstall = @{
            version = 1
            'interactive-sections' = @()
            'refresh-installer' = @{ update = $false }
            locale = 'en_US.UTF-8'
            keyboard = @{ layout = 'tr'; variant = '' }
            timezone = 'Europe/Istanbul'
            identity = @{ hostname = $Record.Name; username = $user; password = '!' }
            ssh = @{ 'install-server' = $true; 'allow-pw' = $false; 'authorized-keys' = @($PublicKey) }
            storage = @{ layout = @{ name = 'direct'; match = @{ path = '/dev/sda' } } }
            apt = @{ geoip = $false; fallback = 'abort' }
            # Hyper-V IP discovery requires hv_kvp_daemon from cloud-tools, not kernel tools alone.
            packages = @('sudo', 'linux-tools-virtual', 'linux-cloud-tools-virtual', 'unattended-upgrades')
            updates = 'security'
            shutdown = 'reboot'
            # Never run the unattended partitioner over a previously partitioned guest disk.
            'early-commands' = @('test "$(lsblk -dn -o TYPE /dev/sda)" = disk && ! lsblk -nr -o TYPE /dev/sda | grep -qx part')
            'late-commands' = @(
                "printf '%s\n' '$token' > /target/etc/workstation-bootstrap-id",
                "printf '%s\n' '$user ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-workstation",
                'chmod 440 /target/etc/sudoers.d/90-workstation',
                "curtin in-target --target=/target -- install -d -o $user -g $user /home/$user/.local/state/workstation-bootstrap/$token",
                'curtin in-target --target=/target -- passwd -l root'
            )
            'user-data' = @{
                disable_root = $true
                ssh_pwauth = $false
                ssh_deletekeys = $false
                ssh_keys = @{ ed25519_private = $hostPrivate; ed25519_public = $hostPublic }
                write_files = @(@{
                    path = '/etc/ssh/sshd_config.d/00-workstation.conf'
                    owner = 'root:root'; permissions = '0600'
                    content = "PermitRootLogin no`nPasswordAuthentication no`nKbdInteractiveAuthentication no`nAllowAgentForwarding no`nX11Forwarding no`nAllowUsers $user`n"
                }, @{
                    path = '/etc/apt/apt.conf.d/20auto-upgrades'
                    owner = 'root:root'; permissions = '0644'
                    content = "APT::Periodic::Update-Package-Lists `"1`";`nAPT::Periodic::Unattended-Upgrade `"1`";`n"
                }, @{
                    path = '/etc/apt/apt.conf.d/52workstation'
                    owner = 'root:root'; permissions = '0644'
                    content = "Unattended-Upgrade::Automatic-Reboot `"false`";`n"
                })
                runcmd = @('systemctl restart hv-kvp-daemon', 'systemctl is-active --quiet hv-kvp-daemon', 'systemctl restart ssh')
            }
        }
    }
    # JSON is YAML-compatible and avoids quoting passwords, keys or shell text by hand.
    $source = Join-Path $Directory 'source'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    Save-UbuntuText (Join-Path $source 'user-data') ("#cloud-config`n" + ($configuration | ConvertTo-Json -Depth 16))
    Save-UbuntuText (Join-Path $source 'meta-data') ("instance-id: $token`nlocal-hostname: $($Record.Name)`n")
    New-VMSeedISO -Directory $source -Destination (Join-Path $Directory 'seed.iso')
    foreach ($file in @('user-data', 'meta-data')) { Remove-Item -LiteralPath (Join-Path $source $file) }
    Remove-Item -LiteralPath $source
}

function Set-UbuntuSSHConfig([object]$Record) {
    if ($Record.Phase -cne 'Complete' -or $Record.Name -cnotmatch '^[a-z][a-z0-9-]{0,61}[a-z0-9]$' -or $Record.Token -cnotmatch '^[a-f0-9]{32}$' -or $Record.UserName -cnotmatch '^[a-z][a-z0-9_]{0,30}$' -or $Record.Address -cnotmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Only a verified, complete Ubuntu installation can publish SSH config.' }
    Assert-UbuntuPath $Record.Root
    $directory = Join-Path $HOME '.ssh'
    $path = Join-Path $directory 'config'
    Assert-UbuntuPath $path
    $mutex = New-Object Threading.Mutex($false, ('Global\Workstation-SSHConfig-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is updating SSH config; rerun to finish.' }
        $existing = ''
        if (Test-Path -LiteralPath $path) { $existing = [IO.File]::ReadAllText($path) }
        $begin = '# BEGIN Workstation Ubuntu ' + $Record.Token
        $end = '# END Workstation Ubuntu ' + $Record.Token
        $pattern = '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n|$)'
        $blocks = [regex]::Matches($existing, $pattern)
        if ($blocks.Count -gt 1 -or (($existing.Contains($begin) -or $existing.Contains($end)) -and $blocks.Count -ne 1)) { throw 'Managed SSH config markers are inconsistent; existing config retained.' }
        $remainder = [regex]::Replace($existing, $pattern, '')
        foreach ($line in ($remainder -split '\r?\n')) {
            if ($line -match '^\s*Host\s+(.+)$') {
                foreach ($alias in (($Matches[1] -replace '\s+#.*$', '') -split '\s+')) {
                    if ([string]::Equals($alias.Trim('"'), $Record.Name, [StringComparison]::OrdinalIgnoreCase)) { throw 'SSH alias already exists outside this installation block; existing config retained.' }
                }
            }
        }
        $root = $Record.Root.Replace('\', '/')
        # Specific options precede existing Host * defaults; reset scope before preserving the original file.
        $block = @(
            $begin, ('Host ' + $Record.Name), ('    HostName ' + $Record.Address), ('    User ' + $Record.UserName),
            ('    IdentityFile "' + $root + '/ssh-ed25519"'), '    IdentitiesOnly yes', '    IdentityAgent none',
            '    ForwardAgent no', '    StrictHostKeyChecking yes', ('    HostKeyAlias workstation-ubuntu-' + $Record.Token),
            ('    UserKnownHostsFile "' + $root + '/known_hosts"'), '    GlobalKnownHostsFile NUL',
            '    ServerAliveInterval 30', '    ServerAliveCountMax 3', 'Host *', $end
        ) -join "`n"
        $updated = $block + "`n" + $remainder
        if ($updated -cne $existing) {
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
            Save-UbuntuText $path $updated
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Wait-UbuntuAddress([object]$Record, [string]$IdentityFile, [string]$KnownHostsFile) {
    $ssh = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
    $alias = 'workstation-ubuntu-' + $Record.Token
    $deadline = (Get-Date).AddMinutes(45); $nextUpdate = Get-Date
    $lastIssue = 'Hyper-V has not reported an IPv4 address. Check the guest hv-kvp-daemon service (linux-cloud-tools-virtual).'
    Write-Host 'Waiting for unattended Ubuntu installation (up to 45 minutes). Ctrl+C retains the VM for resume.'
    do {
        $vm = Get-VM -Id $Record.VMId
        if ($vm.Name -cne $Record.Name -or $vm.Notes -cne ('Workstation Ubuntu VM ' + $Record.Token)) { throw 'VM identity changed while waiting.' }
        $drives = @(Get-VMHardDiskDrive -VM $vm)
        if ($drives.Count -ne 1 -or $drives[0].Path -ine $Record.DiskPath) { throw 'VM disk changed while waiting.' }
        $addresses = @(Get-VMNetworkAdapter -VM $vm | Select-Object -ExpandProperty IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -notlike '127.*' } | Select-Object -Unique)
        if (-not $addresses.Count) { $lastIssue = 'Hyper-V has not reported an IPv4 address. Check the guest hv-kvp-daemon service (linux-cloud-tools-virtual).' }
        foreach ($address in $addresses) {
            $options = @('-F', 'NUL', '-i', $IdentityFile, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes', '-o', 'StrictHostKeyChecking=yes', '-o', ('HostKeyAlias=' + $alias), '-o', ('UserKnownHostsFile="' + $KnownHostsFile.Replace('\', '/') + '"'), '-o', 'GlobalKnownHostsFile=NUL', '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2')
            $preference = $ErrorActionPreference
            $errorPath = Join-Path $Record.Root ('ssh-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
            Assert-UbuntuPath $errorPath
            try {
                $ErrorActionPreference = 'Continue'
                $response = & $ssh @options ($Record.UserName + '@' + $address) ("test `"`$(cat /etc/workstation-bootstrap-id 2>/dev/null)`" = '$($Record.Token)' && . /etc/os-release && test `"`$ID`" = ubuntu && test `"`$VERSION_ID`" = 26.04 && printf '%s' '$($Record.Token)'") 2>$errorPath
                $exitCode = $LASTEXITCODE
                $lastIssue = "SSH guest identity verification failed at $address (exit $exitCode)."
                if (Test-Path -LiteralPath $errorPath) {
                    $detail = ([IO.File]::ReadAllText($errorPath) -replace '[\x00-\x1f\x7f]', ' ').Trim()
                    if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
                    if ($detail) { $lastIssue += ' ' + $detail }
                }
            } finally {
                $ErrorActionPreference = $preference
                if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath }
            }
            if ($exitCode -eq 0 -and ($response -join '') -ceq $Record.Token) { return $address }
        }
        if ((Get-Date) -ge $nextUpdate) { Write-Host ('Ubuntu SSH pending; VM state: ' + $vm.State + '. ' + $lastIssue); $nextUpdate = (Get-Date).AddMinutes(1) }
        Start-Sleep -Seconds 5
    } until ((Get-Date) -ge $deadline)
    throw "Ubuntu SSH verification timed out. Last check: $lastIssue The VM and seed were retained; rerun without reinstalling."
}

function Wait-UbuntuFirstBoot([string]$Ssh, [string[]]$Options, [string]$Target, [string]$InstallationId) {
    if ($InstallationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid installation identity.' }
    # Subiquity disables cloud-init after first boot. Validate its saved result instead of requiring status=done.
    $program = @'
import json
import pathlib
import sys
import time

token = sys.argv[1]
if pathlib.Path('/etc/workstation-bootstrap-id').read_text().strip() != token:
    sys.exit('First-boot installation identity differs.')
deadline = time.monotonic() + 300
while True:
    path = pathlib.Path('/var/lib/cloud/data/status.json')
    if path.exists():
        try:
            state = json.loads(path.read_text())['v1']
        except (ValueError, KeyError):
            state = {}
        stages = [state.get(name, {}) for name in ('init-local', 'init', 'modules-config', 'modules-final')]
        if any(stage.get('errors') for stage in stages):
            sys.exit('Cloud-init recorded a failed stage; inspect its root-owned logs.')
        if not state.get('stage') and all(stage.get('finished') for stage in stages) and pathlib.Path('/var/lib/cloud/instance/boot-finished').is_file():
            warnings = [message for stage in stages for messages in stage.get('recoverable_errors', {}).values() for message in messages]
            # The bootstrap account intentionally has no usable password until passwd runs interactively.
            if any(not message.startswith('Not unlocking blank password for existing user ') for message in warnings):
                sys.exit('Cloud-init recorded unexpected warnings; inspect its root-owned logs.')
            print('Ubuntu first boot completed; no failed cloud-init stages.')
            break
    if time.monotonic() >= deadline:
        sys.exit('Timed out waiting for the cloud-init first-boot completion record.')
    time.sleep(2)
'@
    $program | & $Ssh @Options $Target ('sudo -n python3 - ' + $InstallationId)
    if ($LASTEXITCODE -ne 0) { throw 'Ubuntu first-boot verification failed; VM preserved.' }
}
