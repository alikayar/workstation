$packerRuntime = Join-Path $PSScriptRoot 'Packer.ps1'
if (-not (Test-Path -LiteralPath $packerRuntime)) { $packerRuntime = Join-Path $PSScriptRoot '..\shared\Packer.ps1' }
. $packerRuntime

function Save-WindowsVMRecord([object]$Record) {
    Save-PackerText (Join-Path $Record.Root 'windows-vm.json') ($Record | ConvertTo-Json -Depth 10)
}

function Assert-WindowsPackerPayload([object]$Record) {
    $names = @('windows-pro.pkr.hcl', 'Windows-Packer.ps1', 'Windows-Media.ps1', 'Windows-Unattend.ps1', 'Autounattend.xml', 'Packer.ps1')
    $entries = @($Record.PayloadHashes.PSObject.Properties)
    if ($entries.Count -ne $names.Count) { throw 'Incomplete Windows Packer recovery payload.' }
    foreach ($entry in $entries) {
        if ($entry.Name -cnotin $names -or $entry.Value -cnotmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid Windows Packer payload entry.' }
        $path = Join-Path (Join-Path $Record.Root 'payload') $entry.Name
        Assert-PackerPath $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.Value) { throw 'Saved Windows recovery payload changed; installation preserved.' }
    }
}

