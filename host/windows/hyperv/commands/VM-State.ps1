# Shared by the command front end and its same-user Hyper-V worker.
function Get-VMStore {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("Workstation\" + $sid)
    $commands = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $user = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Workstation'
    $programs = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('Workstation\' + $sid)
    $settingsPath = Join-Path $commands 'settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        $settings = Read-VMJson $settingsPath
        if ($settings.PSObject.Properties.Name -contains 'ValidationId' -and $settings.ValidationId) {
            if ($settings.ValidationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid protected validation scope.' }
            $suffix = 'Validation\' + $settings.ValidationId
            $root = Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Workstation') $suffix
            $user = Join-Path $user $suffix
            $programs = Join-Path $programs $suffix
        }
    }
    return @{ ProgramRoot = $programs; UserRoot = $user; Root = $root; Instances = (Join-Path $root 'Instances'); Images = (Join-Path $root 'Images'); Requests = (Join-Path $root 'Results'); Commands = $commands; Connections = (Join-Path $user 'Connections'); Editor = (Join-Path $user 'Editor') }
}
function Read-VMJson([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-VMJson([string]$Path, [object]$Value) {
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Assert-VMName([string]$Name) {
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{0,30}[a-z0-9]$') { throw 'Use a VM name of 2-32 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit.' }
}
function Assert-VMPath([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $boundary = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside its managed directory: $full" }
    $ancestor = $full
    while ($ancestor.Length -ge $boundary.TrimEnd('\').Length) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not supported: $ancestor" }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        if (-not $ancestor) { break }
    }
    return $full
}
function Assert-VMTree([string]$Directory, [string]$Parent) {
    $null = Assert-VMPath $Directory $Parent
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($Directory)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked entry blocks removal: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
}
function Get-ManagedInstance([string]$Name) {
    Assert-VMName $Name
    $store = Get-VMStore
    $directory = Assert-VMPath (Join-Path $store.Instances $Name) $store.Instances
    $path = Join-Path $directory 'instance.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "No managed temporary VM named '$Name'. Existing Hyper-V VMs are never adopted." }
    $record = Read-VMJson $path
    if ($record.Schema -ne 1 -or $record.Kind -ne 'Temporary' -or $record.Name -cne $Name -or $record.VMName -cne "ws-$Name" -or $record.Id -notmatch '^[a-f0-9]{32}$' -or $record.ImageId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid temporary VM record; inspect it before continuing.' }
    return @{ Directory = $directory; Path = $path; Record = $record }
}
function Get-ManagedHyperV([object]$Instance) {
    $record = $Instance.Record
    $vm = Get-VM -Name $record.VMName -ErrorAction SilentlyContinue
    if ($vm) {
        if (-not $record.VMId -or [string]$vm.Id -cne $record.VMId) { throw 'Hyper-V identity differs from the managed record; the VM was left unchanged.' }
        $null = Assert-VMPath $vm.Path $Instance.Directory
        $image = Join-Path (Get-VMStore).Images $record.ImageId
        $base = Assert-VMPath (Join-Path $image 'base.vhdx') (Get-VMStore).Images
        foreach ($disk in Get-VMHardDiskDrive -VM $vm) {
            if (-not $disk.Path) { throw 'Unmanaged pass-through disk attached; inspect the VM.' }
            $path = Assert-VMPath $disk.Path $Instance.Directory
            $seen = @{}
            while ($true) {
                if ($seen.ContainsKey($path)) { throw 'Cyclic disk chain.' }
                $seen[$path] = $true
                $vhd = Get-VHD -Path $path -ErrorAction Stop
                if (-not $vhd.ParentPath) { throw 'Temporary VM disk no longer points to its recorded image.' }
                $path = [IO.Path]::GetFullPath($vhd.ParentPath)
                if ($path -ieq $base) { break }
                $null = Assert-VMPath $path $Instance.Directory
            }
        }
    }
    return $vm
}
function Test-VMSSHBanner([string]$Address) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        if (-not $client.ConnectAsync($Address, 22).Wait(2000) -or -not $client.Connected) { return $false }
        # ssh.socket can accept TCP before first-boot sshd is usable.
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        try { return ($reader.ReadLine() -match '^SSH-2\.0-') }
        finally { $reader.Dispose() }
    } catch { return $false } finally { $client.Dispose() }
}
function Wait-VMAddress([string]$VMName, [scriptblock]$VerifyIdentity, [string]$ExpectedVMId) {
    $deadline = (Get-Date).AddMinutes(5)
    do {
        if ($ExpectedVMId -and [string](Get-VM -Name $VMName -ErrorAction Stop).Id -cne $ExpectedVMId) { throw 'Hyper-V identity changed while waiting for networking.' }
        $ips = @(Get-VMNetworkAdapter -VMName $VMName | ForEach-Object IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } | Sort-Object -Unique)
        if ($ips.Count -gt 1 -and -not $VerifyIdentity) { throw 'Multiple guest IPv4 addresses; inspect networking.' }
        foreach ($address in $ips) {
            if (Test-VMSSHBanner $address) {
                if (-not $VerifyIdentity -or (& $VerifyIdentity $address)) { return $address }
            }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw 'Guest SSH identity is not ready. The VM and disk were retained; retry wvm open.'
}
function Assert-NoOtherDiskUsers([object]$Instance, [object]$VM) {
    $prefix = $Instance.Directory.TrimEnd('\') + '\'
    foreach ($other in Get-VM) {
        if ($VM -and $other.Id -eq $VM.Id) { continue }
        foreach ($disk in Get-VMHardDiskDrive -VM $other) {
            $path = $disk.Path
            $seen = @{}
            while ($path) {
                $path = [IO.Path]::GetFullPath($path)
                if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Another VM references this VM's disk: $($other.Name). Nothing was removed." }
                if ($seen.ContainsKey($path)) { throw 'Cyclic disk chain blocks safe removal.' }
                $seen[$path] = $true
                $path = (Get-VHD -Path $path -ErrorAction Stop).ParentPath
            }
        }
    }
}

# The delete journal lives outside the directory being removed. An interrupted
# recursive delete can otherwise lose instance.json before its disk is removed.
function Restore-VMDeletionRecord([string]$Name, [string]$Journal, [string]$Directory) {
    Assert-VMName $Name
    $store = Get-VMStore
    $null = Assert-VMPath $Journal (Join-Path $store.Root 'Locks')
    $null = Assert-VMPath $Directory $store.Instances
    if (-not (Test-Path -LiteralPath $Journal)) { return }
    $record = Read-VMJson $Journal
    if ($record.Schema -ne 1 -or $record.Kind -ne 'Temporary' -or $record.Name -cne $Name -or $record.VMName -cne ('ws-' + $Name) -or $record.Id -cnotmatch '^[a-f0-9]{32}$' -or $record.ImageId -cnotmatch '^[a-f0-9]{32}$' -or $record.Phase -ne 'Deleting') { throw 'Invalid deletion journal. Existing data was preserved.' }
    $path = Join-Path $Directory 'instance.json'
    if (Test-Path -LiteralPath $path) {
        $current = Read-VMJson $path
        if ($current.Id -cne $record.Id -or $current.VMId -cne $record.VMId) { throw 'Deletion journal belongs to a different VM generation. Nothing was removed.' }
    } else {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        Write-VMJson $path $record
    }
}

function Initialize-VMHostIdentity([string]$Directory) {
    $store = Get-VMStore
    $key = Assert-VMPath (Join-Path $Directory 'ssh_host_ed25519_key') $store.Instances
    $null = Assert-VMPath ($key + '.pub') $store.Instances
    if (-not (Test-Path -LiteralPath $key)) {
        if (Test-Path -LiteralPath ($key + '.pub')) { throw 'Guest host public key exists without its private key. Restore the pair; identity was not replaced.' }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh-keygen.exe'
        $start.Arguments = '-q -t ed25519 -N "" -f "' + $key + '"'
        $start.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($start)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Could not create the unique guest SSH host identity.' }
    }
    if (-not (Test-Path -LiteralPath ($key + '.pub'))) { throw 'Guest host public key is missing. Restore it before resuming.' }
    return $key
}
function Save-VMHostPin([string]$Path, [string]$Address, [string]$PublicKey) {
    if ($Address -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $PublicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: [^\r\n]*)?$') { throw 'Invalid guest SSH host identity.' }
    $parts = $PublicKey -split ' '
    $entry = "$Address $($parts[0]) $($parts[1])"
    $content = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $existing = @($content -split '\r?\n' | Where-Object { $_ -match ('^' + [regex]::Escape($Address) + '\s') })
    if ($existing.Count -and @($existing | Where-Object { $_.Trim() -cne $entry }).Count) { throw 'Recorded SSH host key differs. The pin was preserved; inspect the VM identity.' }
    if (-not $existing.Count) { [IO.File]::WriteAllText($Path, ($content.TrimEnd() + "`n" + $entry + "`n").TrimStart("`n"), (New-Object Text.UTF8Encoding($false))) }
}

# Capture native stderr without treating diagnostic output as a terminating
# PowerShell 5.1 error. Callers decide success from ExitCode, never from stderr.
function Invoke-VMNative([string]$FilePath, [string[]]$ArgumentList) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    return @{ ExitCode = $exitCode; Output = $output }
}

# Each generated address belongs to one installation, independent of its name.
# The host-wide lock covers collision discovery and adapter assignment together.
function Set-VMNetworkIdentity([object]$VM, [string]$MacAddress) {
    if ($MacAddress -cnotmatch '^02[A-F0-9]{10}$') { throw 'Invalid managed MAC address.' }
    $store = Get-VMStore
    $lock = [IO.File]::Open((Join-Path $store.Root 'Locks\network.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $adapters = @(Get-VMNetworkAdapter -VM $VM)
        if ($adapters.Count -ne 1) { throw 'Expected one managed network adapter.' }
        $other = @(Get-VM | Where-Object { $_.Id -ne $VM.Id } | Get-VMNetworkAdapter)
        $other += @(Get-VMNetworkAdapter -ManagementOS)
        if (@($other | Where-Object { ($_.MacAddress -replace '[:-]', '') -ieq $MacAddress }).Count) { throw 'Managed MAC address is already in use. No adapter was changed.' }
        Set-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -StaticMacAddress $MacAddress
    } finally { $lock.Dispose() }
}
