# Non-secret resource inputs. setup.ps1 saves these before requesting elevation.
function Get-WorkstationResource {
    param([string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    $number = 0
    if ($value -notmatch '^[0-9]+$' -or -not [int]::TryParse($value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
    return $number
}

function Get-WorkstationVMResources {
    return [pscustomobject]@{
        CPUs = Get-WorkstationResource WORKSTATION_VM_CPUS 4 2 64
        MemoryMB = Get-WorkstationResource WORKSTATION_VM_MEMORY_MB 8192 4096 131072
        DiskGB = Get-WorkstationResource WORKSTATION_VM_DISK_GB 80 40 2048
    }
}
