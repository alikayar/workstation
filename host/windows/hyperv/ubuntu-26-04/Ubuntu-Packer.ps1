$packerRuntime = Join-Path $PSScriptRoot 'Packer.ps1'
if (-not (Test-Path -LiteralPath $packerRuntime)) { $packerRuntime = Join-Path $PSScriptRoot '..\shared\Packer.ps1' }
. $packerRuntime

function Assert-UbuntuBuildIdle([string]$Root) {
    foreach ($name in @('packer-process.json', 'setup-process.json')) {
        $path = Join-Path $Root $name
        Assert-UbuntuPath $path
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Id -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$saved.Started) { throw 'A recorded Packer/setup process is still active. Wait for it to exit before resuming.' }
    }
}

function Assert-UbuntuPayload([object]$Record) {
    $properties = @($Record.PayloadHashes.PSObject.Properties)
    $names = @($properties | ForEach-Object Name)
    if ($properties.Count -lt 4 -or $properties.Count -gt 6 -or @(@('ubuntu.pkr.hcl', 'Ubuntu-Setup.ps1', 'Ubuntu-Packer.ps1', 'finalize-account.sh') | Where-Object { $_ -cnotin $names }).Count) { throw 'Saved Packer recovery payload is incomplete.' }
    foreach ($entry in $properties) {
        if ($entry.Name -notin @('ubuntu.pkr.hcl', 'Ubuntu-Setup.ps1', 'Ubuntu-Packer.ps1', 'Ubuntu-Network.ps1', 'Packer.ps1', 'finalize-account.sh') -or $entry.Value -cnotmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid saved Packer payload entry.' }
        $path = Join-Path (Join-Path $Record.Root 'payload') $entry.Name
        Assert-UbuntuPath $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.Value) { throw 'Saved Packer payload changed; installation retained.' }
    }
}

