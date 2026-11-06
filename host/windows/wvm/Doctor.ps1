#Requires -Version 5.1
<#
.SYNOPSIS
Read-only, best-effort diagnostics. No guest commands, repairs or cleanup are run.
#>
function Get-DoctorValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Add-DoctorFinding($Report, [string]$Status, [string]$Area, [string]$Check, [string]$Value, [string]$Recommendation) {
    $Report.Findings.Add([pscustomobject]@{ Status=$Status; Area=$Area; Check=$Check; Value=$Value; Recommendation=$Recommendation })
}

function ConvertTo-DoctorGiB($Bytes) {
    if ($null -ne $Bytes) { [Math]::Round([double]$Bytes / 1GB, 2) }
}

function Assert-DoctorPath([string]$Path) {
    if ($Path -notmatch '^[a-zA-Z]:[\\/]') { throw 'Only absolute local drive paths are inspected.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Linked paths are not inspected.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Read-DoctorRecord([string]$Path) {
    Assert-DoctorPath $Path
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1MB) { throw 'Expected a small metadata file.' }
    # Read only known metadata names, never setup payloads, keys or Packer variables.
    if ($file.Name -notin @('ubuntu-vm.json','windows-vm.json','image.json','network-policy.json')) {
        throw 'Not a diagnostic metadata file.'
    }
    try { Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Metadata is unreadable or invalid JSON: $Path" }
}

function Invoke-DoctorProbe($Report, [string]$Area, [scriptblock]$Probe) {
    try { & $Probe } catch {
        if ($_.Exception -is [IO.InvalidDataException]) {
            Add-DoctorFinding $Report WARN $Area 'Mismatch' $_.Exception.Message 'Review saved policy and live adapter settings; doctor did not repair anything.'
        } else { Add-DoctorFinding $Report UNKNOWN $Area 'Unavailable' $_.Exception.Message 'Check access/provider availability; doctor did not repair anything.' }
    }
}

function Get-DoctorDiskChain([string]$Path, $References, $Disks) {
    $visited = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    while ($Path) {
        Assert-DoctorPath $Path
        $Path = [IO.Path]::GetFullPath($Path)
        if (-not $visited.Add($Path) -or $visited.Count -gt 64) { throw 'Disk chain is cyclic or exceeds the diagnostic limit.' }
        $References.Add($Path) | Out-Null
        if (-not $Disks.ContainsKey($Path)) {
            $disk = Get-VHD -Path $Path -ErrorAction Stop
            $Disks[$Path] = [pscustomobject]@{
                Path=$Path; FileGiB=(ConvertTo-DoctorGiB $disk.FileSize); CapacityGiB=(ConvertTo-DoctorGiB $disk.Size)
                Type=[string]$disk.VhdType; Parent=[string]$disk.ParentPath
            }
        }
        $Path = [string]$Disks[$Path].Parent
    }
}

function Get-DoctorCacheSize([string]$Path, $Budget) {
    Assert-DoctorPath $Path
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Path)
    $size = [pscustomobject]@{ Bytes=0L; Files=0; Complete=$true }
    $partials = New-Object 'Collections.Generic.List[object]'
    while ($stack.Count) {
        if ($Budget.Entries -ge 20000 -or $Budget.Watch.Elapsed.TotalSeconds -ge 5) { $size.Complete = $false; break }
        $directory = $stack.Pop()
        # Recheck queued directories: do not follow junctions or symbolic links.
        try {
            Assert-DoctorPath $directory
            # Consume the pipeline incrementally; foreach (... in Get-ChildItem ...) buffers the whole directory first.
            Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | ForEach-Object {
                if ($Budget.Entries -ge 20000 -or $Budget.Watch.Elapsed.TotalSeconds -ge 5) { throw [OperationCanceledException]::new('Cache traversal budget reached.') }
                $Budget.Entries++
                $entry = $_
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $size.Complete = $false; return }
                if ($entry.PSIsContainer) { $stack.Push($entry.FullName) }
                else {
                    $size.Bytes += $entry.Length; $size.Files++
                    if ($entry.Name -like '*.partial' -and $partials.Count -lt 25) { $partials.Add($entry) }
                }
            }
        } catch { $size.Complete = $false }
    }
    [pscustomobject]@{ Path=$Path; LogicalGiB=(ConvertTo-DoctorGiB $size.Bytes); Files=$size.Files; Complete=$size.Complete; Partials=$partials.ToArray() }
}

function Get-DoctorCounterDelta($Before, $After) {
    # These disk counters are uint32 and can wrap during a short sample.
    $delta = [double]$After - [double]$Before
    if ($delta -lt 0) { $delta += 4294967296.0 }
    return $delta
}

