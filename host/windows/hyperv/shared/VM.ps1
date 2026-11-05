. (Join-Path $PSScriptRoot 'Packer.ps1')

function Save-WVMRecord([object]$Record) {
    $name = if ($Record.Guest -eq 'Windows') { 'windows-vm.json' } else { 'ubuntu-vm.json' }
    Save-PackerText (Join-Path $Record.Root $name) ($Record | ConvertTo-Json -Depth 16)
}

function Assert-WVMRecord([object]$Record) {
    if ($Record.Schema -ne 1 -or $Record.Backend -cnotin @('Image','Packer') -or $Record.Guest -cnotin @('Windows','Ubuntu')) {
        throw 'Unsupported VM record; this command uses the base-image workflow.'
    }
    if ($Record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Record.Token -cnotmatch '^[a-f0-9]{32}$') {
        throw 'VM ownership record differs.'
    }
}

function Get-WVMOwnedVM([object]$Record, [switch]$RegisterBuild) {
    Assert-WVMRecord $Record
    $vm = Get-VM | Where-Object Name -eq $Record.Name
    if (-not $vm) { throw 'Recorded VM is missing.' }
    if ($Record.VMId) {
        if ([string]$vm.Id -ne $Record.VMId -or $vm.Notes -cne ('Workstation ' + $Record.Guest + ' VM ' + $Record.Token)) {
            throw 'VM identity changed.'
        }
    } elseif (-not $RegisterBuild -or $Record.Backend -cne 'Packer' -or $Record.Phase -cne 'Building') {
        throw 'Unrecorded VM cannot be adopted.'
    }
    $boundary = (Join-Path $Record.Root 'machines') + '\'
    Assert-PackerPath $vm.Path
    if (-not ([IO.Path]::GetFullPath($vm.Path)).StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'VM configuration is outside its machines directory.'
    }
    if ($vm.Generation -ne 2 -or $vm.ProcessorCount -ne $Record.CPUs -or $vm.MemoryStartup -ne ($Record.MemoryGB * 1GB)) {
        throw 'VM resources differ from the record.'
    }
    if (@(Get-VMSnapshot -VM $vm).Count) { throw 'Unexpected VM checkpoint.' }
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'Expected one file-backed VM disk.' }
    $disk = [IO.Path]::GetFullPath($drives[0].Path)
    Assert-PackerPath $disk
    if (-not $disk.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or ($Record.DiskPath -and $Record.DiskPath -ine $disk)) {
        throw 'VM disk attachment differs.'
    }
    $vhd = Get-VHD -Path $disk
    if ($vhd.ParentPath -or $vhd.Size -ne ($Record.DiskGB * 1GB)) { throw 'Expected the recorded standalone disk.' }
    $adapters = @(Get-VMNetworkAdapter -VM $vm)
    if ($adapters.Count -ne 1 -or $adapters[0].SwitchName -cne $Record.SwitchName) { throw 'VM network attachment differs.' }
    if ($Record.Guest -eq 'Windows' -and (-not (Get-VMSecurity -VM $vm).TpmEnabled -or (Get-VMFirmware -VM $vm).SecureBoot -ne 'On' -or (Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions -ne $Record.Nested)) {
        throw 'Windows firmware, TPM or processor policy differs.'
    }
    if (-not $Record.VMId) {
        $windows = $Record.Guest -eq 'Windows'
        $seed = Join-Path $Record.Root $(if ($windows) { 'setup-secrets\answer.iso' } else { 'setup-secrets\seed.iso' })
        $hash = if ($windows) { $Record.AnswerSha256 } else { $Record.SeedSha256 }
        Assert-PackerPath $seed
        if (@(Get-VMDvdDrive -VM $vm | Where-Object Path -eq $seed).Count -ne 1 -or (Get-FileHash -LiteralPath $seed).Hash -cne $hash) {
            throw 'Builder setup-media identity differs.'
        }
        Set-VM -VM $vm -Notes ('Workstation ' + $Record.Guest + ' VM ' + $Record.Token)
        $Record.VMId = [string]$vm.Id
        $Record.DiskPath = $disk
        Save-WVMRecord $Record
    }
    return $vm
}
