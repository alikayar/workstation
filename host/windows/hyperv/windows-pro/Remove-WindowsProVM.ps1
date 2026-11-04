#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Deletes an owned Windows Pro VM and its files, or cleans its orphaned files.
.DESCRIPTION
Requires the installation record or an interrupted-deletion journal. Shared ISO
cache is retained. -Force permits powering off a running or saved VM; it does
not bypass ownership checks or the active installation lock. Supports -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VMName,
    [string]$VMRoot = "$env:ProgramData\Workstation\WindowsVMs",
    [switch]$Force
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
    # Preserve inherited WhatIf as well as an explicitly supplied switch.
    $arguments['WhatIf'] = [bool]$WhatIfPreference
    $payload = [Management.Automation.PSSerializer]::Serialize(@{ Script = $PSCommandPath; Parameters = $arguments; ConfirmPreference = [string]$ConfirmPreference })
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $command = '$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $encodedPayload + '''))); $ConfirmPreference=[Management.Automation.ConfirmImpact]$p.ConfirmPreference; $parameters=$p.Parameters; & $p.Script @parameters'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell worker exited with code $LASTEXITCODE." }
    return
}
Import-Module Hyper-V
. (Join-Path $PSScriptRoot 'Windows-Media.ps1')
if ($VMRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'VMRoot must be an absolute local drive path.' }
$VMRoot = [IO.Path]::GetFullPath($VMRoot).TrimEnd('\')
$root = Join-Path $VMRoot $VMName
$recordPath = Join-Path $root 'windows-vm.json'
# Keep deletion ownership outside the directory that may be only partly removed.
$journalPath = Join-Path $VMRoot ('.' + $VMName + '.delete.json')
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function In-WindowsVMDirectory([string]$Path) {
    if (-not $Path) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    return $full -ieq $root -or $full.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)
}
function Assert-WindowsVMDirectory {
    Assert-PlainPath $root
    if (-not (Test-Path -LiteralPath $root)) { return }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($root)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked VM content refused.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}