function Invoke-DoctorPerformance($Report, [bool]$HyperVAvailable) {
    $samples = New-Object 'Collections.Generic.List[object]'
    $unavailable = New-Object 'Collections.Generic.HashSet[string]'
    for ($i = 0; $i -lt 3; $i++) {
        if ($i) { Start-Sleep -Seconds 5 }
        $raw = @(); $cpuLoad = $null
        if (-not $unavailable.Contains('Disk')) {
            try { $raw = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -OperationTimeoutSec 5 -ErrorAction Stop) }
            catch {
                $unavailable.Add('Disk') | Out-Null
                Add-DoctorFinding $Report UNKNOWN Disk 'Performance counters' $_.Exception.Message 'Disk sampling is unavailable; independent CPU/VM sampling continues.'
            }
        }
        if (-not $unavailable.Contains('CPU')) {
            try {
                $cpu = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $null -ne $_.LoadPercentage })
                if (-not $cpu.Count) { throw 'No processor load readings.' }
                $cpuLoad = ($cpu | Measure-Object -Property LoadPercentage -Average).Average
            } catch {
                $unavailable.Add('CPU') | Out-Null
                Add-DoctorFinding $Report UNKNOWN CPU 'Performance counters' $_.Exception.Message 'Host CPU sampling is unavailable; independent disk/VM sampling continues.'
            }
        }
        $usage = @{}
        if ($HyperVAvailable -and -not $unavailable.Contains('VM')) {
            try { foreach ($vm in @(Get-VM -ErrorAction Stop)) { $usage[[string]$vm.Id] = [double]$vm.CPUUsage } }
            catch {
                $unavailable.Add('VM') | Out-Null
                Add-DoctorFinding $Report UNKNOWN HyperV 'VM CPU sample' $_.Exception.Message 'The initial VM inventory remains in the report; sampled VM CPU is incomplete.'
            }
        }
        $samples.Add([pscustomobject]@{ Disks=$raw; CPU=$cpuLoad; VMs=$usage })
        if ($unavailable.Contains('Disk') -and $unavailable.Contains('CPU') -and (-not $HyperVAvailable -or $unavailable.Contains('VM'))) { break }
    }
    $validCPU = @($samples | Where-Object { $null -ne $_.CPU })
    if ($validCPU.Count) {
        $average = [Math]::Round(($validCPU | Measure-Object -Property CPU -Average).Average, 1)
        $status = if ($average -ge 85) { 'WARN' } else { 'INFO' }
        Add-DoctorFinding $Report $status CPU 'Windows CPU sample' "$average% mean across $($validCPU.Count) readings" 'Short host-OS sample, not total hypervisor utilization or proof of a CPU bottleneck.'
    }
    foreach ($row in $Report.VMs) {
        $values = @($samples | Where-Object { $_.VMs.ContainsKey($row.Id) } | ForEach-Object { $_.VMs[$row.Id] })
        if ($values.Count) { $row.SampleCPUPercent = [Math]::Round(($values | Measure-Object -Average).Average, 1) }
    }
    $first = $samples[0]; $last = $samples[$samples.Count-1]
    foreach ($after in @($last.Disks | Where-Object Name -ne '_Total')) {
        $before = @($first.Disks | Where-Object Name -eq $after.Name)
        if ($before.Count -ne 1) { continue }
        if ($after.Frequency_PerfTime -le 0 -or $after.Frequency_PerfTime -ne $before[0].Frequency_PerfTime) { continue }
        $seconds = ([double]$after.Timestamp_PerfTime - [double]$before[0].Timestamp_PerfTime) / [double]$after.Frequency_PerfTime
        if ($seconds -le 0) { continue }
        $ops = Get-DoctorCounterDelta $before[0].AvgDisksecPerTransfer_Base $after.AvgDisksecPerTransfer_Base
        $latency = $null
        if ($ops -gt 0) {
            $ticks = Get-DoctorCounterDelta $before[0].AvgDisksecPerTransfer $after.AvgDisksecPerTransfer
            $latency = [Math]::Round(1000 * $ticks / [double]$after.Frequency_PerfTime / $ops, 2)
        }
        $bytes = [double]$after.DiskBytesPersec - [double]$before[0].DiskBytesPersec
        if ($bytes -lt 0) { continue }
        $queues = @($samples | ForEach-Object { $_.Disks | Where-Object Name -eq $after.Name } | Measure-Object -Property CurrentDiskQueueLength -Average)
        $Report.DiskPerformance.Add([pscustomobject]@{
            Disk=$after.Name; Seconds=[Math]::Round($seconds,1); LatencyMs=$latency
            MiBPerSecond=[Math]::Round($bytes / $seconds / 1MB,2); MeanQueue=[Math]::Round($queues[0].Average,2)
        })
        if ($null -ne $latency -and $latency -ge 20) {
            Add-DoctorFinding $Report WARN Disk 'Latency sample' "$($after.Name): $latency ms" 'Investigate sustained latency under the actual workload; this short sample does not establish a bottleneck.'
        }
    }
    if (-not $Report.DiskPerformance.Count -and -not $unavailable.Contains('Disk')) {
        Add-DoctorFinding $Report UNKNOWN Disk 'Performance intervals' 'No usable physical-disk intervals' 'Counters were empty, reset or did not cover an increasing time interval.'
    }
}

