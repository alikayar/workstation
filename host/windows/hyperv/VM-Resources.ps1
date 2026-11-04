# Non-secret resource inputs. setup.ps1 saves these before requesting elevation.
function ConvertTo-WorkstationResource {
    param([string]$Name, [string]$Value, [int]$Minimum, [int]$Maximum)
    $number = 0
    if ($Value -notmatch '^[0-9]+$' -or -not [int]::TryParse($Value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
    return $number
}

function Get-WorkstationResource {
    param([string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return ConvertTo-WorkstationResource $Name $value $Minimum $Maximum
}

function Get-WorkstationVMResources {
    param([object]$SavedResources)
    $resources = @{}
    foreach ($entry in @(
        @{ Name = 'CPUs'; Env = 'WORKSTATION_VM_CPUS'; Default = 4; Minimum = 2; Maximum = 64 },
        @{ Name = 'MemoryMB'; Env = 'WORKSTATION_VM_MEMORY_MB'; Default = 8192; Minimum = 4096; Maximum = 131072 },
        @{ Name = 'DiskGB'; Env = 'WORKSTATION_VM_DISK_GB'; Default = 80; Minimum = 40; Maximum = 2048 }
    )) {
        $default = $entry.Default
        if ($null -ne $SavedResources) {
            $default = ConvertTo-WorkstationResource $entry.Name $SavedResources.($entry.Name) $entry.Minimum $entry.Maximum
        }
        $value = Get-WorkstationResource $entry.Env $default $entry.Minimum $entry.Maximum
        if ($null -ne $SavedResources -and $value -ne $default) {
            throw "$($entry.Env) differs from the saved installation. Setup does not resize existing VMs."
        }
        $resources[$entry.Name] = $value
    }
    return [pscustomobject]$resources
}

function Read-WorkstationVMResources {
    param([Parameter(Mandatory)][object]$Defaults)
    $resources = @{}
    foreach ($entry in @(
        @{ Name = 'CPUs'; Label = 'VM CPU count'; Minimum = 2; Maximum = 64 },
        @{ Name = 'MemoryMB'; Label = 'VM memory (MiB)'; Minimum = 4096; Maximum = 131072 },
        @{ Name = 'DiskGB'; Label = 'VM disk (GiB)'; Minimum = 40; Maximum = 2048 }
    )) {
        $default = $Defaults.($entry.Name)
        while ($true) {
            $answer = Read-Host "$($entry.Label) [$default]"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = [string]$default }
            try {
                $resources[$entry.Name] = ConvertTo-WorkstationResource $entry.Label $answer.Trim() $entry.Minimum $entry.Maximum
                break
            } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
        }
    }
    return [pscustomobject]$resources
}
