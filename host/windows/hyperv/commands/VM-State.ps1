# Shared by the command front end and its same-user Hyper-V worker.
function Get-VMStore {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("Workstation\" + $sid)
    $commands = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $user = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Workstation'
    return @{ Root = $root; Instances = (Join-Path $root 'Instances'); Images = (Join-Path $root 'Images'); Requests = (Join-Path $root 'Results'); Commands = $commands; Connections = (Join-Path $user 'Connections'); Editor = (Join-Path $user 'Editor') }
}
function Read-VMJson([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-VMJson([string]$Path, [object]$Value) {
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Assert-VMName([string]$Name) {
    if ($Name -notmatch '^[a-z][a-z0-9-]{0,30}[a-z0-9]$') { throw 'Use a VM name of 2-32 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit.' }
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
function Wait-VMAddress([string]$VMName) {
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $ips = @(Get-VMNetworkAdapter -VMName $VMName | ForEach-Object IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' })
        if ($ips.Count -gt 1) { throw 'Multiple guest IPv4 addresses; inspect networking.' }
        if ($ips.Count -eq 1) {
            $client = New-Object Net.Sockets.TcpClient
            try {
                if ($client.ConnectAsync($ips[0], 22).Wait(2000) -and $client.Connected) {
                    # ssh.socket can accept TCP before first-boot sshd is usable.
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 2000
                    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
                    try { if ($reader.ReadLine() -match '^SSH-2\.0-') { return $ips[0] } }
                    finally { $reader.Dispose() }
                }
            } catch { } finally { $client.Dispose() }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw 'Guest SSH is not ready. The VM and disk were retained; retry wvm open.'
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
