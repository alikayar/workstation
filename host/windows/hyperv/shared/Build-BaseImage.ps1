#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Windows','Ubuntu')][string]$Guest,
    [string]$ImageRoot = "$env:ProgramData\Workstation\Images",
    [string]$IsoPath,
    [switch]$OpenConsole
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use elevated Windows x64 PowerShell.' }
if ($PSVersionTable.PSEdition -eq 'Core') {
    $parameters=@{}; foreach($entry in $PSBoundParameters.GetEnumerator()) { $parameters[$entry.Key]=if($entry.Value -is [Management.Automation.SwitchParameter]){[bool]$entry.Value}else{$entry.Value} }
    $data=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize(@{Script=$PSCommandPath;Parameters=$parameters})))
    $program='$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('''+$data+'''))); $parameters=$p.Parameters; & $p.Script @parameters'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program)))
    if($LASTEXITCODE -ne 0){throw 'Base-image Windows PowerShell worker failed.'}; return
}
Import-Module Hyper-V
Import-Module Dism
. (Join-Path $PSScriptRoot 'Image-Build.ps1')
. (Join-Path $PSScriptRoot 'Seed-ISO.ps1')
if ($Guest -eq 'Windows') { . (Join-Path $PSScriptRoot '..\windows-pro\Windows-Media.ps1') }
else { . (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Setup.ps1') }
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State -ne 'Enabled') { throw 'Enable Hyper-V and restart Windows before building an image.' }
$spec = Get-WVMImageSpec $Guest $ImageRoot
function Remove-ImageBuilder {
    $parent=Join-Path $spec.ImageRoot '.builds'
    $root=Join-Path $parent $spec.BuilderName
    $name=if($Guest -eq 'Windows'){'windows-vm.json'}else{'ubuntu-vm.json'}
    $recordPath=Join-Path $root $name
    $journal=Join-Path $parent ('.'+$spec.BuilderName+'.delete.json')
    foreach($path in @($recordPath,$journal)){Assert-PackerPath $path}
    $state=if(Test-Path -LiteralPath $recordPath){$recordPath}elseif(Test-Path -LiteralPath $journal){$journal}else{$null}
    if($state){
        $owned=Get-Content -LiteralPath $state -Raw|ConvertFrom-Json
        if($owned.ImageID -cne $spec.ID -or -not $owned.Generalized){throw 'Builder cleanup identity differs; image publication stopped.'}
        & (Join-Path $PSScriptRoot 'Remove-OwnedVM.ps1') -Guest $Guest -VMName $spec.BuilderName -VMRoot $parent -Confirm:$false
    }
    if((Test-Path -LiteralPath $root) -or (Test-Path -LiteralPath $journal) -or @(Get-VM|Where-Object Name -eq $spec.BuilderName).Count){throw 'Builder cleanup is incomplete; image remains unpublished.'}
}
$mutex = New-Object Threading.Mutex($false, ('Global\Workstation-BaseImage-'+$spec.ID))
$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another process is building this base image; retry when it completes.'}
    if(-not(Test-Path -LiteralPath $spec.ImageRoot)){New-WVMPrivateDirectory $spec.ImageRoot -ImageStore}
    Assert-WVMImageACL $spec.ImageRoot
    $ready=Get-WVMBaseImage $spec
    if($ready){Write-Host "Verified base image reused: $($spec.Folder) $($spec.ID.Substring(0,16))";return $ready}
    $pendingImage=Get-WVMBaseImage $spec -Pending
    if($pendingImage){
        Remove-ImageBuilder
        [IO.File]::Move((Join-Path $spec.Root 'image.pending.json'),(Join-Path $spec.Root 'image.json'))
        return (Get-WVMBaseImage $spec)
    }
    if (([uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB) -lt 6GB) { throw 'Image build needs 4 GiB plus 2 GiB retained for the host.' }
    $parent=Join-Path $spec.ImageRoot '.builds'
    if(-not(Test-Path -LiteralPath $parent)){New-WVMPrivateDirectory $parent -ImageStore}
    Assert-WVMImageACL $parent
    $root=Join-Path $parent $spec.BuilderName
    $recordName=if($Guest -eq 'Windows'){'windows-vm.json'}else{'ubuntu-vm.json'}
    $recordPath=Join-Path $root $recordName
    Assert-PackerPath $recordPath
    $record=$null
    if(Test-Path -LiteralPath $recordPath){
        $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
        if($record.Root -ine $root -or $record.Name -cne $spec.BuilderName -or $record.Guest -cne $Guest -or $record.ImageID -cne $spec.ID -or $record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Image-build ownership differs; builder retained.'}
        if($record.Phase -eq 'Preparing'){Save-WVMImagePayload $spec $record}else{Assert-WVMImagePayload $record}
    }else{
        if((Test-Path -LiteralPath $root) -or @(Get-VM|Where-Object Name -eq $spec.BuilderName).Count){throw 'Unrecorded image-builder VM or files exist; nothing adopted.'}
        $requiredSpace=if($Guest -eq 'Windows'){80GB}else{40GB}
        if((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($ImageRoot).Substring(0,1))).SizeRemaining -lt $requiredSpace){throw 'Not enough free space for image build, sealing and publication (Windows: 80 GiB; Ubuntu: 40 GiB).'}
        $media=if($Guest -eq 'Windows'){$m=Get-WindowsProMedia $IsoPath;Assert-WindowsProImage $m;$m.Path}else{Get-UbuntuMedia $IsoPath}
        New-WVMPrivateDirectory $root -ImageStore
        $record=[pscustomobject]@{Schema=1;Backend='Packer';OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Name=$spec.BuilderName;Root=$root;Token=[guid]::NewGuid().ToString('N');VMId='';DiskPath='';Phase='Preparing';Setup='Pending';UserName='wvmimage';CPUs=2;MemoryGB=4;DiskGB=$spec.DiskGB;SwitchName='Default Switch';Nested=$false;IsoPath=$media;IsoSha256=$spec.MediaSha256;AnswerSha256='';SeedSha256='';HostPublicKey='';Address='';Guest=$Guest;ImageID=$spec.ID;SourceHashes=$spec.Sources;Generalized=$false;SealAttested=$false;SealedDiskSha256=''}
        Save-WVMRecord $record
        Save-WVMImagePayload $spec $record
    }
    Assert-PackerIdle $root
    if(-not $record.VMId -and $record.Phase -eq 'Preparing'){
        $secrets=Join-Path $root 'setup-secrets'
        if(-not(Test-Path -LiteralPath $secrets)){New-Item -ItemType Directory -Path $secrets|Out-Null}
        if($Guest -eq 'Windows'){
            $seed=Join-Path $secrets 'answer.iso'
            if((Test-Path -LiteralPath $seed) -and (-not $record.AnswerSha256 -or (Get-FileHash -LiteralPath $seed).Hash -cne $record.AnswerSha256)){throw 'Unrecorded or changed image answer ISO retained; inspect before retrying.'}
            if(-not(Test-Path -LiteralPath $seed)){
                . (Join-Path $root 'payload\windows-pro\image\Windows-Image.ps1')
                $source=Join-Path $secrets 'source';New-Item -ItemType Directory -Path $source|Out-Null
                try{Save-PackerText (Join-Path $source 'Autounattend.xml') (New-WVMWindowsBaseAnswer $record);New-VMSeedISO $source $seed}
                finally{Remove-Item -LiteralPath (Join-Path $source 'Autounattend.xml');Remove-Item -LiteralPath $source}
            }
            $record.AnswerSha256=(Get-FileHash -LiteralPath $seed).Hash
        }else{
            foreach($path in @((Join-Path $root 'ssh-ed25519'),(Join-Path $secrets 'host-ed25519'))){if(-not(Test-Path -LiteralPath $path)){New-UbuntuKey $path};if(-not(Test-Path -LiteralPath ($path+'.pub'))){throw 'Incomplete builder identity retained.'}}
            $hostKey=Join-Path $secrets 'host-ed25519';$record.HostPublicKey=[IO.File]::ReadAllText($hostKey+'.pub').Trim()
            $seed=Join-Path $secrets 'seed.iso'
            if((Test-Path -LiteralPath $seed) -and (-not $record.SeedSha256 -or (Get-FileHash -LiteralPath $seed).Hash -cne $record.SeedSha256)){throw 'Unrecorded or changed image seed retained; inspect before retrying.'}
            if(-not(Test-Path -LiteralPath $seed)){New-UbuntuSeed $record $secrets ([IO.File]::ReadAllText((Join-Path $root 'ssh-ed25519.pub')).Trim()) $hostKey}
            $record.SeedSha256=(Get-FileHash -LiteralPath $seed).Hash
            Save-UbuntuText (Join-Path $root 'known_hosts') ('workstation-ubuntu-'+$record.Token+' '+$record.HostPublicKey+"`n")
        }
        Save-WVMRecord $record
        $hook=Join-Path $root 'payload\shared\Image-Build.ps1'
        $program='$ErrorActionPreference="Stop"; Import-Module Hyper-V; . '''+$hook.Replace("'","''")+'''; Complete-WVMImageBuild -RecordPath '''+$recordPath.Replace("'","''")+''''
        $command='"'+"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"+'" -NoLogo -NoProfile -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
        if($command.Length -gt 7500){throw 'Use a shorter image storage path.'}
        $variables=@{vm_name=$record.Name;switch_name=$record.SwitchName;state_dir=$root.Replace('\','/');iso_path=$record.IsoPath.Replace('\','/');seed_path=$seed.Replace('\','/');host_command=$command;headless=(-not [bool]$OpenConsole)}
        Invoke-WorkstationPacker -Root $root -VMName $record.Name -Template (Join-Path $root ('payload\'+$spec.Folder+'\image\base.pkr.hcl')) -Variables $variables -BeforeBuild {$record.Phase='Building';Save-WVMRecord $record}
        $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
    }elseif(-not $record.Generalized){
        if(-not $record.VMId){throw 'Unregistered failed builder will not be adopted or rebuilt.'}
        Complete-WVMImageBuild $recordPath -Resume
        $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
    }
    if(-not $record.Generalized){throw 'Only a generalized, attested image may be published.'}
    $vm=Get-VM|Where-Object Name -eq $record.Name
    if($vm){
        Assert-WVMRecord $record
        if([string]$vm.Id -cne $record.VMId -or $vm.Notes -cne ('Workstation '+$record.Guest+' VM '+$record.Token)){throw 'Generalized builder identity changed.'}
        if($vm.State -ne 'Off'){throw 'Generalized builder must remain Off.'}
        if(@(Get-VMSnapshot -VM $vm).Count){throw 'Generalized builder has unexpected checkpoints.'}
        $drives=@(Get-VMHardDiskDrive -VM $vm)
        if($drives.Count -ne 1 -or $drives[0].Path -ine $record.DiskPath){throw 'Generalized builder disk attachment changed.'}
        # Packer may remove its temporary disk after the host hook has sealed it.
        # Publication below verifies the retained sealed copy, not that temporary file.
    }
    $disk=Join-Path $root 'sealed.vhdx'
    Assert-PackerPath $disk
    if($record.SealedDiskSha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $disk).Hash -cne $record.SealedDiskSha256){throw 'Sealed disk fingerprint differs; publication refused.'}
    $vhd=Get-VHD -Path $disk
    if($vhd.ParentPath -or $vhd.Size -ne ($spec.DiskGB*1GB)){throw 'Published image must have an independent base disk.'}
    if(-not(Test-Path -LiteralPath $spec.Root)){New-WVMPrivateDirectory $spec.Root -ImageStore}
    Assert-WVMImageACL $spec.Root
    $artifact=Join-Path $spec.Root 'base.vhdx';$partial=$artifact+'.partial';$hash=(Get-FileHash -LiteralPath $disk).Hash
    if(-not(Test-Path -LiteralPath $artifact)){
        if(-not(Test-Path -LiteralPath $partial)){Copy-Item -LiteralPath $disk -Destination $partial}
        if((Get-FileHash -LiteralPath $partial).Hash -cne $hash){throw 'Partial image differs; publication refused.'}
        [IO.File]::Move($partial,$artifact)
    }
    if((Get-FileHash -LiteralPath $artifact).Hash -cne $hash){throw 'Existing artifact differs; it was not replaced.'}
    Protect-WVMImageFile $artifact
    [IO.File]::SetAttributes($artifact,([IO.File]::GetAttributes($artifact) -bor [IO.FileAttributes]::ReadOnly))
    $manifest=@{Schema=1;Phase='Ready';ID=$spec.ID;Guest=$Guest;Version=$spec.Version;DiskGB=$spec.DiskGB;DiskSha256=$hash;MediaSha256=$spec.MediaSha256;Sources=$spec.Sources;Generalization=$(if($Guest -eq 'Windows'){'Sysprep generalize/oobe'}else{'cloud-init clean and ephemeral account/key removal'});BuiltAt=[DateTime]::UtcNow.ToString('o')}
    $pendingPath=Join-Path $spec.Root 'image.pending.json'
    Save-PackerText $pendingPath ($manifest|ConvertTo-Json -Depth 16)
    Protect-WVMImageFile $pendingPath
    Remove-ImageBuilder
    [IO.File]::Move($pendingPath,(Join-Path $spec.Root 'image.json'))
    Get-WVMBaseImage $spec
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