$mutex = New-Object Threading.Mutex($false, ('Global\Workstation-WindowsVM-' + $VMName.ToLowerInvariant()))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'A create/resume/delete command is still using this VM. Stop that command before deleting; -Force does not override its lock.' }
    Assert-WindowsVMDirectory
    Assert-PlainPath $journalPath
    Assert-PlainPath $recordPath
    $inventory = @(Get-VM)
    $named = @($inventory | Where-Object Name -eq $VMName)
    $journalExists = Test-Path -LiteralPath $journalPath
    $markerExists = Test-Path -LiteralPath $recordPath
    if (-not $journalExists -and -not $markerExists) {
        if ($named.Count -or (Test-Path -LiteralPath $root)) { throw 'No ownership record; existing VM and files preserved.' }
        Write-Host "Nothing to remove: $VMName."
        return
    }
    $journalText = if ($journalExists) { Get-Content -LiteralPath $journalPath -Raw } else { $null }
    $markerText = if ($markerExists) { Get-Content -LiteralPath $recordPath -Raw } else { $null }
    $record = if ($journalExists) { $journalText | ConvertFrom-Json } else { $markerText | ConvertFrom-Json }
    if ($record.Schema -notin @(1, 2) -or $record.OwnerSID -cne $owner -or $record.Name -ine $VMName -or $record.Root -ine $root -or $record.Token -notmatch '^[a-f0-9]{32}$') { throw 'VM deletion ownership differs; files preserved.' }
    if ($record.VMId -and $record.VMId -notmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') { throw 'Invalid recorded VM identity.' }
    if ($journalExists -and $markerExists) {
        $marker = $markerText | ConvertFrom-Json
        if ($marker.OwnerSID -cne $record.OwnerSID -or $marker.Name -ine $record.Name -or $marker.Root -ine $root -or $marker.VMId -ne $record.VMId -or $marker.Token -cne $record.Token) { throw 'Deletion journal belongs to another VM generation; files preserved.' }
    }
    $identified = @($inventory | Where-Object { $record.VMId -and [string]$_.Id -eq $record.VMId })
    if ($named.Count -gt 1 -or $identified.Count -gt 1 -or ($named.Count -and [string]$named[0].Id -ne $record.VMId) -or ($identified.Count -and $identified[0].Name -ine $VMName)) { throw 'VM name or identity was replaced; nothing removed.' }
    $vm = if ($identified.Count) { $identified[0] } else { $null }
    if ($vm -and $vm.Notes -cne ('Workstation Windows VM ' + $record.Token)) { throw 'VM ownership token differs.' }
    foreach ($candidate in $inventory) {
        $owned = $vm -and [string]$candidate.Id -eq [string]$vm.Id
        if ((In-WindowsVMDirectory $candidate.Path) -ne [bool]$owned) { throw 'VM configuration crosses the deletion boundary.' }
        $versions = @(@{ Value = $candidate; Snapshot = $false })
        $versions += @(Get-VMSnapshot -VM $candidate | ForEach-Object { @{ Value = $_; Snapshot = $true } })
        foreach ($entry in $versions) {
            $version = $entry.Value
            if ($entry.Snapshot) {
                if ((In-WindowsVMDirectory $version.Path) -ne [bool]$owned) { throw 'Checkpoint configuration crosses the deletion boundary.' }
                $disks = @(Get-VMHardDiskDrive -VMSnapshot $version)
                $dvds = @(Get-VMDvdDrive -VMSnapshot $version)
            } else {
                $disks = @(Get-VMHardDiskDrive -VM $version)
                $dvds = @(Get-VMDvdDrive -VM $version)
            }
            foreach ($dvd in $dvds) { if (-not $owned -and (In-WindowsVMDirectory $dvd.Path)) { throw 'Another VM references media inside this directory.' } }
            foreach ($disk in $disks) {
                $path = $disk.Path
                if ($owned -and -not $path) { throw 'Unexpected physical disk attachment; VM preserved.' }
                $seen = @{}
                while ($path) {
                    if ((In-WindowsVMDirectory $path) -ne [bool]$owned) { throw 'A disk chain crosses the deletion boundary; VM and files preserved.' }
                    if ($seen.ContainsKey($path)) { throw 'Disk-chain cycle; cleanup refused.' }
                    $seen[$path] = $true
                    $path = (Get-VHD -Path $path).ParentPath
                }
            }
        }
    }
    if ($vm -and $vm.State -ne 'Off' -and -not $Force) { throw 'VM is not Off. Shut it down first, or use -Force to power it off and delete its data.' }
    if (-not $PSCmdlet.ShouldProcess("$VMName; all files in $root", 'Permanently delete owned VM, checkpoints, disks and setup secrets')) { return }
    if ($markerExists -and (Get-Content -LiteralPath $recordPath -Raw) -cne $markerText) { throw 'Installation record changed; cleanup refused.' }
    if ($journalExists -and (Get-Content -LiteralPath $journalPath -Raw) -cne $journalText) { throw 'Deletion journal changed; cleanup refused.' }
    if (-not $journalExists) {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($record | ConvertTo-Json))
        $stream = [IO.File]::Open($journalPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    if ($vm) {
        $current = Get-VM -Id $record.VMId
        if ($current.Name -ine $VMName -or $current.Notes -cne ('Workstation Windows VM ' + $record.Token)) { throw 'VM changed before removal.' }
        if ($current.State -ne 'Off') {
            if (-not $Force) { throw 'VM started during deletion; use -Force explicitly if intended.' }
            Stop-VM -VM $current -TurnOff -Force -Confirm:$false
        }
        Remove-VM -VM $current -Force -Confirm:$false
    }
    Assert-WindowsVMDirectory
    if ([IO.Path]::GetFullPath($root) -ine (Join-Path $VMRoot $VMName)) { throw 'Unexpected deletion target.' }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -Confirm:$false }
    if (Test-Path -LiteralPath $root) { throw 'VM files remain; deletion journal retained for retry.' }
    Remove-Item -LiteralPath $journalPath -Force -Confirm:$false
    Write-Host "Removed $VMName and its owned files. Shared Windows ISO cache retained."
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