function Get-UbuntuOwnedVM([object]$Record, [switch]$RegisterBuild) {
    if ($Record.Schema -ne 2 -or $Record.Backend -cne 'Packer' -or $Record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Record.Token -notmatch '^[a-f0-9]{32}$') { throw 'Invalid Packer installation record.' }
    $vm = Get-VM | Where-Object Name -eq $Record.Name
    if (-not $vm) { throw 'Recorded Ubuntu VM is missing; installation files retained.' }
    if ($Record.VMId) {
        if ([string]$vm.Id -ne $Record.VMId -or $vm.Notes -cne ('Workstation Ubuntu VM ' + $Record.Token)) { throw 'Ubuntu VM identity changed; VM preserved.' }
    } elseif (-not $RegisterBuild -or $Record.Phase -ne 'Building') { throw 'Unrecorded VM will not be adopted on resume.' }
    $machines = Join-Path $Record.Root 'machines'
    if (-not ([IO.Path]::GetFullPath($vm.Path)).StartsWith(($machines + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Packer VM configuration escaped its installation directory.' }
    Assert-UbuntuPath $vm.Path
    if ($vm.Generation -ne 2 -or $vm.ProcessorCount -ne $Record.CPUs -or $vm.MemoryStartup -ne ($Record.MemoryGB * 1GB)) { throw 'Packer VM resources differ from the saved settings.' }
    if (@(Get-VMSnapshot -VM $vm).Count) { throw 'Unexpected VM checkpoint; retained for inspection.' }
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'Expected one file-backed Packer guest disk.' }
    $disk = [IO.Path]::GetFullPath($drives[0].Path)
    if (-not $disk.StartsWith(($machines + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Packer guest disk escaped its installation directory.' }
    if ($Record.DiskPath -and $Record.DiskPath -ine $disk) { throw 'Recorded Packer disk attachment changed.' }
    Assert-UbuntuPath $disk
    $vhd = Get-VHD -Path $disk
    if ($vhd.ParentPath -or $vhd.Size -ne ($Record.DiskGB * 1GB)) { throw 'Packer guest disk differs from its record.' }
    $adapters = @(Get-VMNetworkAdapter -VM $vm)
    if ($adapters.Count -ne 1 -or $adapters[0].SwitchName -cne $Record.SwitchName) { throw 'Packer VM network differs from its record.' }
    if (-not $Record.VMId) {
        $seed = Join-Path $Record.Root 'setup-secrets\seed.iso'
        Assert-UbuntuPath $seed
        if (@(Get-VMDvdDrive -VM $vm | Where-Object Path -eq $seed).Count -ne 1 -or (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash -cne $Record.SeedSha256) { throw 'Packer seed identity differs; VM preserved.' }
        $Record.VMId = [string]$vm.Id; $Record.DiskPath = $disk
        Set-VM -VM $vm -Notes ('Workstation Ubuntu VM ' + $Record.Token)
        Save-UbuntuText (Join-Path $Record.Root 'ubuntu-vm.json') ($Record | ConvertTo-Json -Depth 8)
    }
    return $vm
}

function Register-UbuntuPackerVM([string]$RecordPath) {
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    Assert-UbuntuPayload $record
    $vm = Get-UbuntuOwnedVM $record -RegisterBuild
    $copy = @(Get-VMIntegrationService -VM $vm | Where-Object { ([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480', [StringComparison]::OrdinalIgnoreCase) })
    if ($copy.Count -ne 1) { throw 'Guest Service Interface could not be identified.' }
    $copy[0] | Disable-VMIntegrationService
}

function Set-UbuntuVMPolicy([object]$Record) {
    $vm = Get-UbuntuOwnedVM $Record
    if ($vm.State -ne 'Off') { throw 'Ubuntu VM must be Off before applying its startup/checkpoint policy.' }
    # Apply settings only after shutdown; live reconfiguration can fail during guest boot.
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    $copy = @(Get-VMIntegrationService -VM $vm | Where-Object { ([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480', [StringComparison]::OrdinalIgnoreCase) })
    if ($copy.Count -ne 1) { throw 'Guest Service Interface could not be identified.' }
    $copy[0] | Disable-VMIntegrationService
}

function Complete-UbuntuPackerBuild([string]$RecordPath) {
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    Assert-UbuntuPayload $record
    $processPath = Join-Path $record.Root 'setup-process.json'
    Save-UbuntuText $processPath (@{ Id = $PID; Started = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } | ConvertTo-Json)
    try {
        $null = Get-UbuntuOwnedVM $record
        $key = Join-Path $record.Root 'ssh-ed25519'
        $knownHosts = Join-Path $record.Root 'known_hosts'
        $address = Wait-UbuntuAddress $record $key $knownHosts
        $ssh = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
        $options = @('-F', 'NUL', '-i', $key, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes', '-o', 'StrictHostKeyChecking=yes', '-o', ('HostKeyAlias=workstation-ubuntu-' + $record.Token), '-o', ('UserKnownHostsFile="' + $knownHosts.Replace('\', '/') + '"'), '-o', 'GlobalKnownHostsFile=NUL', '-o', 'ConnectTimeout=10')
        $preference = $ErrorActionPreference
        Wait-UbuntuFirstBoot -Ssh $ssh -Options $options -Target ($record.UserName + '@' + $address) -InstallationId $record.Token
        try {
            $ErrorActionPreference = 'Continue'
            & $ssh @options ($record.UserName + '@' + $address) 'sudo -n shutdown -P now'
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $preference }
        # Shutdown can close SSH before its exit status arrives; still require verified VM power-off below.
        if ($exitCode -notin @(0, 255)) { throw "Ubuntu shutdown request failed (exit $exitCode); no forced power-off was attempted." }
        $deadline = (Get-Date).AddMinutes(5)
        do {
            $vm = Get-UbuntuOwnedVM $record
            if ($vm.State -eq 'Off') { break }
            if ((Get-Date) -ge $deadline) { throw 'Ubuntu did not shut down gracefully. No forced power-off was attempted.' }
            Start-Sleep -Seconds 2
        } while ($true)
        Set-UbuntuVMPolicy $record
        Set-UbuntuNetworkPolicy $record
        $record.Address = $address
        $record.Phase = 'Account'
        Save-UbuntuText $RecordPath ($record | ConvertTo-Json -Depth 8)
    } finally { if (Test-Path -LiteralPath $processPath) { Remove-Item -LiteralPath $processPath } }
}

function Invoke-UbuntuPacker([object]$Record, [string]$RecordPath, [bool]$OpenConsole) {
    $payload = Join-Path $Record.Root 'payload'
    $template = Join-Path $payload 'ubuntu.pkr.hcl'
    $commands = @{}
    foreach ($action in @('Register-UbuntuPackerVM', 'Complete-UbuntuPackerBuild')) {
        $setupPath = (Join-Path $payload 'Ubuntu-Setup.ps1').Replace("'", "''")
        $packerPath = (Join-Path $payload 'Ubuntu-Packer.ps1').Replace("'", "''")
        $networkPath = (Join-Path $payload 'Ubuntu-Network.ps1').Replace("'", "''")
        $program = '$ErrorActionPreference="Stop"; $ProgressPreference="SilentlyContinue"; Import-Module Hyper-V; . ''' + $setupPath + '''; . ''' + $packerPath + '''; . ''' + $networkPath + '''; ' + $action + ' -RecordPath ''' + $RecordPath.Replace("'", "''") + ''''
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
        $commands[$action] = '"' + "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" + '" -NoLogo -NoProfile -OutputFormat Text -EncodedCommand ' + $encoded
        if ($commands[$action].Length -gt 7500) { throw 'Choose a shorter VMRoot path for Packer host commands.' }
    }
    $variables = @{
        vm_name = $Record.Name; switch_name = $Record.SwitchName; cpus = $Record.CPUs
        memory_mb = $Record.MemoryGB * 1024; disk_mb = $Record.DiskGB * 1024
        state_dir = $Record.Root.Replace('\', '/'); iso_path = $Record.IsoPath.Replace('\', '/')
        seed_path = (Join-Path $Record.Root 'setup-secrets\seed.iso').Replace('\', '/')
        register_command = $commands['Register-UbuntuPackerVM']; complete_command = $commands['Complete-UbuntuPackerBuild']
        headless = -not $OpenConsole
    }
    Invoke-WorkstationPacker -Root $Record.Root -VMName $Record.Name -Template $template -Variables $variables -BeforeBuild { $Record.Phase = 'Building'; Save-UbuntuText $RecordPath ($Record | ConvertTo-Json -Depth 8) }
}

function Remove-UbuntuPackerExport([object]$Record) { Remove-WorkstationPackerExport $Record }
