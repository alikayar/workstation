#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates or resumes an owned Windows 11 Pro Hyper-V installation VM.
.DESCRIPTION
Run from an elevated 64-bit Windows PowerShell 5.1 or PowerShell 7 window.
PowerShell 7 delegates to the inbox Windows PowerShell engine. New VMs use
Packer-backed unattended Windows 11 Pro Setup; existing installations are preserved.
Omitted name/resource parameters are prompted with defaults. Installation media
is downloaded or reused from cache with a pinned hash and Setup signature check.
Existing unrelated VMs and disks are never adopted, resized or deleted.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VMName = 'workstation-windows-pro',
    [string]$VMRoot = "$env:ProgramData\Workstation\WindowsVMs",
    [string]$SwitchName = 'Default Switch',
    [ValidateRange(2, 64)][int]$CPUs = 4,
    [ValidateRange(4, 128)][int]$MemoryGB = 8,
    [ValidateRange(64, 2048)][int]$DiskGB = 120,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,19}$')][string]$UserName = 'dev',
    [switch]$NestedVirtualization,
    [switch]$OpenConsole
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Use elevated 64-bit PowerShell on Windows 11 x64.'
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    # Keep Hyper-V objects native by using the same engine on every entry path.
    $arguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [Management.Automation.SwitchParameter]) { $arguments[$entry.Key] = [bool]$entry.Value }
        else { $arguments[$entry.Key] = $entry.Value }
    }
    $payload = @{ Script = $PSCommandPath; Parameters = $arguments }
    $serialized = [Management.Automation.PSSerializer]::Serialize($payload)
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serialized))
    $command = '$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $encodedPayload + '''))); $parameters=$p.Parameters; & $p.Script @parameters'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell worker exited with code $LASTEXITCODE." }
    return
}
if ([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 22000) { throw 'Windows 11 or later is required.' }
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State -ne 'Enabled') {
    throw 'Enable Hyper-V in Windows Features and restart Windows, then rerun. This script does not enable host features or reboot.'
}
. (Join-Path $PSScriptRoot '..\shared\VM-Resources.ps1')
function Read-WindowsVMValue([string]$Label, [object]$Default, [scriptblock]$Validate) {
    while ($true) {
        $answer = Read-Host "$Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = [string]$Default }
        try { return & $Validate $answer.Trim() }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}
if (-not $PSBoundParameters.ContainsKey('VMName')) {
    $VMName = Read-WindowsVMValue 'VM name' $VMName {
        param($value)
        if ($value -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$') { throw 'Use 1-63 letters, digits or hyphens; start with a letter or digit.' }
        return $value
    }
}
Import-Module Hyper-V
Import-Module Dism
. (Join-Path $PSScriptRoot 'Windows-Media.ps1')
. (Join-Path $PSScriptRoot 'Windows-Unattend.ps1')
. (Join-Path $PSScriptRoot 'Windows-Packer.ps1')
. (Join-Path $PSScriptRoot '..\shared\Seed-ISO.ps1')
if ($VMRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'VMRoot must be an absolute local drive path, such as D:\VMs.' }
$VMRoot = [IO.Path]::GetFullPath($VMRoot).TrimEnd('\')
$root = Join-Path $VMRoot $VMName
$markerPath = Join-Path $root 'windows-vm.json'
$secretDirectory = Join-Path $root 'setup-secrets'
$answerISO = Join-Path $secretDirectory 'answer.iso'
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Assert-PlainPath $root
Assert-PlainPath $markerPath
$mutex = New-Object Threading.Mutex($false, ('Global\Workstation-WindowsVM-' + $VMName.ToLowerInvariant()))
$locked = $false; $credential = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another operation is using this Windows VM.' }
    $journal = Join-Path $VMRoot ('.' + $VMName + '.delete.json')
    Assert-PlainPath $journal
    if (Test-Path -LiteralPath $journal) { throw 'Deletion is incomplete; rerun Remove-WindowsProVM.ps1 first.' }
    Assert-PackerIdle $root
    $vm = Get-VM | Where-Object Name -eq $VMName
    $record = $null; $mediaVerified = $false
    if (Test-Path -LiteralPath $markerPath) {
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($record.Schema -notin @(1,2,3) -or $record.OwnerSID -cne $owner -or $record.Name -cne $VMName -or $record.Root -ine $root -or $record.Token -cnotmatch '^[a-f0-9]{32}$') { throw 'VM ownership record differs.' }
        if ($record.Phase -notin @('Creating','Building','Ready') -or ($record.Schema -lt 3 -and $record.Phase -eq 'Building')) { throw 'Invalid Windows installation phase.' }
        if ($record.Schema -eq 3) {
            if ($record.Backend -cne 'Packer') { throw 'Unexpected Windows backend.' }
            Assert-PackerPath $root
            if ($record.Phase -ne 'Creating') { Assert-WindowsPackerPayload $record }
        }
        if ($record.Schema -ge 2) {
            if ($record.Setup -notin @('Pending','Verified','Complete') -or $record.UserName -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,19}$') { throw 'Invalid saved unattended setup state.' }
            if ($PSBoundParameters.ContainsKey('UserName') -and $UserName -cne $record.UserName) { throw 'Saved Windows user differs.' }
            $UserName = $record.UserName
        }
        foreach ($name in @('CPUs','MemoryGB','DiskGB','SwitchName')) {
            if ($PSBoundParameters.ContainsKey($name) -and (Get-Variable $name -ValueOnly) -cne $record.$name) { throw "Saved $name differs; existing VM was preserved." }
            Set-Variable -Name $name -Value $record.$name
        }
        if ($PSBoundParameters.ContainsKey('NestedVirtualization') -and [bool]$NestedVirtualization -ne $record.Nested) { throw 'Saved nested virtualization setting differs.' }
        $NestedVirtualization = [bool]$record.Nested
        if ($PSBoundParameters.ContainsKey('IsoPath') -and [IO.Path]::GetFullPath($IsoPath) -ine $record.IsoPath) { throw 'Saved ISO path differs.' }
        $IsoPath = $record.IsoPath
        if ($record.VMId) { $vm = Get-OwnedWindowsVM $record }
        elseif ($vm -or $record.Phase -ne 'Creating' -or $record.Schema -lt 3) { throw 'Unregistered or missing VM will not be adopted or rebuilt; files retained.' }
    } elseif ($vm -or (Test-Path -LiteralPath $root)) { throw 'Existing VM name or directory is unmanaged; choose another name.' }
    $hostCPUs = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if (-not $record) {
        foreach ($entry in @(
            @{Name='CPUs'; Label='VM CPU count'; Minimum=2; Maximum=[Math]::Min(64,$hostCPUs)},
            @{Name='MemoryGB'; Label='VM memory (GiB)'; Minimum=4; Maximum=32},
            @{Name='DiskGB'; Label='VM disk (GiB)'; Minimum=64; Maximum=2048}
        )) {
            if ($PSBoundParameters.ContainsKey($entry.Name)) { continue }
            $default = Get-Variable $entry.Name -ValueOnly
            if ($entry.Name -eq 'CPUs') { $default = [Math]::Min($default,$entry.Maximum) }
            $value = Read-WindowsVMValue $entry.Label $default { param($answer) ConvertTo-WorkstationResource $entry.Label $answer $entry.Minimum $entry.Maximum }
            Set-Variable -Name $entry.Name -Value $value
        }
        if ($MemoryGB -gt 32) { throw 'The pinned Hyper-V Packer plugin supports at most 32 GiB per new VM.' }
        if (-not $PSBoundParameters.ContainsKey('UserName')) {
            $UserName = Read-WindowsVMValue 'Windows user name' $UserName {
                param($value)
                if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,19}$' -or $value -in @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount')) { throw 'Choose a new local user: 1-20 letters, digits, underscores or hyphens; start with a letter.' }
                return $value
            }
        }
    }
    if ($CPUs -gt $hostCPUs -or $hostCPUs -lt 2) { throw 'Requested CPU count exceeds this host.' }
    if ($UserName -in @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount')) { throw 'Choose a new local account name.' }
    $switch = Get-VMSwitch -Name $SwitchName
    if ($switch.SwitchType -ne 'Internal') { throw 'Select an existing Internal switch; external bridging is not configured.' }
    if (-not $vm -or $vm.State -ne 'Running') {
        $free = [uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
        $required = if ($vm) { $vm.MemoryStartup } else { $MemoryGB * 1GB }
        if ($free -lt ($required + 2GB)) { throw 'Not enough available RAM: leave 2 GiB for the host. No VM was started.' }
    }
    if (-not $record) {
        Assert-PackerPath $root
        if ($SwitchName -match '["`$\r\n]') { throw 'Use a switch name without shell metacharacters.' }
        $drive = [IO.Path]::GetPathRoot($root).Substring(0,1)
        if ((Get-Volume -DriveLetter $drive).SizeRemaining -lt 64GB) { throw 'Leave at least 64 GiB of physical disk space for Windows.' }
        $media = Get-WindowsProMedia $IsoPath
        if ($media.Path.StartsWith(($root + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Keep installation media outside the VM directory.' }
        Assert-PackerPath $media.Path
        Assert-WindowsProImage $media; $mediaVerified = $true
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @($owner,'S-1-5-18','S-1-5-32-544')) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
        }
        [IO.Directory]::CreateDirectory($root,$acl) | Out-Null
        $record = [pscustomobject]@{Schema=3; Backend='Packer'; OwnerSID=$owner; Name=$VMName; Root=$root; Token=[guid]::NewGuid().ToString('N'); VMId=''; DiskPath=''; Phase='Creating'; Setup='Pending'; UserName=$UserName; IsoPath=$media.Path; IsoSha256=$media.Sha256; AnswerSha256=''; PayloadHashes=[pscustomobject]@{}; CPUs=$CPUs; MemoryGB=$MemoryGB; DiskGB=$DiskGB; SwitchName=$SwitchName; Nested=[bool]$NestedVirtualization}
        Save-WindowsVMRecord $record
    }
    if ($record.Schema -eq 3 -and $record.Phase -eq 'Creating') {
        $machines = Join-Path $root 'machines'
        if ($record.VMId -or ((Test-Path -LiteralPath $machines) -and @(Get-ChildItem -LiteralPath $machines -Force).Count)) { throw 'Existing build files will not be rebuilt; inspect or remove this owned installation.' }
        $payload = Join-Path $root 'payload'
        Assert-PackerPath $payload
        if (-not (Test-Path -LiteralPath $payload)) { New-Item -ItemType Directory -Path $payload | Out-Null }
        foreach ($name in @('windows-pro.pkr.hcl','Windows-Packer.ps1','Windows-Media.ps1','Windows-Unattend.ps1','Autounattend.xml','Packer.ps1')) {
            $source = if ($name -eq 'Packer.ps1') { Join-Path $PSScriptRoot '..\shared\Packer.ps1' } else { Join-Path $PSScriptRoot $name }
            $destination = Join-Path $payload $name
            Assert-PackerPath $destination
            $saved = $record.PayloadHashes.PSObject.Properties[$name]
            if ($saved) {
                if ((Get-FileHash -LiteralPath $destination).Hash -cne $saved.Value) { throw 'Existing recovery payload changed; files preserved.' }
            } else {
                if (Test-Path -LiteralPath $destination) { throw 'Unrecorded recovery file retained; inspect before retrying.' }
                Copy-Item -LiteralPath $source -Destination $destination
                $record.PayloadHashes | Add-Member -NotePropertyName $name -NotePropertyValue ((Get-FileHash -LiteralPath $destination).Hash)
                Save-WindowsVMRecord $record
            }
        }
        Assert-WindowsPackerPayload $record
        if (-not $mediaVerified) {
            $media = Get-WindowsProMedia $record.IsoPath
            if ($media.Sha256 -ine $record.IsoSha256) { throw 'Saved ISO hash differs.' }
            Assert-WindowsProImage $media
        }
        . (Join-Path $payload 'Windows-Unattend.ps1')
        $credential = Read-WindowsVMCredential $record.UserName
        if (-not (Test-Path -LiteralPath $answerISO)) {
            New-WindowsAnswerISO $secretDirectory $credential $record.Token $record.DiskGB
            $record.AnswerSha256 = (Get-FileHash -LiteralPath $answerISO).Hash
            Save-WindowsVMRecord $record
        } elseif (-not $record.AnswerSha256 -or (Get-FileHash -LiteralPath $answerISO).Hash -cne $record.AnswerSha256) { throw 'Existing setup media differs; retained for inspection.' }
        Invoke-WindowsPacker $record $credential ([bool]$OpenConsole)
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $vm = Get-OwnedWindowsVM $record
    } else {
        $vm = Get-OwnedWindowsVM $record
        if ($vm.State -notin @('Off','Running','Saved')) { throw 'VM is busy; retry when its state is stable.' }
        if ($record.Schema -lt 3 -and $record.Phase -eq 'Creating') { throw 'Legacy partial hardware configuration requires inspection; no automatic rebuild attempted.' }
        if ($record.Schema -ge 2 -and $record.Setup -eq 'Pending') {
            Assert-PlainPath $answerISO
            if (-not (Test-Path -LiteralPath $answerISO) -or (Get-FileHash -LiteralPath $answerISO).Hash -cne $record.AnswerSha256 -or @(Get-VMDvdDrive -VM $vm | Where-Object Path -eq $answerISO).Count -ne 1) { throw 'Pending setup media differs or is missing; existing disk was not reseeded.' }
            $credential = Read-WindowsVMCredential $record.UserName
        }
        if ($record.Schema -eq 3 -and ($record.Phase -ne 'Ready' -or $record.Setup -ne 'Complete')) {
            if ($record.Setup -eq 'Pending' -and $vm.State -ne 'Running') { Start-VM -VM $vm | Out-Null }
            if ($OpenConsole) { Start-Process "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost',$VMName) | Out-Null }
            Complete-WindowsPackerInstallation $record $credential
        } elseif ($record.Schema -eq 2 -and $record.Setup -ne 'Complete') {
            if ($record.Setup -eq 'Pending' -and $vm.State -ne 'Running') { Start-VM -VM $vm | Out-Null }
            if ($record.Setup -eq 'Pending') {
                Wait-WindowsSetup -VMId $record.VMId -Token $record.Token -DiskPath (Join-Path $root 'windows.vhdx') -Credential $credential
                $record.Setup='Verified'; Save-WindowsVMRecord $record
            }
            Complete-WindowsSetupMedia $record
        }
    }
    Assert-PackerIdle $root
    if ($record.Schema -eq 3) { Remove-WorkstationPackerExport $record }
    $vm = Get-OwnedWindowsVM $record
    if ($vm.State -ne 'Running') {
        $free = [uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
        if ($free -lt ($vm.MemoryStartup + 2GB)) { throw 'Not enough available RAM to start the retained VM; rerun later.' }
        Start-VM -VM $vm | Out-Null
    }
    if ($OpenConsole) { Start-Process "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost',$VMName) | Out-Null }
    if ($record.Schema -eq 1) { Write-Host "Manual Windows installation preserved: $VMName." }
    else { Write-Host "Windows 11 Pro ready: $VMName. English UI, Turkey region and Turkish Q keyboard." }
    Write-Host 'Use basic VMConnect for untrusted work. Enhanced sessions redirect host resources; Internal networking is not full host isolation.'
    [pscustomobject]@{Name=$VMName; VMId=$record.VMId; Directory=$root; State=[string](Get-VM -Id $record.VMId).State; Edition='Windows 11 Pro'; NestedVirtualization=[bool]$NestedVirtualization}
} finally {
    if ($credential) { $credential.Password.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