function Test-DoctorSSHPort([string]$Address, [int]$TimeoutMs) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($ip) -or $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224 -or $Address -like '169.254.*') {
        throw 'No usable guest-reported IPv4 address.'
    }
    $client = New-Object Net.Sockets.TcpClient
    $pending = $null
    try {
        $pending = $client.BeginConnect($ip, 22, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        if ($_.Exception.GetBaseException() -is [Net.Sockets.SocketException]) { return $false }
        throw
    } finally {
        $client.Close()
        if ($pending) { $pending.AsyncWaitHandle.Close() }
    }
}

function Invoke-DoctorUbuntuPolicy($Report, $Record, $VM) {
    $root = [string]$Record.Root
    $adapters = @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)
    if ($adapters.Count -ne 1) { throw [IO.InvalidDataException]::new('Expected one adapter for the recorded Ubuntu policy.') }
    $adapter = $adapters[0]
    $state = Read-DoctorRecord (Join-Path $root 'network-policy.json')
    if ($state.Schema -ne 1 -or $state.Phase -cne 'Applied' -or $state.VMId -ine [string]$VM.Id -or $state.Token -cne $Record.Token -or $state.AdapterId -cne $adapter.Id) { throw [IO.InvalidDataException]::new('Network policy identity/phase differs from the live VM.') }
    $topology = Get-UbuntuNetworkTopology $Record.SwitchName
    if (($state.Topology | ConvertTo-Json -Depth 6 -Compress) -cne ($topology | ConvertTo-Json -Depth 6 -Compress)) { throw [IO.InvalidDataException]::new('Network topology differs from the saved policy.') }
    $expected = @(Get-UbuntuNetworkRules $topology)
    $actual = Get-UbuntuAdapterRules $adapter
    try {
        Assert-UbuntuNetworkRules $actual @($state.Extended) @($state.Mac) -Exact
        Assert-UbuntuNetworkRules $actual $expected @() -Exact
    } catch { throw [IO.InvalidDataException]::new('Live ACLs, the policy journal and the current recipe do not agree.') }
    if (-not (Test-UbuntuAdapterGuards $adapter)) { throw [IO.InvalidDataException]::new('Network adapter guard settings differ.') }
    Add-DoctorFinding $Report OK Network $VM.Name 'Isolation ACLs/topology/guards match the current recipe' 'Configuration check only; guest-to-host/LAN blocking and internet traffic were not tested.'
}

function Invoke-DoctorUbuntuSSH($Report, $Record, $VM, [bool]$Detailed, $ProbeBudget) {
    $adapters = @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)
    $address = [string](Get-DoctorValue $Record Address '')
    $reported = @($adapters | ForEach-Object IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $matchesAddress = $address -and $address -in $reported
    $status = if ($matchesAddress) { 'OK' } elseif ([string]$VM.State -ne 'Running') { 'INFO' } else { 'WARN' }
    Add-DoctorFinding $Report $status SSH $VM.Name "Recorded=$address; reported=$($reported -join ', ')" 'No IP discovery scan or SSH configuration refresh is performed.'
    if ($Record.OwnerSID -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        $configPath = Join-Path $HOME '.ssh\config'
        Assert-DoctorPath $configPath
        $matchesConfig = $false
        if (Test-Path -LiteralPath $configPath) {
            if ((Get-Item -LiteralPath $configPath).Length -gt 1MB) { throw 'SSH config exceeds the diagnostic size limit.' }
            $text = [IO.File]::ReadAllText($configPath)
            $pattern = '(?ms)^# BEGIN Workstation Ubuntu ' + [regex]::Escape($Record.Token) + '\r?\n(.*?)^# END Workstation Ubuntu ' + [regex]::Escape($Record.Token) + '(?:\r?\n|$)'
            $blocks = [regex]::Matches($text, $pattern)
            if ($blocks.Count -eq 1) {
                $body = $blocks[0].Groups[1].Value
                $matchesConfig = $body -match ('(?m)^Host ' + [regex]::Escape($Record.Name) + '\r?$') -and $body -match ('(?m)^\s+HostName ' + [regex]::Escape($address) + '\r?$')
            }
        }
        $status = if ($matchesConfig) { 'OK' } else { 'WARN' }
        Add-DoctorFinding $Report $status SSH ($VM.Name + ' alias') ([string]$matchesConfig) 'Only the managed config block is compared; Includes/Match/ProxyCommand are never executed and credentials are not read.'
    } else { Add-DoctorFinding $Report INFO SSH ($VM.Name + ' alias') 'Another owner' 'Run as the VM owner to inspect their managed SSH alias.' }
    if ($Detailed -and [string]$VM.State -eq 'Running' -and $matchesAddress) {
        $remaining = 5000 - [int]$ProbeBudget.ElapsedMilliseconds
        if ($remaining -gt 0) {
            $ProbeBudget.Start()
            try { $open = Test-DoctorSSHPort $address ([Math]::Min(1000,$remaining)) }
            finally { $ProbeBudget.Stop() }
            $status = if ($open) { 'OK' } else { 'WARN' }
            Add-DoctorFinding $Report $status SSH ($VM.Name + ' TCP/22') ([string]$open) 'TCP reachability only: SSH server identity, authentication and guest health were not verified.'
        } else { Add-DoctorFinding $Report UNKNOWN SSH ($VM.Name + ' TCP/22') 'Probe budget exhausted' 'Detailed mode limits combined connection waits to five seconds.' }
    }
}

