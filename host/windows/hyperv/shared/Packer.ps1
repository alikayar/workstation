function Assert-PackerPath([string]$Path) {
    if ($Path -match '["`$\r\n]') { throw 'Use Packer paths without quotes, backticks, dollar signs or line breaks.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked Packer path refused: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Save-PackerText([string]$Path, [string]$Content) {
    Assert-PackerPath $Path
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Assert-PackerIdle([string]$Root) {
    foreach ($name in @('packer-process.json', 'setup-process.json')) {
        $path = Join-Path $Root $name
        Assert-PackerPath $path
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Id -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$saved.Started) { throw 'A recorded Packer/setup process is still active; wait for it to exit.' }
    }
}

function Get-WorkstationPacker {
    $directory = Join-Path $env:ProgramData 'Workstation\Tools\Packer\1.16.2'
    Assert-PackerPath $directory
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
        Assert-PackerPath $archive
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
        Assert-PackerPath $executable
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


function Invoke-WorkstationPacker([string]$Root, [string]$VMName, [string]$Template, [hashtable]$Variables, [scriptblock]$WhileRunning, [scriptblock]$BeforeBuild) {
    foreach ($path in @($Root, $Template)) { Assert-PackerPath $path }
    Assert-PackerIdle $Root
    $packer = Get-WorkstationPacker
    $directory = Split-Path -Parent $packer
    $variablesPath = Join-Path $Root 'payload\build.pkrvars.json'
    Save-PackerText $variablesPath ($Variables | ConvertTo-Json -Depth 8)
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
        $env:TEMP = Join-Path $Root 'packer-temp'; $env:TMP = $env:TEMP
        foreach ($path in @($env:PACKER_PLUGIN_PATH, $env:PACKER_CACHE_DIR, $env:TEMP, (Join-Path $Root 'machines'))) { Assert-PackerPath $path; New-Item -ItemType Directory -Path $path -Force | Out-Null }
        Save-PackerText $env:PACKER_CONFIG '{}'
        $mutex = New-Object Threading.Mutex($false, 'Global\Workstation-Packer-Plugins-1.16.2')
        $locked = $false
        try {
            try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { throw 'Another VM is initializing Packer plugins; retry after it finishes.' }
            & $packer init $Template
            if ($LASTEXITCODE -ne 0) { throw 'Pinned Hyper-V plugin initialization failed.' }
        } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
        & $packer validate ("-var-file=$variablesPath") $Template
        if ($LASTEXITCODE -ne 0) { throw 'Packer configuration validation failed; no build started.' }
        if (@(Get-VM | Where-Object Name -eq $VMName).Count) { throw 'VM name already exists; no Packer build started.' }
        if (@(Get-ChildItem -LiteralPath (Join-Path $Root 'machines') -Force).Count) { throw 'Previous build files retained; a replacement VM will not be created.' }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $packer
        $start.Arguments = 'build -on-error=abort -var-file="' + $variablesPath + '" "' + $Template + '"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $false
        if ($BeforeBuild) { & $BeforeBuild }
        $process = [Diagnostics.Process]::Start($start)
        $processPath = Join-Path $Root 'packer-process.json'
        try {
            Save-PackerText $processPath (@{ Id = $process.Id; Started = $process.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json)
            if ($WhileRunning) { & $WhileRunning $process }
            if (-not $process.WaitForExit(3600000)) { throw 'Packer did not exit within one hour; VM and active-process record retained.' }
            if ($process.ExitCode -ne 0) { throw 'Packer stopped. VM and recovery files retained; resume the recorded guest without rebuilding.' }
        } finally {
            # A credential-owning parent may fail or be cancelled. Terminate only its Packer process, never the guest.
            if ($WhileRunning -and -not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) }
            if ($process.HasExited -and (Test-Path -LiteralPath $processPath)) { Remove-Item -LiteralPath $processPath }
            $process.Dispose()
        }
    } finally {
        foreach ($name in $saved.Keys) {
            $value = if ($null -eq $saved[$name]) { [NullString]::Value } else { $saved[$name] }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Remove-WorkstationPackerExport([object]$Record) {
    $directory = Join-Path $Record.Root 'export'
    Assert-PackerPath $directory
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
