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
    if ($properties.Count -ne 4) { throw 'Saved Packer recovery payload is incomplete.' }
    foreach ($entry in $properties) {
        if ($entry.Name -notin @('ubuntu.pkr.hcl', 'Ubuntu-Setup.ps1', 'Ubuntu-Packer.ps1', 'finalize-account.sh') -or $entry.Value -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid saved Packer payload entry.' }
        $path = Join-Path (Join-Path $Record.Root 'payload') $entry.Name
        Assert-UbuntuPath $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.Value) { throw 'Saved Packer payload changed; installation retained.' }
    }
}
function Get-UbuntuPacker {
    $directory = Join-Path $env:ProgramData 'Workstation\Tools\Packer\1.16.2'
    Assert-UbuntuPath $directory
    $mutex = New-Object Threading.Mutex($false, 'Global\Workstation-Packer-1.16.2')
    $locked = $false
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    $partial = $null; $zip = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is preparing Packer. Retry after it finishes.' }
        if (-not (Test-Path -LiteralPath $directory)) {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            }
            [IO.Directory]::CreateDirectory($directory, $acl) | Out-Null
        }
        $acl = Get-Acl -LiteralPath $directory
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Packer directory has an unexpected owner; retained for inspection.' }
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Packer directory permits unprivileged writes; retained for inspection.' }
        }
        $archive = Join-Path $directory 'packer.zip'
        Assert-UbuntuPath $archive
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path -LiteralPath $archive)) {
            $partial = $archive + '.' + [guid]::NewGuid().ToString('N') + '.partial'
            $ProgressPreference = 'SilentlyContinue'
            Write-Host 'Downloading pinned Packer 1.16.2 for Workstation (no PATH changes)...'
            Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 600 -Uri 'https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_windows_amd64.zip' -OutFile $partial
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine '1b3984ae7f5954cc3ae416b527ae5c5a747ea7bb7977366038609199be4a2710') { throw 'Packer archive checksum mismatch.' }
            [IO.File]::Move($partial, $archive)
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine '1b3984ae7f5954cc3ae416b527ae5c5a747ea7bb7977366038609199be4a2710') { throw 'Cached Packer archive checksum mismatch; file retained.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        $entry = $zip.GetEntry('packer.exe')
        if (-not $entry) { throw 'Pinned Packer archive is missing packer.exe.' }
        $hasher = [Security.Cryptography.SHA256]::Create()
        $stream = $entry.Open()
        try { $expected = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $hasher.Dispose() }
        $executable = Join-Path $directory 'packer.exe'
        Assert-UbuntuPath $executable
        if (-not (Test-Path -LiteralPath $executable)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $executable, $false) }
        if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ine $expected) { throw 'Packer executable differs from the pinned archive; file retained.' }
        return $executable
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial }
        [Net.ServicePointManager]::SecurityProtocol = $protocol
        if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
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
        $record.Address = $address
        $record.Phase = 'Account'
        Save-UbuntuText $RecordPath ($record | ConvertTo-Json -Depth 8)
    } finally { if (Test-Path -LiteralPath $processPath) { Remove-Item -LiteralPath $processPath } }
}