function Get-OwnedWindowsVM([object]$Record, [switch]$RegisterBuild) {
    if ($Record.Schema -notin @(1,2,3) -or $Record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Record.Token -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid Windows VM ownership.' }
    $vm = Get-VM | Where-Object Name -eq $Record.Name
    if (-not $vm) { throw 'Recorded Windows VM is missing; files preserved.' }
    if ($Record.VMId) {
        if ([string]$vm.Id -ne $Record.VMId -or $vm.Notes -cne ('Workstation Windows VM ' + $Record.Token)) { throw 'Windows VM identity changed; VM preserved.' }
    } elseif (-not $RegisterBuild -or $Record.Schema -ne 3 -or $Record.Phase -ne 'Building') { throw 'Unrecorded Windows VM will not be adopted.' }
    Assert-PlainPath $vm.Path
    $boundary = $Record.Root.TrimEnd('\') + '\'
    if ($vm.Path -ine $Record.Root -and -not $vm.Path.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Windows configuration escaped its installation directory.' }
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'Expected one file-backed Windows disk.' }
    $base = Join-Path $Record.Root 'windows.vhdx'
    if ($Record.Schema -eq 3) {
        if ($Record.Backend -cne 'Packer') { throw 'Unexpected Windows backend.' }
        $machines = Join-Path $Record.Root 'machines'
        if (-not $vm.Path.StartsWith(($machines + '\'), [StringComparison]::OrdinalIgnoreCase) -or -not $drives[0].Path.StartsWith(($machines + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Packer VM escaped its machines directory.' }
        if ($vm.Generation -ne 2 -or $vm.ProcessorCount -ne $Record.CPUs -or $vm.MemoryStartup -ne ($Record.MemoryGB * 1GB)) { throw 'Windows Packer resources differ from the record.' }
        if (@(Get-VMSnapshot -VM $vm).Count) { throw 'Unexpected Packer checkpoint; VM preserved.' }
        if (-not (Get-VMSecurity -VM $vm).TpmEnabled -or (Get-VMFirmware -VM $vm).SecureBoot -ne 'On' -or (Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions -ne $Record.Nested) { throw 'Windows Packer firmware/TPM/processor policy differs.' }
        if ($Record.DiskPath -and $Record.DiskPath -ine $drives[0].Path) { throw 'Windows Packer disk attachment changed.' }
        $base = $drives[0].Path
    }
    $path = $drives[0].Path; $seen = @{}
    do {
        $path = [IO.Path]::GetFullPath($path)
        Assert-PlainPath $path
        if (-not $path.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)) { throw 'Windows disk chain escaped or cycles; files preserved.' }
        $seen[$path] = $true
        $vhd = Get-VHD -Path $path
        if ($path -ieq $base) {
            if ($vhd.ParentPath -or $vhd.Size -ne ($Record.DiskGB * 1GB)) { throw 'Windows base disk differs; files preserved.' }
            break
        }
        if (-not $vhd.ParentPath) { throw 'Windows disk is not descended from its recorded base.' }
        $path = $vhd.ParentPath
    } while ($true)
    $adapters = @(Get-VMNetworkAdapter -VM $vm)
    if ($adapters.Count -ne 1 -or $adapters[0].SwitchName -cne $Record.SwitchName) { throw 'Windows VM network attachment changed.' }
    if (-not $Record.VMId) {
        $answer = Join-Path $Record.Root 'setup-secrets\answer.iso'
        Assert-PlainPath $answer
        if (@(Get-VMDvdDrive -VM $vm | Where-Object Path -eq $answer).Count -ne 1 -or (Get-FileHash -LiteralPath $answer).Hash -cne $Record.AnswerSha256) { throw 'Windows setup-media identity differs.' }
        Set-VM -VM $vm -Notes ('Workstation Windows VM ' + $Record.Token)
        $Record.VMId = [string]$vm.Id; $Record.DiskPath = $drives[0].Path
        Save-WindowsVMRecord $Record
    }
    return $vm
}

function Set-WindowsVMPolicy([object]$Record) {
    $vm = Get-OwnedWindowsVM $Record
    if ($vm.State -ne 'Off') { throw 'Windows VM must be Off before startup/checkpoint settings are applied.' }
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    $copy = @(Get-VMIntegrationService -VM $vm | Where-Object { ([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480', [StringComparison]::OrdinalIgnoreCase) })
    if ($copy.Count -ne 1) { throw 'Windows Guest Service Interface could not be identified.' }
    $copy[0] | Disable-VMIntegrationService
}

function Complete-WindowsSetupMedia([object]$Record) {
    if ($Record.Setup -eq 'Complete') { return }
    if ($Record.Setup -ne 'Verified') { throw 'Windows setup has not been verified; media preserved.' }
    $vm = Get-OwnedWindowsVM $Record
    $secret = Join-Path $Record.Root 'setup-secrets'
    $answer = Join-Path $secret 'answer.iso'
    Get-VMDvdDrive -VM $vm | Where-Object Path -eq $answer | Remove-VMDvdDrive
    Get-VMDvdDrive -VM $vm | Where-Object Path -eq $Record.IsoPath | Set-VMDvdDrive -Path $null
    Assert-PlainPath $answer
    if (Test-Path -LiteralPath $answer) { Remove-Item -LiteralPath $answer -Force }
    if ((Test-Path -LiteralPath $secret) -and @(Get-ChildItem -LiteralPath $secret -Force).Count -eq 0) { Remove-Item -LiteralPath $secret }
    $Record.Setup = 'Complete'; Save-WindowsVMRecord $Record
}

function Register-WindowsPackerVM([string]$RecordPath) {
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    Assert-WindowsPackerPayload $record
    $vm = Get-OwnedWindowsVM $record -RegisterBuild
    $copy = @(Get-VMIntegrationService -VM $vm | Where-Object { ([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480', [StringComparison]::OrdinalIgnoreCase) })
    if ($copy.Count -ne 1) { throw 'Windows Guest Service Interface could not be identified.' }
    $copy[0] | Disable-VMIntegrationService
    $processPath = Join-Path $record.Root 'setup-process.json'
    Save-PackerText $processPath (@{ Id = $PID; Started = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } | ConvertTo-Json)
    try {
        $deadline = (Get-Date).AddMinutes(55)
        do {
            $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
            $vm = Get-OwnedWindowsVM $record
            if ($record.Setup -eq 'Complete' -and $record.Phase -eq 'Ready' -and $vm.State -eq 'Off') { return }
            if ((Get-Date) -ge $deadline) { throw 'Windows verification parent did not finish; guest retained.' }
            $parentPath = Join-Path $record.Root 'packer-process.json'
            if (-not (Test-Path -LiteralPath $parentPath)) { throw 'Packer process record disappeared; guest retained.' }
            $parent = Get-Content -LiteralPath $parentPath -Raw | ConvertFrom-Json
            $process = Get-Process -Id $parent.Id -ErrorAction SilentlyContinue
            if (-not $process -or $process.StartTime.ToUniversalTime().Ticks -ne [long]$parent.Started) { throw 'Packer parent exited; guest retained.' }
            Start-Sleep -Seconds 2
        } while ($true)
    } finally { if (Test-Path -LiteralPath $processPath) { Remove-Item -LiteralPath $processPath } }
}

function Complete-WindowsPackerInstallation([object]$Record, [Management.Automation.PSCredential]$Credential, [scriptblock]$AssertActive) {
    if ($Record.Setup -eq 'Pending') {
        if (-not $Credential) { throw 'A credential is required to verify pending Windows Setup.' }
        Wait-WindowsSetup -VMId $Record.VMId -Token $Record.Token -DiskPath $Record.DiskPath -Credential $Credential -AssertActive $AssertActive
        $Record.Setup = 'Verified'; Save-WindowsVMRecord $Record
    }
    Complete-WindowsSetupMedia $Record
    $vm = Get-OwnedWindowsVM $Record
    if ($vm.State -eq 'Running') {
        $job = Stop-VM -VM $vm -AsJob -Confirm:$false
        try {
            $null = Wait-Job $job -Timeout 120
            if ($job.State -ne 'Completed') { throw 'Windows did not shut down normally; no power cut attempted.' }
            Receive-Job $job | Out-Null
        } finally { if ($job.State -eq 'Running') { Stop-Job $job }; Remove-Job $job -Force }
    }
    Set-WindowsVMPolicy $Record
    $Record.Phase = 'Ready'; Save-WindowsVMRecord $Record
}

function Complete-WindowsPackerParent([string]$RecordPath, [Management.Automation.PSCredential]$Credential, [object]$Process) {
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
        if ($record.VMId) { break }
        if ($Process.HasExited -or (Get-Date) -ge $deadline) { throw 'Packer did not register its Windows VM; unrecorded VMs are not adopted.' }
        Start-Sleep -Seconds 1
    } while ($true)
    Complete-WindowsPackerInstallation $record $Credential { if ($Process.HasExited) { throw 'Packer exited during Windows setup; VM retained.' } }
}

function Invoke-WindowsPacker([object]$Record, [Management.Automation.PSCredential]$Credential, [bool]$OpenConsole) {
    Assert-WindowsPackerPayload $Record
    $payload = Join-Path $Record.Root 'payload'
    $recordPath = Join-Path $Record.Root 'windows-vm.json'
    $program = '$ErrorActionPreference="Stop"; $ProgressPreference="SilentlyContinue"; Import-Module Hyper-V; '
    foreach ($name in @('Windows-Media.ps1', 'Windows-Packer.ps1')) { $program += '. ''' + (Join-Path $payload $name).Replace("'", "''") + '''; ' }
    $program += 'Register-WindowsPackerVM -RecordPath ''' + $recordPath.Replace("'", "''") + ''''
    $command = '"' + "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" + '" -NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    if ($command.Length -gt 7500) { throw 'Use a shorter Windows VMRoot path for the Packer host command.' }
    $variables = @{
        vm_name = $Record.Name; switch_name = $Record.SwitchName; cpus = $Record.CPUs
        memory_mb = $Record.MemoryGB * 1024; disk_mb = $Record.DiskGB * 1024
        state_dir = $Record.Root.Replace('\','/'); iso_path = $Record.IsoPath.Replace('\','/')
        answer_path = (Join-Path $Record.Root 'setup-secrets\answer.iso').Replace('\','/')
        host_command = $command; nested = $Record.Nested; headless = -not $OpenConsole
    }
    # The credential stays in this process; the Packer child receives only public paths and a registration command.
    Invoke-WorkstationPacker -Root $Record.Root -VMName $Record.Name -Template (Join-Path $payload 'windows-pro.pkr.hcl') -Variables $variables -BeforeBuild { $Record.Phase = 'Building'; Save-WindowsVMRecord $Record } -WhileRunning { param($process) Complete-WindowsPackerParent $recordPath $Credential $process }
}
