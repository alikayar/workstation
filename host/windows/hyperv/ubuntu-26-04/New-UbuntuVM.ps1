#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates or resumes an owned Ubuntu Server 26.04 Hyper-V VM without installer questions.
.DESCRIPTION
Run in elevated 64-bit PowerShell on Windows 11 Pro x64. If Hyper-V is disabled,
it is enabled without an automatic restart; reboot Windows and rerun to continue.
Name and resources show defaults; Enter accepts them. The sudo password is entered
into Ubuntu's passwd over authenticated SSH after installation, never into files.
Packer creates the VM and handles first boot; existing guests resume over SSH without
rebuilding. PowerShell 7 delegates to 5.1. Packer and its plugin use a private tool folder.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [ValidatePattern('^[a-z][a-z0-9-]{0,61}[a-z0-9]$')][string]$VMName = 'workstation-ubuntu-26-04',
    [string]$VMRoot = "$env:ProgramData\Workstation\UbuntuVMs",
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,63}$')][string]$SwitchName = 'Default Switch',
    [ValidateRange(2, 64)][int]$CPUs = 4,
    [ValidateRange(4, 32)][int]$MemoryGB = 8,
    [ValidateRange(40, 2048)][int]$DiskGB = 80,
    [ValidatePattern('^[a-z][a-z0-9_]{0,30}$')][string]$UserName = 'dev',
    [switch]$OpenConsole
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use elevated 64-bit PowerShell on Windows 11 x64.' }
if ($PSVersionTable.PSEdition -eq 'Core') {
    $arguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [Management.Automation.SwitchParameter]) { $arguments[$entry.Key] = [bool]$entry.Value }
        else { $arguments[$entry.Key] = $entry.Value }
    }
    $serialized = [Management.Automation.PSSerializer]::Serialize(@{ Script = $PSCommandPath; Parameters = $arguments })
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serialized))
    $command = '$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $encodedPayload + '''))); $parameters=$p.Parameters; & $p.Script @parameters'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell worker exited with code $LASTEXITCODE." }
    return
}
if ([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 22000) { throw 'Windows 11 or later is required.' }
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperv.State -in @('EnablePending', 'DisablePending')) {
    Write-Host 'A Hyper-V feature change is pending. Restart this Windows machine, then rerun the same Ubuntu command.'
    return
}
if ($hyperv.State -ne 'Enabled') {
    Write-Host 'Enabling Hyper-V. This may take a few minutes...'
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
    Write-Host 'Hyper-V was enabled. Restart this Windows machine, then rerun the same Ubuntu command. No VM was created.'
    return
}
Import-Module Hyper-V
. (Join-Path $PSScriptRoot '..\shared\VM-Resources.ps1')
. (Join-Path $PSScriptRoot '..\shared\Seed-ISO.ps1')
. (Join-Path $PSScriptRoot 'Ubuntu-Setup.ps1')
. (Join-Path $PSScriptRoot 'Ubuntu-Packer.ps1')
foreach ($tool in @('ssh.exe', 'scp.exe', 'ssh-keygen.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path ([Environment]::SystemDirectory) ('OpenSSH\' + $tool)))) { throw 'Install the Windows OpenSSH Client optional feature before running Ubuntu setup.' }
}
function Read-UbuntuValue([string]$Label, [object]$Default, [scriptblock]$Validate) {
    while ($true) {
        $answer = Read-Host "$Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = [string]$Default }
        try { return & $Validate $answer.Trim() } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}
if (-not $PSBoundParameters.ContainsKey('VMName')) {
    $VMName = Read-UbuntuValue 'VM name' $VMName {
        param($value)
        if ($value -notmatch '^[a-z][a-z0-9-]{0,61}[a-z0-9]$') { throw 'Use 2-63 lowercase letters, digits or hyphens; start with a letter and end with a letter or digit.' }
        return $value
    }
}
if ($VMRoot -match '["\r\n]' -or $VMRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'VMRoot must be an absolute local drive path, such as D:\VMs.' }
$VMRoot = [IO.Path]::GetFullPath($VMRoot).TrimEnd('\') + '\'
$root = Join-Path $VMRoot $VMName
$markerPath = Join-Path $root 'ubuntu-vm.json'
$payload = Join-Path $root 'payload'
$keyPath = Join-Path $root 'ssh-ed25519'
$knownHosts = Join-Path $root 'known_hosts'
$secrets = Join-Path $root 'setup-secrets'
$seed = Join-Path $secrets 'seed.iso'
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Assert-UbuntuPath $root
Assert-UbuntuPath $markerPath
$hostCPUs = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$mutex = New-Object Threading.Mutex($false, ('Global\Workstation-UbuntuVM-' + $VMName.ToLowerInvariant()))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another operation is using this Ubuntu VM.' }
    Assert-UbuntuBuildIdle $root
    $vm = Get-VM | Where-Object Name -eq $VMName
    $record = $null
    if (Test-Path -LiteralPath $markerPath) {
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($record.Schema -ne 2 -or $record.Backend -cne 'Packer' -or $record.OwnerSID -cne $owner -or $record.Name -cne $VMName -or $record.Root -ine $root -or $record.Token -notmatch '^[a-f0-9]{32}$' -or $record.UserName -notmatch '^[a-z][a-z0-9_]{0,30}$') { throw 'Ubuntu VM ownership record differs; existing VM preserved.' }
        if ($record.Phase -notin @('Preparing', 'Building', 'Account', 'Complete')) { throw 'Invalid installation phase.' }
        if ($record.Phase -in @('Account', 'Complete') -and -not $record.VMId) { throw 'Recorded VM identity is missing; files retained.' }
        if ($record.VMId -and (-not $vm -or [string]$vm.Id -ne $record.VMId)) { throw 'Recorded VM is missing or replaced; files retained.' }
        if ($vm -and ($vm.Notes -cne ('Workstation Ubuntu VM ' + $record.Token) -or -not $record.VMId)) { throw 'VM ownership token or recorded identity differs.' }
        if ($PSBoundParameters.ContainsKey('UserName') -and $UserName -cne $record.UserName) { throw 'Resume with the original user name.' }
        $UserName = $record.UserName
        if (-not $PSBoundParameters.ContainsKey('SwitchName')) { $SwitchName = $record.SwitchName }
        if ($PSBoundParameters.ContainsKey('IsoPath') -and [IO.Path]::GetFullPath($IsoPath) -ine $record.IsoPath) { throw 'Installation media path differs from the saved record.' }
        if (-not $PSBoundParameters.ContainsKey('IsoPath')) { $IsoPath = $record.IsoPath }
    } elseif ($vm -or (Test-Path -LiteralPath $root)) { throw 'Existing VM name or directory is unmanaged; choose another name.' }
    if ($SwitchName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,63}$') { throw 'Use a switch name containing letters, digits, spaces, underscores, dots or hyphens.' }
    $switch = Get-VMSwitch -Name $SwitchName
    if ($switch.SwitchType -ne 'Internal') { throw 'Use an existing Internal switch with DHCP and outbound internet, normally Default Switch.' }
    foreach ($entry in @(
        @{ Name = 'CPUs'; Label = 'VM CPU count'; Minimum = 2; Maximum = [Math]::Min(64, $hostCPUs) },
        @{ Name = 'MemoryGB'; Label = 'VM memory (GiB)'; Minimum = 4; Maximum = 32 },
        @{ Name = 'DiskGB'; Label = 'VM disk (GiB)'; Minimum = 40; Maximum = 2048 }
    )) {
        if (-not $PSBoundParameters.ContainsKey($entry.Name)) {
            if ($record) {
                $saved = ConvertTo-WorkstationResource $entry.Label ([string]$record.($entry.Name)) $entry.Minimum $entry.Maximum
                Set-Variable -Name $entry.Name -Value $saved; continue
            }
            $default = [Math]::Min((Get-Variable -Name $entry.Name -ValueOnly), $entry.Maximum)
            $value = Read-UbuntuValue $entry.Label $default { param($answer) ConvertTo-WorkstationResource $entry.Label $answer $entry.Minimum $entry.Maximum }
            Set-Variable -Name $entry.Name -Value $value
        }
    }
    if ($CPUs -gt $hostCPUs) { throw 'Requested CPU count exceeds host logical CPUs.' }
    if (-not $record -and -not $PSBoundParameters.ContainsKey('UserName')) {
        $UserName = Read-UbuntuValue 'Ubuntu user name' $UserName {
            param($value)
            if ($value -notmatch '^[a-z][a-z0-9_]{0,30}$' -or $value -in @('root', 'ubuntu', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'backup', 'list', 'irc', 'nobody')) { throw 'Choose a new non-root account using lowercase letters, digits or underscores.' }
            return $value
        }
    }
    if ($UserName -in @('root', 'ubuntu', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'backup', 'list', 'irc', 'nobody')) { throw 'Choose a new non-root development account.' }
    if ($record -and ($record.CPUs -ne $CPUs -or $record.MemoryGB -ne $MemoryGB -or $record.DiskGB -ne $DiskGB -or $record.SwitchName -cne $SwitchName)) { throw 'Saved VM settings differ. This command does not resize or reconfigure existing VMs.' }
    if (-not $vm -or $vm.State -notin @('Running', 'Saved')) {
        if (([uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB) -lt (($MemoryGB + 2) * 1GB)) { throw 'Not enough available RAM; leave 2 GiB for the host.' }
    }
    if (-not $record) {
        $drive = [IO.Path]::GetPathRoot($root).Substring(0, 1)
        if ((Get-Volume -DriveLetter $drive).SizeRemaining -lt 20GB) { throw 'Leave at least 20 GiB free for a new Ubuntu installation.' }
        $IsoPath = Get-UbuntuMedia $IsoPath
        if ($IsoPath.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep shared media outside the VM directory.' }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($owner, 'S-1-5-18', 'S-1-5-32-544')) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        if (-not (Test-Path -LiteralPath $VMRoot)) { New-Item -ItemType Directory -Path $VMRoot -Force | Out-Null }
        [IO.Directory]::CreateDirectory($root, $acl) | Out-Null
        $record = [pscustomobject]@{ Schema = 2; Backend = 'Packer'; DiskPath = ''; PayloadHashes = @{}; OwnerSID = $owner; Name = $VMName; Root = $root; Token = [guid]::NewGuid().ToString('N'); VMId = ''; Phase = 'Preparing'; UserName = $UserName; CPUs = $CPUs; MemoryGB = $MemoryGB; DiskGB = $DiskGB; SwitchName = $SwitchName; IsoPath = $IsoPath; SeedSha256 = ''; HostPublicKey = ''; Address = '' }
        Save-UbuntuText $markerPath ($record | ConvertTo-Json -Depth 8)
    }
    if ($vm) { $vm = Get-UbuntuOwnedVM $record }
    $finalizer = Join-Path $payload 'finalize-account.sh'
    if ($record.Phase -eq 'Preparing') {
        $record.IsoPath = Get-UbuntuMedia $record.IsoPath
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        $sources = @{
            'ubuntu.pkr.hcl' = Join-Path $PSScriptRoot 'ubuntu.pkr.hcl'
            'Ubuntu-Setup.ps1' = Join-Path $PSScriptRoot 'Ubuntu-Setup.ps1'
            'Ubuntu-Packer.ps1' = Join-Path $PSScriptRoot 'Ubuntu-Packer.ps1'
            'finalize-account.sh' = Join-Path $PSScriptRoot 'finalize-account.sh'
        }
        $hashes = @{}
        foreach ($name in $sources.Keys) {
            $destination = Join-Path $payload $name
            Assert-UbuntuPath $destination
            if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $sources[$name] -Destination $destination }
            $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            $prior = $record.PayloadHashes.PSObject.Properties[$name]
            if ($prior -and $prior.Value -cne $hash) { throw 'Saved recovery payload changed; files retained.' }
            $hashes[$name] = $hash
        }
        $record.PayloadHashes = [pscustomobject]$hashes
        Save-UbuntuText $markerPath ($record | ConvertTo-Json -Depth 8)
        if (-not (Test-Path -LiteralPath $keyPath)) { New-UbuntuKey $keyPath }
        elseif (-not (Test-Path -LiteralPath ($keyPath + '.pub'))) { throw 'Incomplete SSH identity retained; inspect before retrying.' }
        Assert-UbuntuPath $secrets
        if (-not (Test-Path -LiteralPath $secrets)) { New-Item -ItemType Directory -Path $secrets | Out-Null }
        $hostKey = Join-Path $secrets 'host-ed25519'
        if (-not (Test-Path -LiteralPath $hostKey)) { New-UbuntuKey $hostKey }
        elseif (-not (Test-Path -LiteralPath ($hostKey + '.pub'))) { throw 'Incomplete server identity retained; inspect before retrying.' }
        $record.HostPublicKey = [IO.File]::ReadAllText($hostKey + '.pub').Trim()
        if (-not (Test-Path -LiteralPath $seed)) {
            . (Join-Path $payload 'Ubuntu-Setup.ps1')
            New-UbuntuSeed $record $secrets ([IO.File]::ReadAllText($keyPath + '.pub').Trim()) $hostKey
        }
        $record.SeedSha256 = (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash
        Save-UbuntuText $markerPath ($record | ConvertTo-Json -Depth 8)
    }
    Assert-UbuntuPayload $record
    foreach ($file in @($keyPath, ($keyPath + '.pub'))) { Assert-UbuntuPath $file; if (-not (Test-Path -LiteralPath $file)) { throw 'Recorded SSH identity is missing; it will not be replaced.' } }
    $alias = 'workstation-ubuntu-' + $record.Token
    # OpenSSH keys are case-sensitive; Turkish case folding in Windows PowerShell rejects valid Base64.
    if ($record.HostPublicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: [^\r\n]*)?$') { throw 'Invalid recorded SSH host key.' }
    Save-UbuntuText $knownHosts ($alias + ' ' + $record.HostPublicKey + "`n")
    if ($record.Phase -in @('Preparing', 'Building') -and -not $vm) {
        Assert-UbuntuPath $seed
        if (-not (Test-Path -LiteralPath $seed) -or (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash -cne $record.SeedSha256) { throw 'Setup seed is missing or changed; existing files retained.' }
        # Packer's temp_path must exist before it creates the per-build subdirectory.
        $machines = Join-Path $root 'machines'
        Assert-UbuntuPath $machines
        if (-not (Test-Path -LiteralPath $machines)) { New-Item -ItemType Directory -Path $machines | Out-Null }
        Invoke-UbuntuPacker $record $markerPath ([bool]$OpenConsole)
        # Local Packer provisioners persist the VM identity and original disk path.
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $vm = Get-UbuntuOwnedVM $record
    }
    $vm = Get-UbuntuOwnedVM $record
    if ($record.Phase -eq 'Building') {
        if ($vm.State -in @('Off', 'Saved')) { Start-VM -VM $vm | Out-Null }
        elseif ($vm.State -ne 'Running') { throw 'VM is busy; retry after its state stabilizes.' }
        Complete-UbuntuPackerBuild -RecordPath $markerPath
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $vm = Get-UbuntuOwnedVM $record
    }
    if ($vm.State -in @('Off', 'Saved')) { Start-VM -VM $vm | Out-Null }
    elseif ($vm.State -ne 'Running') { throw 'VM is busy; retry after its state stabilizes.' }
    if ($OpenConsole) { Start-Process -FilePath "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost', $VMName) | Out-Null }
    $address = Wait-UbuntuAddress $record $keyPath $knownHosts
    Save-UbuntuText $knownHosts (($alias + ' ' + $record.HostPublicKey + "`n") + ($address + ' ' + $record.HostPublicKey + "`n"))
    $record.Address = $address
    if ($record.Phase -eq 'Building') { $record.Phase = 'Account'; Save-UbuntuText $markerPath ($record | ConvertTo-Json -Depth 8) }
    if ($record.Phase -ne 'Complete' -and -not (Test-Path -LiteralPath $finalizer)) { throw 'Saved account finalizer is missing; files retained.' }
    & (Join-Path $PSScriptRoot 'Set-GuestAccount.ps1') -Address $address -UserName $UserName -IdentityFile $keyPath -KnownHostsFile $knownHosts -InstallationId $record.Token -FinalizerPath $finalizer -WaitForCloudInit
    $vm = Get-VM -Id $record.VMId
    if ($vm.Notes -cne ('Workstation Ubuntu VM ' + $record.Token)) { throw 'VM identity changed before setup cleanup.' }
    Get-VMDvdDrive -VM $vm | Where-Object { $_.Path -eq $seed -or $_.Path -eq $record.IsoPath } | Set-VMDvdDrive -Path $null
    foreach ($file in @($seed, (Join-Path $secrets 'host-ed25519'), (Join-Path $secrets 'host-ed25519.pub'))) {
        Assert-UbuntuPath $file
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    if ((Test-Path -LiteralPath $secrets) -and @(Get-ChildItem -LiteralPath $secrets -Force).Count -eq 0) { Remove-Item -LiteralPath $secrets }
    Remove-UbuntuPackerExport $record
    $record.Phase = 'Complete'; Save-UbuntuText $markerPath ($record | ConvertTo-Json -Depth 8)
    Set-UbuntuSSHConfig $record
    Write-Host "Ubuntu Server 26.04 ready: $VMName ($UserName@$address). Root is locked; SSH password login is disabled."
    Write-Host "SSH identity: $keyPath"
    Write-Host "Connect: ssh $VMName (saved in your user SSH config). Rerun this command to refresh a changed DHCP address."
    Write-Host 'This installation does not apply Ansible. Internal networking is not a host-isolation policy.'
    [pscustomobject]@{ Name = $VMName; VMId = $record.VMId; Directory = $root; Address = $address; UserName = $UserName; IdentityFile = $keyPath; KnownHostsFile = $knownHosts }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