function Invoke-UbuntuPacker([object]$Record, [string]$RecordPath, [bool]$OpenConsole) {
    $packer = Get-UbuntuPacker
    $directory = Split-Path -Parent $packer
    $payload = Join-Path $Record.Root 'payload'
    $template = Join-Path $payload 'ubuntu.pkr.hcl'
    $commands = @{}
    foreach ($action in @('Register-UbuntuPackerVM', 'Complete-UbuntuPackerBuild')) {
        $setupPath = (Join-Path $payload 'Ubuntu-Setup.ps1').Replace("'", "''")
        $packerPath = (Join-Path $payload 'Ubuntu-Packer.ps1').Replace("'", "''")
        $program = '$ErrorActionPreference="Stop"; $ProgressPreference="SilentlyContinue"; Import-Module Hyper-V; . ''' + $setupPath + '''; . ''' + $packerPath + '''; ' + $action + ' -RecordPath ''' + $RecordPath.Replace("'", "''") + ''''
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
    $variablesPath = Join-Path $payload 'build.pkrvars.json'
    Save-UbuntuText $variablesPath ($variables | ConvertTo-Json -Depth 8)
    $saved = @{}
    foreach ($name in @('PACKER_PLUGIN_PATH', 'PACKER_CACHE_DIR', 'PACKER_CONFIG', 'PACKER_LOG', 'PACKER_LOG_PATH', 'Path', 'PSModulePath', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:PACKER_PLUGIN_PATH = Join-Path $directory 'plugins'
        $env:PACKER_CACHE_DIR = Join-Path $env:ProgramData 'Workstation\Media\Packer'
        $env:PACKER_CONFIG = Join-Path $directory 'config.json'
        $env:PACKER_LOG = '0'; $env:PACKER_LOG_PATH = $null
        $system = [Environment]::SystemDirectory
        $env:Path = "$system;$system\WindowsPowerShell\v1.0;$system\OpenSSH"
        $env:PSModulePath = Join-Path $system 'WindowsPowerShell\v1.0\Modules'
        $env:TEMP = Join-Path $Record.Root 'packer-temp'; $env:TMP = $env:TEMP
        foreach ($path in @($env:PACKER_PLUGIN_PATH, $env:PACKER_CACHE_DIR, $env:TEMP)) { Assert-UbuntuPath $path; New-Item -ItemType Directory -Path $path -Force | Out-Null }
        Save-UbuntuText $env:PACKER_CONFIG '{}'
        $pluginMutex = New-Object Threading.Mutex($false, 'Global\Workstation-Packer-Plugins-1.16.2')
        $pluginLocked = $false
        try {
            try { $pluginLocked = $pluginMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $pluginLocked = $true }
            if (-not $pluginLocked) { throw 'Another VM is initializing Packer plugins. Retry after it finishes.' }
            & $packer init $template
            if ($LASTEXITCODE -ne 0) { throw 'Pinned Packer Hyper-V plugin initialization failed.' }
        } finally { if ($pluginLocked) { $pluginMutex.ReleaseMutex() }; $pluginMutex.Dispose() }
        & $packer validate ("-var-file=$variablesPath") $template
        if ($LASTEXITCODE -ne 0) { throw 'Packer configuration validation failed; no build started.' }
        # Packer must never retry creation against a guest left by a previous run.
        if (@(Get-VM | Where-Object Name -eq $Record.Name).Count) { throw 'VM name appeared before Packer build; existing VM preserved.' }
        $machines = Join-Path $Record.Root 'machines'
        if ((Test-Path -LiteralPath $machines) -and @(Get-ChildItem -LiteralPath $machines -Force).Count) { throw 'Previous build files exist. Inspect them instead of creating another VM.' }
        $Record.Phase = 'Building'; Save-UbuntuText $RecordPath ($Record | ConvertTo-Json -Depth 8)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $packer
        $start.Arguments = 'build -on-error=abort -var-file="' + $variablesPath + '" "' + $template + '"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $false
        $process = [Diagnostics.Process]::Start($start)
        $processPath = Join-Path $Record.Root 'packer-process.json'
        try {
            Save-UbuntuText $processPath (@{ Id = $process.Id; Started = $process.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json)
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw 'Packer build stopped. VM and recovery payload retained; rerun to resume the recorded guest, not rebuild it.' }
        } finally {
            if ($process.HasExited -and (Test-Path -LiteralPath $processPath)) { Remove-Item -LiteralPath $processPath }
            $process.Dispose()
        }
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

function Remove-UbuntuPackerExport([object]$Record) {
    $directory = Join-Path $Record.Root 'export'
    Assert-UbuntuPath $directory
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $boundary = [IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
    foreach ($vm in @(Get-VM)) {
        $versions = @(@{ VM = $vm; Snapshot = $false })
        $versions += @(Get-VMSnapshot -VM $vm | ForEach-Object { @{ VM = $_; Snapshot = $true } })
        foreach ($version in $versions) {
            $configuration = [IO.Path]::GetFullPath($version.VM.Path).TrimEnd('\')
            if ($configuration -ieq $directory -or $configuration.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'A VM or checkpoint uses the temporary export; files retained.' }
            $disks = if ($version.Snapshot) { @(Get-VMHardDiskDrive -VMSnapshot $version.VM) } else { @(Get-VMHardDiskDrive -VM $version.VM) }
            $dvds = if ($version.Snapshot) { @(Get-VMDvdDrive -VMSnapshot $version.VM) } else { @(Get-VMDvdDrive -VM $version.VM) }
            foreach ($dvd in $dvds) { if ($dvd.Path -and [IO.Path]::GetFullPath($dvd.Path).StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'A VM references temporary export media; files retained.' } }
            foreach ($disk in $disks) {
                $path = $disk.Path; $seen = @{}
                while ($path) {
                    $path = [IO.Path]::GetFullPath($path)
                    if ($path.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'A VM disk chain uses the temporary export; files retained.' }
                    if ($seen.ContainsKey($path)) { throw 'Disk-chain cycle; export cleanup refused.' }
                    $seen[$path] = $true; $path = (Get-VHD -Path $path).ParentPath
                }
            }
        }
    }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($directory)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked export content; cleanup refused.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    # Only the redundant Packer export; the registered VM keeps its original disks.
    Remove-Item -LiteralPath $directory -Recurse -Force
}
