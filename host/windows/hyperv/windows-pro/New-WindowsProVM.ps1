#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates or resumes an owned Windows 11 Pro Hyper-V installation VM.
.DESCRIPTION
Run from an elevated 64-bit Windows PowerShell 5.1 or PowerShell 7 window.
PowerShell 7 delegates to the inbox Windows PowerShell engine. New VMs use
unattended Windows 11 Pro Setup; existing manual installations are preserved.
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
. (Join-Path $PSScriptRoot '..\VM-Resources.ps1')
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
. (Join-Path $PSScriptRoot '..\commands\Seed-ISO.ps1')
if ($VMRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'VMRoot must be an absolute local drive path, such as D:\VMs.' }
$VMRoot = [IO.Path]::GetFullPath($VMRoot).TrimEnd('\')
$root = Join-Path $VMRoot $VMName
$markerPath = Join-Path $root 'windows-vm.json'
$diskPath = Join-Path $root 'windows.vhdx'
$secretDirectory = Join-Path $root 'setup-secrets'
$answerISO = Join-Path $secretDirectory 'answer.iso'
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Assert-PlainPath $root
Assert-PlainPath $markerPath
Assert-PlainPath ($markerPath + '.tmp')
$switch = Get-VMSwitch -Name $SwitchName
if ($switch.SwitchType -ne 'Internal') { throw 'Select an existing Internal switch; external host/LAN bridging is not configured by this script.' }
$hostCPUs = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if ($hostCPUs -lt 2) { throw 'At least two host logical CPUs are required.' }
# VM names are host-wide, even when callers choose different storage roots.
$mutex = New-Object Threading.Mutex($false, ('Global\Workstation-WindowsVM-' + $VMName.ToLowerInvariant()))
$locked = $false
$mountedHere = $false
$credential = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another operation is using this Windows VM.' }
    $deletionJournal = Join-Path $VMRoot ('.' + $VMName + '.delete.json')
    Assert-PlainPath $deletionJournal
    if (Test-Path -LiteralPath $deletionJournal) { throw 'Deletion is incomplete for this name. Rerun Remove-WindowsProVM.ps1 before creating or resuming it.' }
    $vm = Get-VM | Where-Object Name -eq $VMName
    $record = $null
    if (Test-Path -LiteralPath $markerPath) {
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($record.Schema -notin @(1, 2) -or $record.OwnerSID -cne $owner -or $record.Name -cne $VMName -or $record.Root -ine $root -or $record.Token -notmatch '^[a-f0-9]{32}$') { throw 'VM ownership record differs.' }
        if ($record.Phase -notin @('Creating', 'Ready') -or ($record.Phase -eq 'Ready' -and -not $record.VMId)) { throw 'Invalid VM installation state; files retained.' }
        if ($record.VMId -and (-not $vm -or [string]$vm.Id -ne $record.VMId)) { throw 'Recorded VM is missing or has been replaced; files retained.' }
        if ($vm -and $vm.Notes -cne ('Workstation Windows VM ' + $record.Token)) { throw 'VM ownership token differs; existing VM preserved.' }
        if ($record.Schema -eq 2) {
            if ($record.Setup -notin @('Pending', 'Verified', 'Complete')) { throw 'Invalid unattended setup state.' }
            if ($record.UserName -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,19}$') { throw 'Invalid saved local user name.' }
            if ($PSBoundParameters.ContainsKey('UserName') -and $UserName -cne $record.UserName) { throw 'User name differs from the saved installation.' }
            $UserName = $record.UserName
        }
    } else {
        if ($vm -or (Test-Path -LiteralPath $root)) { throw 'Existing VM name or directory is unmanaged; choose another name.' }
    }
    foreach ($entry in @(
        @{ Name = 'CPUs'; Label = 'VM CPU count'; Minimum = 2; Maximum = [Math]::Min(64, $hostCPUs) },
        @{ Name = 'MemoryGB'; Label = 'VM memory (GiB)'; Minimum = 4; Maximum = 128 },
        @{ Name = 'DiskGB'; Label = 'VM disk (GiB)'; Minimum = 64; Maximum = 2048 }
    )) {
        if ($PSBoundParameters.ContainsKey($entry.Name)) { continue }
        $default = if ($null -ne $record) { $record.($entry.Name) } else { Get-Variable -Name $entry.Name -ValueOnly }
        if ($null -eq $record -and $entry.Name -eq 'CPUs') { $default = [Math]::Min($default, $entry.Maximum) }
        $value = Read-WindowsVMValue $entry.Label $default {
            param($answer)
            ConvertTo-WorkstationResource $entry.Label $answer $entry.Minimum $entry.Maximum
        }
        Set-Variable -Name $entry.Name -Value $value
    }
    if ($CPUs -gt $hostCPUs) { throw "Requested CPUs exceed host logical CPUs ($hostCPUs)." }
    if ($null -eq $record) {
        if (-not $PSBoundParameters.ContainsKey('UserName')) {
            $UserName = Read-WindowsVMValue 'Windows user name' $UserName {
                param($value)
                if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,19}$' -or $value -in @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')) { throw 'Choose a new local user: 1-20 letters, digits, underscores or hyphens; start with a letter.' }
                return $value
            }
        }
    }
    if ($UserName -in @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')) { throw 'Choose a new local account name.' }
    if (-not $vm -or $vm.State -ne 'Running') {
        $available = [uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
        if ($available -lt (($MemoryGB + 2) * 1GB)) { throw 'Not enough available RAM: leave 2 GiB for the host. No VM was started.' }
    }
    if (-not (Test-Path -LiteralPath $diskPath)) {
        $driveName = [IO.Path]::GetPathRoot($root).Substring(0, 1)
        if ((Get-Volume -DriveLetter $driveName).SizeRemaining -lt 64GB) { throw 'Leave at least 64 GiB of physical disk space for the new Windows installation.' }
    }
    $media = Get-WindowsProMedia $IsoPath
    $IsoPath = $media.Path
    $IsoSha256 = $media.Sha256
    if ($IsoPath.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep installation media outside the VM directory.' }
    if ($null -ne $record) {
        if ($record.IsoPath -ine $IsoPath -or $record.IsoSha256 -ine $IsoSha256 -or $record.CPUs -ne $CPUs -or $record.MemoryGB -ne $MemoryGB -or $record.DiskGB -ne $DiskGB -or $record.SwitchName -cne $SwitchName -or $record.Nested -ne [bool]$NestedVirtualization) { throw 'Saved settings differ; repeat with the original arguments. Existing VMs are not resized.' }
    } else {
        $record = [pscustomobject]@{ Schema = 2; OwnerSID = $owner; Name = $VMName; Root = $root; Token = [guid]::NewGuid().ToString('N'); VMId = ''; Phase = 'Creating'; Setup = 'Pending'; UserName = $UserName; IsoPath = $IsoPath; IsoSha256 = $IsoSha256; CPUs = $CPUs; MemoryGB = $MemoryGB; DiskGB = $DiskGB; SwitchName = $SwitchName; Nested = [bool]$NestedVirtualization }
    }
    function Save-Record {
        $temp = $markerPath + '.tmp'
        Assert-PlainPath $markerPath
        Assert-PlainPath $temp
        [IO.File]::WriteAllText($temp, ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $markerPath) { [IO.File]::Replace($temp, $markerPath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $markerPath) }
    }
    $image = Get-DiskImage -ImagePath $IsoPath
    if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $IsoPath -PassThru; $mountedHere = $true }
    $volumes = @($image | Get-Volume | Where-Object DriveLetter)
    if ($volumes.Count -ne 1) { throw 'Expected one readable installation-media volume.' }
    $mediaRoot = [string]$volumes[0].DriveLetter + ':\'
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $mediaRoot 'setup.exe')
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Windows Setup must have a valid Microsoft Authenticode signature.' }
    $wim = Join-Path $mediaRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $mediaRoot 'sources\install.esd' }
    $pro = @(Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq 'Windows 11 Pro')
    if ($pro.Count -ne 1) { throw 'The ISO must contain Windows 11 Pro (not Enterprise Evaluation or Pro N).' }
    $detail = Get-WindowsImage -ImagePath $wim -Index $pro[0].ImageIndex
    if ($detail.EditionId -ne 'Professional' -or [int]$detail.Architecture -ne 9 -or [version]$detail.Version -ne [version]$media.Version) { throw 'Expected the pinned Windows 11 Pro x64 build 26200.6584.' }
    if ($mountedHere) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null; $mountedHere = $false }
    if ($vm) {
        if ($vm.Path -ine $root -and -not $vm.Path.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'VM configuration is outside its owned directory.' }
        $drives = @(Get-VMHardDiskDrive -VM $vm)
        if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'Expected exactly one file-backed VM disk.' }
        $path = $drives[0].Path; $seen = @{}
        while ($path) {
            $path = [IO.Path]::GetFullPath($path)
            if (-not $path.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)) { throw 'Unexpected disk chain; retained for inspection.' }
            Assert-PlainPath $path
            $seen[$path] = $true
            $vhd = Get-VHD -Path $path
            if ($path -ieq $diskPath) { if ($vhd.ParentPath) { throw 'Unexpected base-disk parent.' }; break }
            if (-not $vhd.ParentPath) { throw 'Disk is not descended from the recorded base.' }
            $path = $vhd.ParentPath
        }
    }
    if ($record.Schema -eq 2 -and $record.Setup -eq 'Pending') {
        Assert-PlainPath $answerISO
        if ($record.Phase -eq 'Ready' -and -not (Test-Path -LiteralPath $answerISO)) { throw 'Pending setup media is missing; existing Windows disk will not be reseeded.' }
        if ((Test-Path -LiteralPath $answerISO) -and (Get-FileHash -LiteralPath $answerISO -Algorithm SHA256).Hash -cne $record.AnswerSha256) { throw 'Existing setup media differs; files retained.' }
        $credential = Read-WindowsVMCredential $UserName
    }
    if ($vm -and $record.Phase -eq 'Ready') {
        if ($vm.State -notin @('Off', 'Running', 'Saved')) { throw 'VM is busy; retry when its state is stable.' }
    } else {
        if ($vm -and $vm.State -ne 'Off') { throw 'Incomplete VM must be Off to resume configuration; it was not stopped automatically.' }
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
        Save-Record
        if (-not (Test-Path -LiteralPath $diskPath)) { New-VHD -Path $diskPath -Dynamic -SizeBytes ($DiskGB * 1GB) | Out-Null }
        else {
            Assert-PlainPath $diskPath
            $base = Get-VHD -Path $diskPath
            if ($base.VhdType -ne 'Dynamic' -or $base.Size -ne ($DiskGB * 1GB) -or $base.ParentPath) { throw 'Existing base disk differs; preserved.' }
        }
        if ($record.Schema -eq 2 -and -not (Test-Path -LiteralPath $answerISO)) {
            New-WindowsAnswerISO $secretDirectory $credential $record.Token $DiskGB
            $record | Add-Member -NotePropertyName AnswerSha256 -NotePropertyValue ((Get-FileHash -LiteralPath $answerISO -Algorithm SHA256).Hash) -Force
            Save-Record
        }
        if (-not $vm) {
            # A crash between New-VM and setting Notes is deliberately refused on resume.
            $vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -VHDPath $diskPath -SwitchName $SwitchName -Path $root
            Set-VM -VM $vm -Notes ('Workstation Windows VM ' + $record.Token)
        }
        $record.VMId = [string]$vm.Id; Save-Record
        Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
        Set-VMProcessor -VM $vm -Count $CPUs -ExposeVirtualizationExtensions ([bool]$NestedVirtualization)
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
        if (-not (Get-VMSecurity -VM $vm).TpmEnabled) {
            Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
            Enable-VMTPM -VM $vm
        }
        # Integration IDs can include a VM-specific prefix; the service GUID is stable.
        $copyService = @(Get-VMIntegrationService -VM $vm | Where-Object { ([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480', [StringComparison]::OrdinalIgnoreCase) })
        if ($copyService.Count -ne 1) { throw 'Guest Service Interface could not be identified; VM left Off.' }
        $copyService[0] | Disable-VMIntegrationService
        $dvds = @(Get-VMDvdDrive -VM $vm)
        $installer = @($dvds | Where-Object { $_.Path -ine $answerISO })
        if ($installer.Count -gt 1 -or @($dvds | Where-Object { $_.Path -and $_.Path -ine $IsoPath -and $_.Path -ine $answerISO }).Count) { throw 'Unexpected DVD attachments.' }
        if ($installer.Count -eq 0) { Add-VMDvdDrive -VM $vm -Path $IsoPath }
        else { Set-VMDvdDrive -VMDvdDrive $installer[0] -Path $IsoPath }
        if ($record.Schema -eq 2 -and -not @($dvds | Where-Object Path -eq $answerISO).Count) { Add-VMDvdDrive -VM $vm -Path $answerISO }
        $dvd = Get-VMDvdDrive -VM $vm | Where-Object Path -eq $IsoPath
        Set-VMFirmware -VM $vm -FirstBootDevice $dvd
        $record.Phase = 'Ready'; Save-Record
    }
    if ($record.Schema -eq 2 -and $record.Setup -eq 'Pending') {
        if ((Get-FileHash -LiteralPath $answerISO -Algorithm SHA256).Hash -cne $record.AnswerSha256) { throw 'Setup media changed; VM was not started.' }
        if (@(Get-VMDvdDrive -VM $vm | Where-Object Path -eq $answerISO).Count -ne 1) { throw 'Pending setup media is not attached; VM was not started.' }
    }
    $vm = Get-VM -Id $record.VMId
    if ($vm.State -ne 'Running') {
        $free = [uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
        if ($free -lt (($MemoryGB + 2) * 1GB)) { throw 'Not enough available RAM: leave 2 GiB for the host. The VM and disks were retained; rerun later.' }
        Start-VM -VM $vm | Out-Null
    }
    if ($OpenConsole) { Start-Process -FilePath "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost', $VMName) | Out-Null }
    if ($record.Schema -eq 2 -and $record.Setup -eq 'Pending') {
        Wait-WindowsSetup -VMId $record.VMId -Token $record.Token -DiskPath $diskPath -Credential $credential
        $record.Setup = 'Verified'; Save-Record
    }
    if ($record.Schema -eq 2 -and $record.Setup -eq 'Verified') {
        $vm = Get-VM -Id $record.VMId
        if ($vm.Notes -cne ('Workstation Windows VM ' + $record.Token)) { throw 'VM identity changed before setup cleanup.' }
        Get-VMDvdDrive -VM $vm | Where-Object Path -eq $answerISO | Remove-VMDvdDrive
        Get-VMDvdDrive -VM $vm | Where-Object Path -eq $IsoPath | Set-VMDvdDrive -Path $null
        Assert-PlainPath $answerISO
        if (Test-Path -LiteralPath $answerISO) { Remove-Item -LiteralPath $answerISO -Force }
        if ((Test-Path -LiteralPath $secretDirectory) -and @(Get-ChildItem -LiteralPath $secretDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $secretDirectory }
        $record.Setup = 'Complete'; Save-Record
    }
    if ($record.Schema -eq 1) { Write-Host "Existing manual installation preserved: $VMName. Continue Windows Setup in its console." }
    else { Write-Host "Windows 11 Pro ready: $VMName. English UI, Turkey region and Turkish Q keyboard." }
    Write-Host 'Use a basic VMConnect session for untrusted work; enhanced sessions can redirect clipboard and host devices. Internal networking is not a full host-isolation policy.'
    [pscustomobject]@{ Name = $VMName; VMId = $record.VMId; Directory = $root; State = [string](Get-VM -Id $record.VMId).State; Edition = 'Windows 11 Pro'; NestedVirtualization = [bool]$NestedVirtualization }
} finally {
    if ($credential) { $credential.Password.Dispose() }
    try { if ($mountedHere) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
