#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GitName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GitEmail,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [ValidatePattern('^[a-z][a-z0-9-]{0,48}[a-z0-9]$')][string]$VMName = 'workstation',
    [ValidatePattern('^[a-z][a-z0-9_]{0,30}$')][string]$UserName = 'dev',
    [string]$IdentityFile,
    [ValidatePattern('^[^"\r\n]+$')][string]$KnownHostsFile,
    [switch]$TemplateBuild,
    [string]$PreparedPayload,
    [string]$TrustedPackerPath,
    [string]$SwitchName = 'Default Switch',
    [ValidateRange(2, 64)][int]$CPUs = 4,
    [ValidateRange(4096, 131072)][int]$MemoryMB = 8192,
    [ValidateRange(40, 2048)][int]$DiskGB = 80,
    [ValidateRange(1024, 65535)][int]$HttpPort = 8808,
    [string]$StateRoot = "$env:LOCALAPPDATA\Workstation\HyperV"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on the Windows host.' }
. (Join-Path $PSScriptRoot 'VM-Resources.ps1')
if (-not $PSBoundParameters.ContainsKey('CPUs')) { $CPUs = Get-WorkstationResource WORKSTATION_VM_CPUS 4 2 64 }
if (-not $PSBoundParameters.ContainsKey('MemoryMB')) { $MemoryMB = Get-WorkstationResource WORKSTATION_VM_MEMORY_MB 8192 4096 131072 }
if (-not $PSBoundParameters.ContainsKey('DiskGB')) { $DiskGB = Get-WorkstationResource WORKSTATION_VM_DISK_GB 80 40 2048 }
if ($UserName -eq 'root') { throw 'Choose a non-root development user.' }
if ($StateRoot -match '["\r\n]' -or $StateRoot.StartsWith('\\')) { throw 'Use a local state directory without quotes or line breaks.' }
$windows = Get-CimInstance Win32_OperatingSystem
if ([int]$windows.BuildNumber -lt 22000 -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This workflow targets Windows 11 on x64, from 64-bit PowerShell.'
}
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
    Write-Host 'Hyper-V was enabled. Restart Windows yourself, then rerun the same command.'
    return
}
Import-Module Hyper-V
$sshExe = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
$scpExe = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\scp.exe'
$keygenExe = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh-keygen.exe'
foreach ($tool in @($sshExe, $scpExe, $keygenExe)) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required on the host: $tool" }
}
if ([IO.Path]::GetExtension($PublicKeyPath) -ne '.pub') { throw 'Select the public key file ending in .pub.' }
$publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
if ($publicKey -notmatch '^(ssh-ed25519|ssh-rsa) ([A-Za-z0-9+/]+={0,3})(?: [^\r\n]*)?$') {
    throw 'Provide a single OpenSSH RSA or Ed25519 public key (.pub), never a private key.'
}
$publicKey = "$($Matches[1]) $($Matches[2])"
$repo = if (-not $PreparedPayload) { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path } else { $null }
$frozen = if ($PreparedPayload) { Get-Content -LiteralPath (Join-Path $PreparedPayload 'repository.json') -Raw | ConvertFrom-Json } else { $null }
if ($PreparedPayload -and ($frozen.Revision -notmatch '^[a-f0-9]{40,64}$' -or $frozen.Branch -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$')) { throw 'Invalid prepared repository metadata.' }
$state = Join-Path ([IO.Path]::GetFullPath($StateRoot)) $VMName
$manifestPath = Join-Path $state 'installation.json'
function Save-Connection([string]$Address) {
    if (-not $Address) {
        $deadline = (Get-Date).AddMinutes(2)
        do {
            $addresses = @(Get-VMNetworkAdapter -VMName $VMName | Select-Object -ExpandProperty IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' })
            if ($addresses.Count -gt 1) { throw 'Multiple guest addresses reported. Inspect networking before connecting.' }
            if ($addresses.Count -eq 1) { $Address = $addresses[0] }
            if (-not $Address) { Start-Sleep -Seconds 3 }
        } until ($Address -or (Get-Date) -ge $deadline)
        if (-not $Address) { throw 'The VM is installed but has not reported an address. Rerun setup after it boots.' }
    }
    $json = @{ Address = $Address; User = $UserName } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $state 'connection.json'), $json, [Text.UTF8Encoding]::new($false))
}
function Complete-Account([string]$Address) {
    # Image builders are sealed immediately instead of creating a reusable user password.
    # Legacy installations retain their original provisioning policy.
    if ($TemplateBuild -or $installation.Schema -lt 2) { return }
    $deadline = (Get-Date).AddMinutes(2)
    do {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $ready = $client.ConnectAsync($Address, 22)
            if ($ready.Wait(2000) -and $client.Connected) { break }
        } catch { } finally { $client.Dispose() }
        if ((Get-Date) -ge $deadline) { throw 'Ubuntu SSH is not ready for account finalization. Rerun setup to resume.' }
        Start-Sleep -Seconds 3
    } while ($true)
    $key = $IdentityFile
    if (-not $key) { $key = $PublicKeyPath.Substring(0, $PublicKeyPath.Length - 4) }
    $account = @{ Address = $Address; UserName = $UserName; IdentityFile = $key; InstallationId = $installation.Id; FinalizerPath = (Join-Path $payload 'finalize-account.sh') }
    if ($KnownHostsFile) { $account.KnownHostsFile = $KnownHostsFile }
    & (Join-Path $PSScriptRoot 'guest\Set-GuestAccount.ps1') @account
}
$utf8 = New-Object Text.UTF8Encoding($false)
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and -not (Test-Path -LiteralPath $manifestPath)) {
    throw "VM '$VMName' has no Workstation installation record. It was left unchanged."
}
if ((Test-Path -LiteralPath $state) -and -not (Test-Path -LiteralPath $manifestPath)) {
    throw "Unrecognized state directory: $state. Inspect it before continuing."
}
if (-not $PreparedPayload -and -not (Test-Path -LiteralPath $manifestPath)) {
    $changes = & git.exe -C $repo status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'Run from a Git checkout of Workstation.' }
    if ($changes) { throw 'Commit or stash local changes before creating a new installation. Its recovery payload uses a committed revision.' }
}
if (-not (Test-Path -LiteralPath $state)) {
    New-Item -ItemType Directory -Path $state | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $callerRights = if ($PreparedPayload) { "*$($sid):(OI)(CI)RX" } else { "*$($sid):(OI)(CI)F" }
    & "$env:SystemRoot\System32\icacls.exe" $state /inheritance:r /grant:r $callerRights '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-83-0:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict permissions on the installation directory.' }
}
# Prevent two invocations from provisioning the same installation concurrently.
$lock = [IO.File]::Open((Join-Path $state 'installation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$build = $null
$ruleCreated = $false
$previousCache = $env:PACKER_CACHE_DIR
try {
    if (Test-Path -LiteralPath $manifestPath) {
        $installation = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($installation.Schema -notin @(1, 2) -or $installation.Id -notmatch '^[a-f0-9]{32}$' -or $installation.Revision -notmatch '^[a-f0-9]{40,64}$') {
            throw 'Invalid Workstation installation record; inspect it before continuing.'
        }
        $isBuilder = ($installation.PSObject.Properties.Name -contains 'Purpose') -and $installation.Purpose -eq 'TemplateBuilder'
        if ([bool]$TemplateBuild -ne [bool]$isBuilder) { throw 'Use the original installation mode. Normal VMs cannot be adopted as image builders.' }
        if ($installation.UserName -ne $UserName -or $installation.PublicKey -ne $publicKey -or $installation.GitName -ne $GitName -or $installation.GitEmail -ne $GitEmail) {
            throw 'Resume with the original username, public key and Git identity. Manage changes inside the prepared VM.'
        }
        if ($installation.Schema -eq 2) {
            # Explicit parameters/environment values must agree; omitted values reuse the record.
            if (-not $PSBoundParameters.ContainsKey('CPUs') -and -not $env:WORKSTATION_VM_CPUS) { $CPUs = $installation.Resources.CPUs }
            if (-not $PSBoundParameters.ContainsKey('MemoryMB') -and -not $env:WORKSTATION_VM_MEMORY_MB) { $MemoryMB = $installation.Resources.MemoryMB }
            if (-not $PSBoundParameters.ContainsKey('DiskGB') -and -not $env:WORKSTATION_VM_DISK_GB) { $DiskGB = $installation.Resources.DiskGB }
        }
        if ($installation.Schema -eq 2 -and
            ($installation.Resources.CPUs -ne $CPUs -or $installation.Resources.MemoryMB -ne $MemoryMB -or $installation.Resources.DiskGB -ne $DiskGB)) {
            throw 'Resource sizes differ from the saved installation. Resume with its original settings; setup does not resize existing VMs.'
        }
    } else {
        if ($PreparedPayload) { $revision = $frozen.Revision; $branch = $frozen.Branch }
        else {
            $revision = & git.exe -C $repo rev-parse HEAD
            if ($LASTEXITCODE -ne 0) { throw 'Run from a Git checkout of Workstation.' }
            $branch = & git.exe -C $repo symbolic-ref --short HEAD
            if ($LASTEXITCODE -ne 0) { throw 'Check out a branch before preparing the VM payload.' }
        }
        $installation = [pscustomobject]@{
            Schema = 2; Id = [Guid]::NewGuid().ToString('N'); Revision = $revision; Branch = $branch
            Purpose = $(if ($TemplateBuild) { 'TemplateBuilder' } else { 'Workstation' })
            UserName = $UserName; PublicKey = $publicKey; GitName = $GitName; GitEmail = $GitEmail
            Resources = @{ CPUs = $CPUs; MemoryMB = $MemoryMB; DiskGB = $DiskGB }
        }
        [IO.File]::WriteAllText($manifestPath, ($installation | ConvertTo-Json), $utf8)
    }
    $payload = Join-Path $state 'payload'
    $bundle = Join-Path $payload 'workstation.bundle'
    $payloadReady = Join-Path $payload 'ready'
    if (-not (Test-Path -LiteralPath $payloadReady)) {
        if ($vm) { throw 'The saved provisioning payload is incomplete. Inspect the installation directory.' }
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        if ($PreparedPayload) {
            if ($frozen.Revision -cne $installation.Revision) { throw 'The installed package differs from the interrupted builder. Resume using its original package.' }
            Copy-Item -LiteralPath (Join-Path $PreparedPayload 'workstation.bundle') -Destination $bundle -Force
        } else {
            $current = & git.exe -C $repo rev-parse HEAD
            if ($LASTEXITCODE -ne 0 -or $current -ne $installation.Revision) { throw 'Restore the recorded checkout revision before preparing the interrupted payload.' }
            & git.exe -C $repo bundle create "$bundle.tmp" HEAD $installation.Branch
            if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the saved repository revision.' }
            Move-Item -LiteralPath "$bundle.tmp" -Destination $bundle -Force
        }
        $vars = @{ git_user_name = $GitName; git_user_email = $GitEmail }
        if ($installation.Schema -eq 2) {
            $vars.workstation_security_enabled = $true
            $vars.docker_add_user_to_group = $false
        }
        [IO.File]::WriteAllText((Join-Path $payload 'workstation-vars.json'), ($vars | ConvertTo-Json), $utf8)
        $files = @('provision-workstation.sh')
        if ($installation.Schema -eq 2) { $files += @('finalize-account.sh', 'ubuntu.pkr.hcl') }
        $sourcePaths = @{
            'provision-workstation.sh' = 'host/windows/hyperv/guest/provision-workstation.sh'
            'finalize-account.sh' = 'host/windows/hyperv/guest/finalize-account.sh'
            'ubuntu.pkr.hcl' = 'host/windows/hyperv/ubuntu.pkr.hcl'
        }
        foreach ($file in $files) {
            if ($PreparedPayload) {
                Copy-Item -LiteralPath (Join-Path $PreparedPayload $file) -Destination (Join-Path $payload $file) -Force
            } else {
                # Read the recorded revision, including installations from the earlier flat layout.
                $sourcePath = $sourcePaths[$file]
                $legacyPath = "host/windows/$file"
                $recordedPaths = @(& git.exe -C $repo ls-tree -r --name-only $installation.Revision -- $sourcePath $legacyPath)
                if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the recorded revision. No VM was created.' }
                if ($recordedPaths -notcontains $sourcePath) {
                    if ($recordedPaths -notcontains $legacyPath) { throw "Could not find $file in the recorded revision. No VM was created." }
                    $sourcePath = $legacyPath
                }
                $content = & git.exe -C $repo show "$($installation.Revision):$sourcePath"
                if ($LASTEXITCODE -ne 0) { throw "Could not read $file from the recorded revision. No VM was created." }
                # Keep payload filenames and LF line endings stable for guest recovery.
                [IO.File]::WriteAllText((Join-Path $payload $file), (($content -join "`n") + "`n"), $utf8)
            }
        }
        [IO.File]::WriteAllText($payloadReady, $installation.Revision, $utf8)
    }
    Write-Host "Using saved Workstation revision $($installation.Revision). New local changes are not part of this installation."
    $machines = Join-Path $state 'machines'
    if ($vm) {
        $machineRoot = [IO.Path]::GetFullPath($machines).TrimEnd('\') + '\'
        if (-not ([IO.Path]::GetFullPath($vm.Path)).StartsWith($machineRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The existing VM is outside this installation directory. It was left unchanged.'
        }
        if ($vm.State -eq 'Off' -or $vm.State -eq 'Saved') { Start-VM -VM $vm | Out-Null }
        elseif ($vm.State -eq 'Paused') { Resume-VM -VM $vm | Out-Null }
        elseif ($vm.State -ne 'Running') { throw "VM state '$($vm.State)' needs attention in Hyper-V Manager." }
        $deadline = (Get-Date).AddMinutes(10)
        $guestAddress = $null
        do {
            $ips = @(Get-VMNetworkAdapter -VMName $VMName | Select-Object -ExpandProperty IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' })
            if ($ips.Count -gt 1) { throw 'Multiple guest IPv4 addresses reported; inspect VM networking before resuming.' }
            if ($ips.Count -eq 1) {
                $client = New-Object Net.Sockets.TcpClient
                try {
                    $connect = $client.ConnectAsync($ips[0], 22)
                    if ($connect.Wait(2000) -and $client.Connected) { $guestAddress = $ips[0] }
                } catch { } finally { $client.Dispose() }
            }
            if (-not $guestAddress) { Start-Sleep -Seconds 5 }
        } until ($guestAddress -or (Get-Date) -ge $deadline)
        if (-not $guestAddress) { throw 'Ubuntu SSH is not ready after 10 minutes. Inspect the installer in Hyper-V Manager; the disk was preserved.' }
        if (-not $IdentityFile) { $IdentityFile = $PublicKeyPath.Substring(0, $PublicKeyPath.Length - 4) }
        $sshOptions = @('-F', 'NUL', '-o', 'IdentityAgent=none', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes', '-i', $IdentityFile, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=ask', '-o', 'ConnectTimeout=15')
        if ($KnownHostsFile) { $sshOptions += @('-o', ('UserKnownHostsFile="' + [IO.Path]::GetFullPath($KnownHostsFile).Replace('\', '/') + '"')) }
        $target = "$UserName@$guestAddress"
        $id = $installation.Id
        $remote = ".local/state/workstation-bootstrap/$id"
        # Verify guest ownership before uploading files or running provisioning.
        & $sshExe @sshOptions $target "test `"`$(cat /etc/workstation-bootstrap-id)`" = '$id' || exit 20; if test -f ~/$remote/complete && test `"`$(cat ~/$remote/complete)`" = '$($installation.Revision)'; then exit 0; else exit 10; fi"
        if ($LASTEXITCODE -eq 0) {
            Complete-Account $guestAddress
            Save-Connection $guestAddress
            Write-Host "VM '$VMName' is already ready at $guestAddress (user $UserName)."
            return
        }
        if ($LASTEXITCODE -ne 10) { throw 'Guest identity or SSH authentication could not be confirmed. No provisioning was attempted.' }
        & $sshExe @sshOptions $target "mkdir -p ~/$remote"
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the guest payload directory.' }
        foreach ($file in @('workstation.bundle', 'workstation-vars.json', 'provision-workstation.sh', 'bootstrap-key.pub')) {
            & $scpExe @sshOptions (Join-Path $payload $file) "${target}:$remote/$file"
            if ($LASTEXITCODE -ne 0) { throw "Could not upload $file. Rerun the command to resume." }
        }
        & $sshExe @sshOptions $target "sh ~/$remote/provision-workstation.sh $id $($installation.Revision)"
        if ($LASTEXITCODE -ne 0) { throw 'Workstation provisioning did not finish. The VM and payload were preserved; rerun to resume.' }
        Complete-Account $guestAddress
        Save-Connection $guestAddress
        Write-Host "VM '$VMName' is ready at $guestAddress (user $UserName)."
        return
    }

    # Packer is only used when no VM exists; never rerun the installer over a guest disk.
    if ((Test-Path -LiteralPath $machines) -and @(Get-ChildItem -LiteralPath $machines -Force).Count -gt 0) {
        throw 'VM files remain but no registered VM was found. Recover the VM in Hyper-V Manager; no new disks were created.'
    }
    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ($switch.SwitchType -ne 'Internal') { throw 'Use an existing Internal switch with DHCP and internet access (normally Default Switch).' }
    $adapter = "vEthernet ($SwitchName)"
    $addresses = @(Get-NetIPAddress -InterfaceAlias $adapter -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($addresses.Count -ne 1) { throw "Expected one IPv4 address on '$adapter'." }
    $hostAddress = $addresses[0].IPAddress
    $env:PACKER_CACHE_DIR = Join-Path $state 'cache'
    New-Item -ItemType Directory -Path $machines, $env:PACKER_CACHE_DIR -Force | Out-Null
    if ($PreparedPayload) {
        if (-not $TrustedPackerPath -or -not (Test-Path -LiteralPath $TrustedPackerPath)) { throw 'Protected Packer executable is missing. Rerun host setup.' }
        $packer = [pscustomobject]@{ Source = $TrustedPackerPath }
    } else {
        $packer = Get-Command packer.exe -ErrorAction SilentlyContinue
        if (-not $packer) {
            & winget.exe install --id Hashicorp.Packer --exact --source winget --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) { throw "Packer installation failed (exit $LASTEXITCODE)." }
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            $packer = Get-Command packer.exe -ErrorAction Stop
        }
    }
    $build = Join-Path $state ("bootstrap-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $build | Out-Null
    $keyPath = Join-Path $build 'bootstrap-key'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $keygenExe
    $start.Arguments = '-q -t ed25519 -N "" -f "' + $keyPath + '"'
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'Could not generate the temporary build identity.' }
    Copy-Item -LiteralPath "$keyPath.pub" -Destination (Join-Path $payload 'bootstrap-key.pub')
    $variables = @{
        vm_name = $VMName; switch_name = $SwitchName; host_address = $hostAddress; http_port = $HttpPort
        cpus = $CPUs; memory_mb = $MemoryMB; disk_mb = $DiskGB * 1024
        state_dir = $state.Replace('\', '/')
        payload_dir = $payload.Replace('\', '/'); bootstrap_id = $installation.Id; revision = $installation.Revision
        username = $UserName; public_key = $publicKey
        bootstrap_public_key = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()
        bootstrap_private_key = $keyPath.Replace('\', '/')
    }
    $variablesPath = Join-Path $build 'build.pkrvars.json'
    [IO.File]::WriteAllText($variablesPath, ($variables | ConvertTo-Json), $utf8)
    $template = if ($installation.Schema -eq 2) { Join-Path $payload 'ubuntu.pkr.hcl' } else { Join-Path $PSScriptRoot 'ubuntu.pkr.hcl' }
    $packerPath = $packer.Source
    & $packerPath init $template
    if ($LASTEXITCODE -ne 0) { throw 'Packer plugin installation failed.' }
    $ruleName = "Workstation-Packer-$($installation.Id)"
    New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $hostAddress -LocalPort $HttpPort -InterfaceAlias $adapter -RemoteAddress LocalSubnet -Profile Any | Out-Null
    $ruleCreated = $true
    & $packerPath build -on-error=abort "-var-file=$variablesPath" $template
    if ($LASTEXITCODE -ne 0) { throw 'VM build stopped. Rerun this command to resume over SSH once Ubuntu is installed; otherwise inspect the installer in Hyper-V Manager.' }
    Start-VM -Name $VMName | Out-Null
    Remove-Item -LiteralPath (Join-Path $state 'output') -Recurse -Force
    Save-Connection
    $connection = Get-Content -LiteralPath (Join-Path $state 'connection.json') -Raw | ConvertFrom-Json
    Complete-Account $connection.Address
    Write-Host "VM '$VMName' is installed and starting. See docs/windows.md for the SSH alias."
} finally {
    $env:PACKER_CACHE_DIR = $previousCache
    try {
        if ($ruleCreated) { Remove-NetFirewallRule -Name $ruleName }
    } finally {
        try {
            if ($build) { Remove-Item -LiteralPath $build -Recurse -Force }
        } finally { $lock.Dispose() }
    }
}
