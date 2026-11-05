. (Join-Path $PSScriptRoot '..\windows-pro\Windows-Media.ps1')
. (Join-Path $PSScriptRoot 'VM.ps1')

function Read-WVMRecord([string]$Path, [string]$VMName) {
    Assert-PlainPath $Path
    $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-WVMRecord $record
    $guest = $record.Guest
    $root = Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) $VMName
    if ([IO.Path]::GetFileName($Path).StartsWith('.')) { $root = Join-Path (Split-Path -Parent $Path) $VMName }
    Assert-PlainPath $root
    if ($record.Name -ine $VMName -or $record.Root -ine $root -or $record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $record.Token -cnotmatch '^[a-f0-9]{32}$') { throw 'VM ownership record differs; nothing changed.' }
    [pscustomobject]@{ Guest = $guest; Record = $record; RecordPath = $Path }
}

function Get-WVMTarget([string]$VMName, [string]$VMRoot, [switch]$AllowOrphan) {
    if ([string]::IsNullOrWhiteSpace($VMName)) { throw 'Supply an exact VM name, for example: wvm start interview.' }
    if ($VMRoot) {
        if ($VMRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'VMRoot must be an absolute local drive path.' }
        $VMRoot = [IO.Path]::GetFullPath($VMRoot).TrimEnd('\')
    }
    $matches = @(Get-VM | Where-Object Name -eq $VMName)
    if ($matches.Count -gt 1) { throw 'VM name is ambiguous.' }
    $vm = if ($matches.Count) { $matches[0] } else { $null }
    $paths = @()
    if ($vm) {
        $cursor = [IO.Path]::GetFullPath($vm.Path)
        while ($cursor) {
            foreach ($name in @('windows-vm.json','ubuntu-vm.json')) {
                $path = Join-Path $cursor $name
                Assert-PlainPath $path
                if (Test-Path -LiteralPath $path) { $paths += $path }
            }
            if ($paths.Count) { break }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    } elseif ($AllowOrphan) {
        if ($VMName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$') { throw 'Invalid managed VM name.' }
        $parents = if ($VMRoot) { @($VMRoot) } else { @("$env:ProgramData\Workstation\WindowsVMs", "$env:ProgramData\Workstation\UbuntuVMs") }
        foreach ($parent in $parents) {
            foreach ($relative in @((Join-Path $VMName 'windows-vm.json'), (Join-Path $VMName 'ubuntu-vm.json'), ('.' + $VMName + '.delete.json'))) {
                $path = Join-Path $parent $relative
                Assert-PlainPath $path
                if (Test-Path -LiteralPath $path) { $paths += $path }
            }
        }
        $paths = @($paths | Group-Object { (Read-WVMRecord $_ $VMName).Record.Root } | ForEach-Object { $_.Group[0] })
    } else { throw "VM not found: $VMName" }
    if ($paths.Count -gt 1) { throw 'Multiple ownership records found; specify -VMRoot for orphan cleanup.' }
    if (-not $paths.Count) {
        if ($AllowOrphan -or -not $vm -or $vm.Notes -match '^Workstation (Windows|Ubuntu) VM ') { throw 'No Workstation ownership record found. For orphan cleanup, supply -VMRoot; unmanaged VMs cannot be deleted.' }
        return [pscustomobject]@{ VM = $vm; Guest = ''; Record = $null; RecordPath = '' }
    }
    $target = Read-WVMRecord $paths[0] $VMName
    if ($VMRoot -and [IO.Path]::GetFullPath($target.Record.Root) -ine [IO.Path]::GetFullPath((Join-Path $VMRoot $VMName))) { throw 'VMRoot differs from the ownership record.' }
    if ($vm -and ([string]$vm.Id -ne $target.Record.VMId -or $vm.Notes -cne ('Workstation ' + $target.Guest + ' VM ' + $target.Record.Token))) { throw 'VM identity or ownership token changed; nothing changed.' }
    $target | Add-Member -NotePropertyName VM -NotePropertyValue $vm
    return $target
}

function Invoke-WVMPower {
    [CmdletBinding(SupportsShouldProcess)]
    param([ValidateSet('start','stop')][string]$Action, [string]$VMName, [string]$VMRoot, [switch]$OpenConsole)
    $target = Get-WVMTarget $VMName $VMRoot
    $id = [string]$target.VM.Id
    $lockName = if ($target.Record) { 'Global\Workstation-' + $target.Guest + 'VM-' + $VMName.ToLowerInvariant() } else { 'Global\Workstation-WVM-' + $id }
    $mutex = New-Object Threading.Mutex($false, $lockName)
    $locked = $false
    function Get-CurrentPowerVM {
        $value = Get-VM -Id $id
        if ($value.Name -ine $VMName -or $value.Notes -cne $target.VM.Notes) { throw 'VM identity changed before the power operation.' }
        return $value
    }
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another operation is using this VM.' }
        $current = Get-WVMTarget $VMName $VMRoot
        if ([string]$current.VM.Id -ne $id -or $current.VM.Notes -cne $target.VM.Notes) { throw 'VM changed before the power operation.' }
        $target = $current; $vm = $target.VM
        if ($target.Record) { Assert-PackerIdle $target.Record.Root }
        if ($Action -eq 'start') {
            if ($vm.State -notin @('Off','Saved','Running')) { throw 'VM is busy or paused; no state was changed.' }
            if ($target.Record -and (($target.Guest -eq 'Ubuntu' -and $target.Record.Phase -ne 'Complete') -or ($target.Guest -eq 'Windows' -and ($target.Record.Phase -ne 'Ready' -or ($target.Record.Setup -ne 'Complete'))))) { throw 'Installation is incomplete; use wvm create to resume it first.' }
            if ($PSCmdlet.ShouldProcess($VMName, 'Start VM')) {
                $vm = Get-CurrentPowerVM
                if ($vm.State -notin @('Off','Saved','Running')) { throw 'VM state changed; retry when stable.' }
                if ($vm.State -ne 'Running' -and ([uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB) -lt ($vm.MemoryStartup + 2GB)) { throw 'Not enough available RAM: leave 2 GiB for the host. No VM was started.' }
                if ($target.Guest -eq 'Ubuntu') {
                    . (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Setup.ps1')
                    . (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Network.ps1')
                    if ($vm.State -eq 'Off') { Set-UbuntuNetworkPolicy $target.Record } else { Assert-UbuntuNetworkPolicy $target.Record }
                }
                if ($vm.State -ne 'Running') { Start-VM -VM $vm | Out-Null }
                if ($OpenConsole) { Start-Process "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost', '-G', $id) | Out-Null }
            }
        } else {
            if ($vm.State -eq 'Off') { Write-Host "Already Off: $VMName"; return }
            if ($vm.State -ne 'Running') { throw 'Normal shutdown requires a running VM; saved or paused guests are not powered off implicitly.' }
            if ($PSCmdlet.ShouldProcess($VMName, 'Shut down VM normally')) {
                $vm = Get-CurrentPowerVM
                if ($vm.State -eq 'Off') { Write-Host "Already Off: $VMName"; return }
                if ($vm.State -ne 'Running') { throw 'VM state changed; normal shutdown was not attempted.' }
                $job = Stop-VM -VM $vm -AsJob -Confirm:$false
                try {
                    $null = Wait-Job $job -Timeout 120
                    if ($job.State -ne 'Completed') { throw 'Normal shutdown did not finish; no forced power-off attempted.' }
                    Receive-Job $job | Out-Null
                    if ((Get-VM -Id $id).State -ne 'Off') { throw 'VM has not reached Off; no forced power-off attempted.' }
                } finally { if ($job.State -eq 'Running') { Stop-Job $job }; Remove-Job $job -Force }
            }
        }
        Get-VM -Id $id | Select-Object Name, State
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
