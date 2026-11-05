. (Join-Path $PSScriptRoot 'VM.ps1')
. (Join-Path $PSScriptRoot 'BaseImage.ps1')
. (Join-Path $PSScriptRoot 'Seed-ISO.ps1')
. (Join-Path $PSScriptRoot '..\windows-pro\Windows-Media.ps1')
. (Join-Path $PSScriptRoot '..\windows-pro\Windows-Unattend.ps1')
. (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Setup.ps1')
. (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Network.ps1')

function Get-WVMCloneSources([string]$Guest) {
    $sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $sources=if($Guest -eq 'Windows'){
        @{'Windows-Unattend.ps1'='windows-pro\Windows-Unattend.ps1';'Autounattend.xml'='windows-pro\Autounattend.xml';'Windows-Image.ps1'='windows-pro\image\Windows-Image.ps1'}
    }else{@{'Ubuntu-Clone.ps1'='ubuntu-26-04\image\Ubuntu-Clone.ps1';'finalize-account.sh'='ubuntu-26-04\finalize-account.sh'}}
    $result=@{};foreach($entry in $sources.GetEnumerator()){$result[$entry.Key]=Join-Path $sourceRoot $entry.Value}
    return $result
}

function Get-WVMCloneHashes([string]$Guest) {
    $hashes=@{};foreach($entry in (Get-WVMCloneSources $Guest).GetEnumerator()){$hashes[$entry.Key]=(Get-FileHash -LiteralPath $entry.Value).Hash}
    return [pscustomobject]$hashes
}

function Set-WVMClonePayload([object]$Record) {
    $sources=Get-WVMCloneSources $Record.Guest
    if(@($Record.ClonePayloadHashes.PSObject.Properties).Count -ne $sources.Count){throw 'Clone payload manifest is incomplete.'}
    $payload=Join-Path $Record.Root 'payload'
    Assert-PackerPath $payload
    if(-not(Test-Path -LiteralPath $payload)){New-Item -ItemType Directory -Path $payload|Out-Null}
    foreach($entry in $sources.GetEnumerator()){
        $path=Join-Path $payload $entry.Key;Assert-PackerPath $path
        $prior=$Record.ClonePayloadHashes.PSObject.Properties[$entry.Key]
        if(-not $prior -or $prior.Value -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid clone payload manifest.'}
        if(-not(Test-Path -LiteralPath $path)){
            if((Get-FileHash -LiteralPath $entry.Value).Hash -cne $prior.Value){throw 'Original bootstrap source changed before snapshot completion; clone retained.'}
            Copy-Item -LiteralPath $entry.Value -Destination $path
        }
        if((Get-FileHash -LiteralPath $path).Hash -cne $prior.Value){throw 'Clone recovery payload changed; VM preserved.'}
    }
    return $payload
}

function Copy-WVMCloneDisk([object]$Record, [object]$Image) {
    $path=$Record.DiskPath;Assert-PackerPath $path
    if(-not $Record.DiskCopied){
        $temporary=$path+'.partial';Assert-PackerPath $temporary
        if(-not(Test-Path -LiteralPath $path)){
            if(-not(Test-Path -LiteralPath $temporary)){Copy-Item -LiteralPath $Image.DiskPath -Destination $temporary}
            if((Get-FileHash -LiteralPath $temporary).Hash -cne $Record.SourceDiskSha256){throw 'Partial clone disk differs; it was not overwritten.'}
            [IO.File]::Move($temporary,$path)
        }
        if((Get-FileHash -LiteralPath $path).Hash -cne $Record.SourceDiskSha256){throw 'Unrecorded clone disk differs; it was not overwritten.'}
        [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -band (-bnot [IO.FileAttributes]::ReadOnly)))
        $Record.DiskCopied=$true;Save-WVMRecord $Record
    }
    $vhd=Get-VHD -Path $path
    if($vhd.ParentPath -or $vhd.Size -notin @(($Record.ImageDiskGB*1GB),($Record.DiskGB*1GB))){throw 'Clone disk size or parent differs.'}
    if($vhd.Size -lt ($Record.DiskGB*1GB)){Resize-VHD -Path $path -SizeBytes ($Record.DiskGB*1GB)}
    if(-not $Record.DiskIdentityReset){
        if($Record.VMId){throw 'A registered clone cannot have its disk identity reset implicitly.'}
        Set-VHD -Path $path -ResetDiskIdentifier
        $Record.DiskIdentityReset=$true;Save-WVMRecord $Record
    }
    if(-not $Record.PreparedDiskSha256){
        if($Record.VMId){throw 'Registered clone has no pre-boot disk fingerprint; it will not be reseeded.'}
        $Record.PreparedDiskSha256=(Get-FileHash -LiteralPath $path).Hash
        Save-WVMRecord $Record
    }
}

function Initialize-WVMClone([object]$Record) {
    $vm=Get-VM|Where-Object Name -eq $Record.Name
    if($Record.VMId -and $Record.HardwareReady){$vm=Get-WVMOwnedVM $Record}
    elseif($Record.VMId){
        $drives=@(Get-VMHardDiskDrive -VM $vm);$adapters=@(Get-VMNetworkAdapter -VM $vm)
        if(-not $vm -or [string]$vm.Id -ne $Record.VMId -or $vm.Notes -cne ('Workstation '+$Record.Guest+' VM '+$Record.Token) -or -not $vm.Path.StartsWith((Join-Path $Record.Root 'machines\'),[StringComparison]::OrdinalIgnoreCase) -or $drives.Count -ne 1 -or $drives[0].Path -ine $Record.DiskPath -or $adapters.Count -ne 1 -or $adapters[0].SwitchName -cne $Record.SwitchName){throw 'Incomplete clone identity, disk or adapter differs; nothing changed.'}
    }
    elseif($vm){throw 'Unrecorded VM will not be adopted.'}
    else{
        $vm=New-VM -Name $Record.Name -Generation 2 -MemoryStartupBytes ($Record.MemoryGB*1GB) -VHDPath $Record.DiskPath -SwitchName $Record.SwitchName -Path (Join-Path $Record.Root 'machines\configuration')
        Set-VM -VM $vm -Notes ('Workstation '+$Record.Guest+' VM '+$Record.Token)
        $Record.VMId=[string]$vm.Id;Save-WVMRecord $Record
    }
    if($vm.State -ne 'Off'){throw 'Clone hardware preparation requires Off; no VM was stopped automatically.'}
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ($Record.MemoryGB*1GB)
    Set-VMProcessor -VM $vm -Count $Record.CPUs -ExposeVirtualizationExtensions $Record.Nested
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $(if($Record.Guest -eq 'Windows'){'MicrosoftWindows'}else{'MicrosoftUEFICertificateAuthority'})
    if($Record.Guest -eq 'Windows' -and -not(Get-VMSecurity -VM $vm).TpmEnabled){Set-VMKeyProtector -VM $vm -NewLocalKeyProtector;Enable-VMTPM -VM $vm}
    $copy=@(Get-VMIntegrationService -VM $vm|Where-Object{([string]$_.Id).EndsWith('6c09bb55-d683-4da0-8931-c9bf705f6480',[StringComparison]::OrdinalIgnoreCase)})
    if($copy.Count -ne 1){throw 'Guest Service Interface could not be identified; clone left Off.'}
    $copy[0]|Disable-VMIntegrationService
    Set-VMFirmware -VM $vm -FirstBootDevice (@(Get-VMHardDiskDrive -VM $vm)[0])
    $Record.HardwareReady=$true;Save-WVMRecord $Record
    return $vm
}