function Invoke-WVMDoctor {
    [CmdletBinding()]
    param([switch]$Detailed, [switch]$AsObject, [string]$VMRoot, [string]$ImageRoot = "$env:ProgramData\Workstation\Images")
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $report = [pscustomobject]@{
        Timestamp=[DateTime]::UtcNow.ToString('o'); Detailed=[bool]$Detailed; InventoryComplete=$false; ReferencesComplete=$false
        Findings=(New-Object 'Collections.Generic.List[object]'); VMs=(New-Object 'Collections.Generic.List[object]')
        Disks=(New-Object 'Collections.Generic.List[object]'); Volumes=(New-Object 'Collections.Generic.List[object]')
        Network=(New-Object 'Collections.Generic.List[object]'); Cache=(New-Object 'Collections.Generic.List[object]')
        Cleanup=(New-Object 'Collections.Generic.List[object]'); DiskPerformance=(New-Object 'Collections.Generic.List[object]')
    }
    $inventory = [pscustomobject]@{ Items=@() }
    $diskMap = @{}; $vmDiskReferences = @{}
    $sshBudget = New-Object Diagnostics.Stopwatch
    $networkAvailable = $false
    try {
        # This file defines the existing policy helpers; call only its read/compare functions.
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'hyperv\ubuntu-26-04\Ubuntu-Network.ps1')
        $networkAvailable = $true
    } catch { Add-DoctorFinding $report UNKNOWN Network 'Policy helpers' 'Unavailable' 'The checkout must include the Ubuntu network policy implementation.' }
    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $references = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stores = @("$env:ProgramData\Workstation\WindowsVMs", "$env:ProgramData\Workstation\UbuntuVMs", (Join-Path $ImageRoot '.builds'))
    if ($VMRoot) { $stores += $VMRoot }
    foreach ($path in @($ImageRoot) + $stores) {
        if ($path -notmatch '^[a-zA-Z]:[\\/]') { throw 'Doctor storage roots must be absolute local drive paths.' }
    }

    Invoke-DoctorProbe $report Host {
        $hostInfo = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
        if ($null -eq $osInfo.FreePhysicalMemory -or $null -eq $osInfo.TotalVisibleMemorySize -or $osInfo.TotalVisibleMemorySize -le 0) { throw 'Host memory counters are unavailable.' }
        $free = [double]$osInfo.FreePhysicalMemory * 1KB
        $total = [double]$osInfo.TotalVisibleMemorySize * 1KB
        $reserve = [Math]::Max(2GB, $total * 0.1)
        $status = if ($free -lt $reserve) { 'WARN' } else { 'OK' }
        Add-DoctorFinding $report $status Memory 'Host RAM' "Total=$(ConvertTo-DoctorGiB $total) GiB; available=$(ConvertTo-DoctorGiB $free) GiB; estimated VM headroom=$(ConvertTo-DoctorGiB ([Math]::Max(0,$free-$reserve))) GiB" 'Headroom reserves max(2 GiB, 10% RAM); it is a sizing hint, not an allocation guarantee.'
        Add-DoctorFinding $report INFO CPU 'Host processors' "$($hostInfo.NumberOfLogicalProcessors) logical processors; hypervisor present=$($hostInfo.HypervisorPresent)" 'VM vCPU counts are allocations, not reserved physical cores.'
    }
    Invoke-DoctorProbe $report CPU {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $null -ne $_.LoadPercentage })
        if (-not $processors.Count) { throw 'Windows processor load is unavailable.' }
        $load = ($processors | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $load) { throw 'Windows processor load is unavailable.' }
        Add-DoctorFinding $report $(if ($load -ge 85) {'WARN'} else {'INFO'}) CPU 'Windows CPU snapshot' "$([Math]::Round($load,1))%" 'Host-OS load is not total hypervisor utilization; use Detailed to collect multiple readings.'
    }
    Invoke-DoctorProbe $report HyperV {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        Add-DoctorFinding $report INFO Access 'Administrator' ([string]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Normal users get a partial report if Hyper-V, CIM or protected metadata access is denied; no elevation is attempted.'
        $service = Get-Service -Name vmms -ErrorAction Stop
        Add-DoctorFinding $report $(if ($service.Status -eq 'Running') {'OK'} else {'WARN'}) HyperV 'VM management service' ([string]$service.Status) 'Doctor does not start services or enable Windows features.'
        Import-Module Hyper-V -ErrorAction Stop
        $inventory.Items = @(Get-VM -ErrorAction Stop)
        $report.InventoryComplete = $true
    }
    $vms = @($inventory.Items)
    Invoke-DoctorProbe $report HyperV {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        Add-DoctorFinding $report $(if ($feature.State -eq 'Enabled') {'OK'} else {'WARN'}) HyperV 'Windows feature' ([string]$feature.State) 'Restart explicitly if Windows reports a pending feature transition.'
    }
    $report.ReferencesComplete = $report.InventoryComplete
    foreach ($vm in $vms) {
        Invoke-DoctorProbe $report ('VM ' + $vm.Name) {
            $memory = $null
            try { $memory = Get-VMMemory -VM $vm -ErrorAction Stop }
            catch { Add-DoctorFinding $report UNKNOWN Memory $vm.Name $_.Exception.Message 'VM state and CPU remain available; dynamic-memory configuration could not be read.' }
            $report.VMs.Add([pscustomobject]@{
                Name=$vm.Name; Id=[string]$vm.Id; State=[string]$vm.State; CPUs=$vm.ProcessorCount; CPUPercent=$vm.CPUUsage; SampleCPUPercent=$null
                AssignedGiB=(ConvertTo-DoctorGiB $vm.MemoryAssigned); StartupGiB=(ConvertTo-DoctorGiB $vm.MemoryStartup)
                DemandGiB=(ConvertTo-DoctorGiB (Get-DoctorValue $vm MemoryDemand)); MemoryStatus=(Get-DoctorValue $vm MemoryStatus 'Unavailable')
                Dynamic=(Get-DoctorValue $memory DynamicMemoryEnabled); MinimumGiB=(ConvertTo-DoctorGiB (Get-DoctorValue $memory Minimum)); MaximumGiB=(ConvertTo-DoctorGiB (Get-DoctorValue $memory Maximum))
            })
            if ([string]$vm.State -eq 'Running' -and [string](Get-DoctorValue $vm MemoryStatus '') -notin @('','OK')) {
                Add-DoctorFinding $report WARN Memory $vm.Name ([string]$vm.MemoryStatus) 'Investigate guest memory demand; host metrics do not identify guest applications.'
            }
            foreach ($integration in @(Get-VMIntegrationService -VM $vm -ErrorAction Stop)) {
                if ($integration.Enabled -and [string]$vm.State -eq 'Running' -and [string]$integration.PrimaryStatusDescription -notin @('OK','')) {
                    Add-DoctorFinding $report INFO Integration ($vm.Name + '/' + $integration.Name) ([string]$integration.PrimaryStatusDescription) 'Reported integration state; optional/unsupported guest services can legitimately be unavailable.'
                }
            }
        }
        $diskReferences = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $vmDiskReferences[[string]$vm.Id] = $diskReferences
        try {
            $states = @($vm) + @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
            if ($states.Count -gt 1) { $report.Cleanup.Add([pscustomobject]@{ Path=$vm.Path; Kind='Checkpoint chain'; Assessment='Review only'; Reason="$($states.Count-1) checkpoints; never delete AVHDX files directly." }) }
            for ($index = 0; $index -lt $states.Count; $index++) {
                $target = if ($index -eq 0) { @{ VM=$states[$index] } } else { @{ VMSnapshot=$states[$index] } }
                foreach ($drive in @(Get-VMHardDiskDrive @target -ErrorAction Stop)) {
                    if ($drive.Path) { Get-DoctorDiskChain $drive.Path $diskReferences $diskMap }
                    else { $report.ReferencesComplete = $false; throw 'Non-file-backed disk cannot be included in file-reference coverage.' }
                }
                foreach ($dvd in @(Get-VMDvdDrive @target -ErrorAction Stop)) { if ($dvd.Path) { $references.Add([IO.Path]::GetFullPath($dvd.Path)) | Out-Null } }
            }
        } catch {
            $report.ReferencesComplete = $false
            Add-DoctorFinding $report UNKNOWN Disks $vm.Name $_.Exception.Message 'Disk/reference coverage is partial; no file can be declared safe to delete.'
        } finally { foreach ($diskPath in $diskReferences) { $references.Add($diskPath) | Out-Null } }
        Invoke-DoctorProbe $report ('Network ' + $vm.Name) {
            foreach ($adapter in @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)) {
                $report.Network.Add([pscustomobject]@{ VM=$vm.Name; Adapter=$adapter.Name; Switch=$adapter.SwitchName; IPs=(@($adapter.IPAddresses) -join ', ') })
                if (-not $adapter.SwitchName) { Add-DoctorFinding $report WARN Network $vm.Name 'Disconnected adapter' 'Review the intended switch; doctor does not reconnect it.' }
            }
        }
        Invoke-DoctorProbe $report ('Record ' + $vm.Name) {
            $cursor = [IO.Path]::GetFullPath($vm.Path)
            while ($cursor) {
                Assert-DoctorPath $cursor
                $found = $false
                foreach ($name in @('windows-vm.json','ubuntu-vm.json')) {
                    $path = Join-Path $cursor $name
                    if (Test-Path -LiteralPath $path) { $paths.Add($path) | Out-Null; $found = $true }
                }
                if ($found) { break }
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
        }
    }
    foreach ($store in @($stores | Sort-Object -Unique)) {
        Invoke-DoctorProbe $report Records {
            if (Test-Path -LiteralPath $store) {
                $directories = @(Get-ChildItem -LiteralPath $store -Directory -Force -ErrorAction Stop | Select-Object -First 201)
                if ($directories.Count -gt 200) { Add-DoctorFinding $report UNKNOWN Records $store 'Scan limited to 200 directories' 'Metadata coverage is partial.' }
                foreach ($directory in @($directories | Select-Object -First 200)) {
                    Invoke-DoctorProbe $report Records {
                        Assert-DoctorPath $directory.FullName
                        foreach ($name in @('windows-vm.json','ubuntu-vm.json')) {
                            $path = Join-Path $directory.FullName $name
                            if (Test-Path -LiteralPath $path) { $paths.Add($path) | Out-Null }
                        }
                    }
                }
            }
        }
    }
    foreach ($path in $paths) {
        Invoke-DoctorProbe $report Records {
            $record = Read-DoctorRecord $path
            foreach ($property in @('Schema','Name','VMId','Root','DiskPath','Guest','Token','Phase')) {
                if ($null -eq (Get-DoctorValue $record $property)) { throw "Incomplete VM metadata: $path" }
            }
            if ($record.Schema -ne 1 -or $record.Root -ine (Split-Path -Parent $path) -or $record.Token -cnotmatch '^[a-f0-9]{32}$') { throw "Unsupported/inconsistent VM metadata: $path" }
            if ($record.Phase -ne 'Complete') {
                Add-DoctorFinding $report INFO Recovery $record.Name ([string]$record.Phase) 'Setup or image build is not finalized; it may be active or recoverable.'
                $report.Cleanup.Add([pscustomobject]@{ Path=$record.Root; Kind='Build/recovery data'; Assessment='Review only'; Reason='Preserve until installation activity and recovery needs have been established.' })
            }
            $live = @($vms | Where-Object { [string]$_.Id -ieq $record.VMId })
            $matchesLocation = $false
            if ($live.Count -eq 1) {
                $recordRoot = [IO.Path]::GetFullPath($record.Root).TrimEnd('\')
                $configRoot = [IO.Path]::GetFullPath($live[0].Path).TrimEnd('\')
                $matchesLocation = $configRoot -ieq $recordRoot -or $configRoot.StartsWith($recordRoot + '\',[StringComparison]::OrdinalIgnoreCase)
            }
            if (-not $report.InventoryComplete) { throw "Cannot compare VM identity without inventory: $path" }
            if ($live.Count -ne 1) {
                Add-DoctorFinding $report WARN Records $record.Name "No registered VM for record; phase=$($record.Phase)" 'Recovery data retained; absence from this inventory is not proof of safe deletion.'
                $report.Cleanup.Add([pscustomobject]@{ Path=$record.Root; Kind='Unregistered record/build'; Assessment='Review only'; Reason='May contain recoverable disks or an active/paused installation.' })
            } elseif (-not $matchesLocation -or $live[0].Name -cne $record.Name -or $live[0].Notes -cne ('Workstation ' + $record.Guest + ' VM ' + $record.Token)) {
                Add-DoctorFinding $report WARN Records $record.Name 'VM ID/name/configuration location/ownership note differs' 'Inspect identity before any lifecycle action.'
            } else {
                Add-DoctorFinding $report OK Records $record.Name ('Identity matches; phase=' + $record.Phase) 'Only identity is checked here; no setup resume is attempted.'
                $attached = @(Get-VMHardDiskDrive -VM $live[0] -ErrorAction Stop | ForEach-Object Path)
                if ($record.DiskPath) {
                    Assert-DoctorPath $record.DiskPath
                    $recordedDisk = [IO.Path]::GetFullPath($record.DiskPath)
                    if ($recordedDisk -notin $attached -and -not $vmDiskReferences[[string]$live[0].Id].Contains($recordedDisk)) {
                        $status = if ($report.ReferencesComplete) { 'WARN' } else { 'UNKNOWN' }
                        Add-DoctorFinding $report $status Disks $record.Name 'Recorded disk not observed in this VM disk chain' 'Check current attachments and parent chains; unreadable chains cannot establish a mismatch.'
                    }
                }
                if ($record.Guest -eq 'Ubuntu' -and $record.Phase -eq 'Complete') {
                    if ($networkAvailable) { Invoke-DoctorProbe $report ('Ubuntu policy ' + $record.Name) { Invoke-DoctorUbuntuPolicy $report $record $live[0] } }
                    Invoke-DoctorProbe $report ('Ubuntu SSH ' + $record.Name) { Invoke-DoctorUbuntuSSH $report $record $live[0] ([bool]$Detailed) $sshBudget }
                }
            }
            if ($record.DiskPath) {
                Assert-DoctorPath $record.DiskPath
                if (-not (Test-Path -LiteralPath $record.DiskPath)) { Add-DoctorFinding $report WARN Disks $record.Name 'Recorded disk file missing' 'Preserve recovery metadata; doctor does not rebuild or adopt disks.' }
            }
        }
    }
    foreach ($disk in $diskMap.Values) { $report.Disks.Add($disk) }
    Invoke-DoctorProbe $report Storage {
        foreach ($volume in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 5 -ErrorAction Stop)) {
            $percent = if ($null -ne $volume.FreeSpace -and $null -ne $volume.Size -and $volume.Size -gt 0) { [Math]::Round(100 * [double]$volume.FreeSpace / [double]$volume.Size,1) } else { $null }
            $report.Volumes.Add([pscustomobject]@{ Drive=$volume.DeviceID; TotalGiB=(ConvertTo-DoctorGiB $volume.Size); FreeGiB=(ConvertTo-DoctorGiB $volume.FreeSpace); FreePercent=$percent })
            if ($null -eq $percent) { Add-DoctorFinding $report UNKNOWN Storage $volume.DeviceID 'Volume capacity counters unavailable' 'Missing capacity is not reported as zero free space.' }
            if ($null -ne $percent -and ($percent -lt 10 -or $volume.FreeSpace -lt 10GB)) {
                Add-DoctorFinding $report WARN Storage $volume.DeviceID "Free=$percent% / $(ConvertTo-DoctorGiB $volume.FreeSpace) GiB" 'Capacity warning threshold: below 10% or 10 GiB; review growth and storage before creating another VM.'
            }
        }
    }
    $running = @($vms | Where-Object { [string]$_.State -eq 'Running' })
    if ($report.InventoryComplete) {
        $assigned = ($vms | Measure-Object -Property MemoryAssigned -Sum).Sum
        $cpus = ($running | Measure-Object -Property ProcessorCount -Sum).Sum
        Add-DoctorFinding $report INFO Resources 'VM allocation' "Assigned RAM=$(ConvertTo-DoctorGiB $assigned) GiB; running VM vCPUs=$cpus" 'Allocation is not utilization; saved/off VMs do not reserve their startup RAM.'
        if (-not $vms.Count) { Add-DoctorFinding $report INFO HyperV Inventory 'No registered VMs' 'No VM disk/guest checks apply.' }
    }
    if ($Detailed) {
        Invoke-DoctorProbe $report Performance { Invoke-DoctorPerformance $report $report.InventoryComplete }
        $budget = [pscustomobject]@{ Entries=0; Watch=[Diagnostics.Stopwatch]::StartNew() }
        $cacheRoots = @($ImageRoot, "$env:ProgramData\Workstation\Media", "$env:ProgramData\Workstation\Tools")
        $inspectedRoots = New-Object 'Collections.Generic.List[string]'
        foreach ($root in @($cacheRoots | Sort-Object -Unique | Sort-Object Length)) {
            $canonical = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
            if (@($inspectedRoots | Where-Object { $canonical.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count) {
                Add-DoctorFinding $report INFO Cache $root 'Covered by a parent cache root' 'Overlapping stores are not sized twice; refer to the parent total and its completeness flag.'
                continue
            }
            Invoke-DoctorProbe $report Cache {
                if (Test-Path -LiteralPath $root) {
                    $size = Get-DoctorCacheSize $root $budget
                    $inspectedRoots.Add($canonical)
                    $report.Cache.Add(($size | Select-Object Path,LogicalGiB,Files,Complete))
                    foreach ($partial in $size.Partials) { $report.Cleanup.Add([pscustomobject]@{ Path=$partial.FullName; Kind='Partial download'; Assessment='Review only'; Reason='Could belong to an active or recoverable build; no deletion eligibility inferred.' }) }
                    if (-not $size.Complete) { Add-DoctorFinding $report UNKNOWN Cache $root 'Partial size only' 'A link, access failure or shared 20,000-entry/five-second traversal limit prevented complete sizing.' }
                }
            }
        }
        Invoke-DoctorProbe $report Cache {
            $mediaRoot = "$env:ProgramData\Workstation\Media"
            if (Test-Path -LiteralPath $mediaRoot) {
                Assert-DoctorPath $mediaRoot
                $media = @(Get-ChildItem -LiteralPath $mediaRoot -File -Filter '*.iso' -ErrorAction Stop | Select-Object -First 26)
                if ($media.Count -gt 25) { Add-DoctorFinding $report UNKNOWN Cache $mediaRoot 'ISO review list limited to 25 entries' 'Additional cached media were not included in the review list.' }
                foreach ($file in @($media | Select-Object -First 25)) {
                    Assert-DoctorPath $file.FullName
                    $assessment = if ($references.Contains($file.FullName)) { 'Registered reference' } elseif ($report.ReferencesComplete) { 'No registered reference observed' } else { 'Reference coverage unavailable' }
                    $report.Cleanup.Add([pscustomobject]@{ Path=$file.FullName; Kind='Reusable ISO'; Assessment=$assessment; Reason='Review only: an unmounted ISO may still be needed for rebuilds or recovery.' })
                }
            }
            foreach ($family in @('windows-pro','ubuntu-26-04')) {
                $familyRoot = Join-Path $ImageRoot $family
                if (-not (Test-Path -LiteralPath $familyRoot)) { continue }
                Assert-DoctorPath $familyRoot
                $versions = @(Get-ChildItem -LiteralPath $familyRoot -Directory -ErrorAction Stop | Select-Object -First 201)
                if ($versions.Count -gt 200) { Add-DoctorFinding $report UNKNOWN Cache $familyRoot 'Image metadata limited to 200 versions' 'Additional versions were not inspected.' }
                foreach ($version in @($versions | Select-Object -First 200)) {
                    Invoke-DoctorProbe $report Images {
                        Assert-DoctorPath $version.FullName
                        $manifest = Join-Path $version.FullName 'image.json'
                        if (-not (Test-Path -LiteralPath $manifest)) {
                            $report.Cleanup.Add([pscustomobject]@{ Path=$version.FullName; Kind='Unpublished image'; Assessment='Review only'; Reason='Incomplete publication/recovery data may still be needed.' })
                            return
                        }
                        $image = Read-DoctorRecord $manifest
                        if ((Get-DoctorValue $image Schema) -ne 1 -or (Get-DoctorValue $image Phase) -ne 'Ready') { throw "Unexpected image manifest: $manifest" }
                        $disk = Join-Path $version.FullName 'base.vhdx'
                        Assert-DoctorPath $disk
                        if (-not (Test-Path -LiteralPath $disk)) { Add-DoctorFinding $report WARN Images $version.Name 'Published base disk missing' 'Preserve the manifest and investigate; doctor does not rebuild it.' }
                        $assessment = if ($references.Contains($disk)) { 'Registered disk-chain reference' } elseif ($report.ReferencesComplete) { 'No registered disk-chain reference observed' } else { 'Reference coverage unavailable' }
                        $report.Cleanup.Add([pscustomobject]@{ Path=$version.FullName; Kind='Reusable base image'; Assessment=$assessment; Reason='Review only: partial clones, future creates and external backups are outside registered-reference coverage.' })
                    }
                }
            }
        }
        Add-DoctorFinding $report INFO Cache 'Cleanup scope' 'Logical file sizes only; shared/sparse files may not reclaim that amount' 'Images and media can be reused or needed for recovery. Review references; nothing is certified safe to delete.'
    } else { Add-DoctorFinding $report INFO Diagnostics 'Detailed checks' 'Not requested' 'Use wvm doctor -Detailed for a ten-second performance sample, bounded TCP/22 probes and cache sizing.' }
    Add-DoctorFinding $report INFO Diagnostics 'Reference coverage' ([string]$report.ReferencesComplete) 'Covers readable registered VM/checkpoint disk chains and mounted media only; excludes unregistered workloads and external backups.'
    if ($AsObject) { return $report }
    Write-Host ('WVM doctor - ' + $report.Timestamp)
    Write-Host 'Read-only snapshot. UNKNOWN means unavailable, not healthy. No repairs, guest commands or cleanup are performed.'
    if ($report.VMs.Count) {
        Write-Host "`nVM CPU and state"
        $columns = @('Name','State','CPUs','CPUPercent')
        if ($Detailed) { $columns += 'SampleCPUPercent' }
        $report.VMs | Select-Object $columns | Format-Table -AutoSize -Wrap | Out-Host
        Write-Host "`nVM memory"
        $report.VMs | Select-Object Name,AssignedGiB,StartupGiB,@{Name='DemandGiB';Expression={if ($null -eq $_.DemandGiB) {'n/a'} else {$_.DemandGiB}}},MemoryStatus | Format-Table -AutoSize -Wrap | Out-Host
        $report.VMs | Select-Object Name,Dynamic,MinimumGiB,MaximumGiB | Format-Table -AutoSize -Wrap | Out-Host
    }
    foreach ($section in @('Volumes','Disks','Network','DiskPerformance','Cache','Cleanup')) {
        if ($report.$section.Count) { Write-Host "`n$section"; $report.$section | Format-Table -AutoSize -Wrap | Out-Host }
    }
    Write-Host "`nFindings"
    foreach ($finding in $report.Findings) {
        Write-Host ("[{0}] {1} / {2}: {3}" -f $finding.Status,$finding.Area,$finding.Check,$finding.Value)
        Write-Host ('  Next: ' + $finding.Recommendation)
    }
}
