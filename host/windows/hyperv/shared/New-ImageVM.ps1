#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Windows','Ubuntu')][string]$Guest,
    [string]$VMName,
    [string]$VMRoot,
    [string]$ImageRoot="$env:ProgramData\Workstation\Images",
    [string]$IsoPath,
    [string]$SwitchName='Default Switch',
    [ValidateRange(2,64)][int]$CPUs=4,
    [ValidateRange(4,128)][int]$MemoryGB=8,
    [int]$DiskGB,
    [string]$UserName='dev',
    [switch]$NestedVirtualization,
    [switch]$OpenConsole
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:OS -ne 'Windows_NT' -or -not[Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'Use elevated Windows 11 x64 PowerShell.'}
if($PSVersionTable.PSEdition -eq 'Core'){
    $parameters=@{};foreach($entry in $PSBoundParameters.GetEnumerator()){$parameters[$entry.Key]=if($entry.Value -is [Management.Automation.SwitchParameter]){[bool]$entry.Value}else{$entry.Value}}
    $data=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize(@{Script=$PSCommandPath;Parameters=$parameters})))
    $program='$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('''+$data+''')));$parameters=$p.Parameters;& $p.Script @parameters'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program)))
    if($LASTEXITCODE -ne 0){throw 'Image-backed VM worker failed.'};return
}
if([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 22000){throw 'Windows 11 or later is required.'}
$feature=Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if($feature.State -ne 'Enabled'){
    if($Guest -eq 'Ubuntu' -and $feature.State -notin @('EnablePending','DisablePending')){Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart|Out-Null}
    Write-Host 'Enable Hyper-V if needed, restart Windows and rerun. No VM was created.';return
}
Import-Module Hyper-V
. (Join-Path $PSScriptRoot 'Clone-VM.ps1')
. (Join-Path $PSScriptRoot 'VM-Resources.ps1')
function Read-CloneValue([string]$Label,[object]$Default,[scriptblock]$Validate){
    while($true){$answer=Read-Host "$Label [$Default]";if([string]::IsNullOrWhiteSpace($answer)){$answer=[string]$Default};try{return & $Validate $answer.Trim()}catch{Write-Host $_.Exception.Message -ForegroundColor Yellow}}
}
$folder=if($Guest -eq 'Windows'){'windows-pro'}else{'ubuntu-26-04'}
$namePattern=if($Guest -eq 'Windows'){'^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$'}else{'^[a-z][a-z0-9-]{0,61}[a-z0-9]$'}
if(-not $PSBoundParameters.ContainsKey('VMName')){$VMName=Read-CloneValue 'VM name' ('workstation-'+$folder) {param($value) if($value -cnotmatch $namePattern){throw 'Use a valid guest hostname containing letters, digits or hyphens.'};$value}}
if($VMName -cnotmatch $namePattern){throw 'Invalid guest VM name.'}
if(-not $PSBoundParameters.ContainsKey('VMRoot')){$VMRoot=Join-Path $env:ProgramData $(if($Guest -eq 'Windows'){'Workstation\WindowsVMs'}else{'Workstation\UbuntuVMs'})}
if($VMRoot -notmatch '^[a-zA-Z]:[\\/]'){throw 'VMRoot must be an absolute local drive path.'}
$VMRoot=[IO.Path]::GetFullPath($VMRoot).TrimEnd('\');$root=Join-Path $VMRoot $VMName
$recordName=if($Guest -eq 'Windows'){'windows-vm.json'}else{'ubuntu-vm.json'}
$marker=Join-Path $root $recordName;Assert-PackerPath $marker
if($Guest -eq 'Ubuntu'){
    if($NestedVirtualization){throw 'Nested virtualization is supported only for Windows clones.'}
    foreach($tool in @('ssh.exe','scp.exe','ssh-keygen.exe')){if(-not(Test-Path -LiteralPath (Join-Path ([Environment]::SystemDirectory) ('OpenSSH\'+$tool)))){throw 'Enable Windows OpenSSH Client before creating Ubuntu.'}}
}
$mutex=New-Object Threading.Mutex($false,('Global\Workstation-'+$Guest+'VM-'+$VMName.ToLowerInvariant()))
$locked=$false;$credential=$null
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another operation is using this VM.'}
    $journal=Join-Path $VMRoot ('.'+$VMName+'.delete.json');Assert-PackerPath $journal
    if(Test-Path -LiteralPath $journal){throw 'Finish wvm delete recovery before creating this name again.'}
    Assert-PackerIdle $root
    $vm=Get-VM|Where-Object Name -eq $VMName;$record=$null;$image=$null
    if(Test-Path -LiteralPath $marker){
        $record=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
        Assert-WVMRecord $record
        if ($record.DiskPath -ine (Join-Path $root 'machines\os.vhdx')) { throw 'Clone disk path differs from its directory.' }
        $schema=1
        if($record.Schema -ne $schema -or $record.Backend -cne 'Image' -or $record.Guest -cne $Guest -or $record.Root -ine $root -or $record.Name -cne $VMName -or $record.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $record.Token -cnotmatch '^[a-f0-9]{32}$' -or $record.ImageID -cnotmatch '^[a-f0-9]{64}$'){throw 'Image-backed VM ownership differs.'}
        if($record.Phase -notin @('Preparing','Creating','Booting','Account','Cleanup','Complete','Ready')){throw 'Invalid clone recovery phase.'}
        if($record.VMId -and (-not $vm -or [string]$vm.Id -ne $record.VMId)){throw 'Recorded VM is missing or replaced; it will not be recreated.'}
        if($vm -and (-not $record.VMId -or $vm.Notes -cne ('Workstation '+$Guest+' VM '+$record.Token))){throw 'Unrecorded or replaced VM will not be adopted.'}
        foreach($name in @('CPUs','MemoryGB','DiskGB','SwitchName','UserName')){
            if($PSBoundParameters.ContainsKey($name) -and (Get-Variable $name -ValueOnly) -cne $record.$name){throw "Saved $name differs; existing VM preserved."}
            Set-Variable -Name $name -Value $record.$name
        }
        if($PSBoundParameters.ContainsKey('NestedVirtualization') -and [bool]$NestedVirtualization -ne $record.Nested){throw 'Saved nested virtualization differs.'}
        $NestedVirtualization=[bool]$record.Nested
    }else{
        if($vm -or(Test-Path -LiteralPath $root)){throw 'Existing VM name or directory is unmanaged; choose another name.'}
        $hostCPUs=[int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        if(-not $PSBoundParameters.ContainsKey('DiskGB')){$DiskGB=if($Guest -eq 'Windows'){120}else{80}}
        foreach($entry in @(@{Name='CPUs';Label='VM CPU count';Min=2;Max=[Math]::Min(64,$hostCPUs)},@{Name='MemoryGB';Label='VM memory (GiB)';Min=4;Max=32},@{Name='DiskGB';Label='VM disk (GiB)';Min=$(if($Guest -eq 'Windows'){64}else{40});Max=2048})){
            if(-not $PSBoundParameters.ContainsKey($entry.Name)){$default=[Math]::Min((Get-Variable $entry.Name -ValueOnly),$entry.Max);$value=Read-CloneValue $entry.Label $default {param($v) ConvertTo-WorkstationResource $entry.Label $v $entry.Min $entry.Max};Set-Variable $entry.Name $value}
            $null=ConvertTo-WorkstationResource $entry.Label ([string](Get-Variable $entry.Name -ValueOnly)) $entry.Min $entry.Max
        }
        $userPattern=if($Guest -eq 'Windows'){'^[a-zA-Z][a-zA-Z0-9_-]{0,19}$'}else{'^[a-z][a-z0-9_]{0,30}$'}
        $reserved=@('root','ubuntu','wvmimage','Administrator','Guest','DefaultAccount','WDAGUtilityAccount','daemon','bin','sys','sync','games','man','lp','mail','news','uucp','proxy','backup','list','irc','nobody')
        if(-not $PSBoundParameters.ContainsKey('UserName')){$UserName=Read-CloneValue 'Guest user name' $UserName {param($v) if($v -cnotmatch $userPattern -or $v -in $reserved){throw 'Choose a new non-system user name.'};$v}}
        if($UserName -cnotmatch $userPattern -or $UserName -in $reserved){throw 'Invalid guest user name.'}
        $switch=Get-VMSwitch -Name $SwitchName
        if($switch.SwitchType -ne 'Internal'){throw 'Use an existing Internal switch.'}
        if($Guest -eq 'Ubuntu'){$null=Get-UbuntuNetworkTopology $SwitchName}
        if(([uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB) -lt (($MemoryGB+2)*1GB)){throw 'Not enough RAM for the requested clone plus 2 GiB for the host; no image build or VM creation started.'}
        $spec=Get-WVMImageSpec $Guest $ImageRoot
        $image=Get-WVMBaseImage $spec
        if(-not $image){Write-Host 'Preparing the reusable base image once; subsequent creates only copy it.';$image=& (Join-Path $PSScriptRoot 'Build-BaseImage.ps1') -Guest $Guest -ImageRoot $ImageRoot -IsoPath $IsoPath -OpenConsole:$OpenConsole}
        if($image.ID -cne $spec.ID){throw 'Image specification changed during creation; retry before creating a VM.'}
        if((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($root).Substring(0,1))).SizeRemaining -lt ((Get-Item -LiteralPath $image.DiskPath).Length+10GB)){throw 'Not enough disk space for a full independent image copy and working space.'}
        New-WVMPrivateDirectory $root
        New-Item -ItemType Directory -Path (Join-Path $root 'machines')|Out-Null
        $record=[pscustomobject]@{Schema=1;Backend='Image';Guest=$Guest;OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Name=$VMName;Root=$root;Token=[guid]::NewGuid().ToString('N');VMId='';DiskPath=(Join-Path $root 'machines\os.vhdx');Phase='Preparing';Setup='Pending';UserName=$UserName;CPUs=$CPUs;MemoryGB=$MemoryGB;DiskGB=$DiskGB;SwitchName=$SwitchName;Nested=[bool]$NestedVirtualization;ImageID=$image.ID;ImageRoot=$spec.ImageRoot;ImageDiskGB=$image.DiskGB;SourceDiskSha256=$image.DiskSha256;DiskCopied=$false;DiskIdentityReset=$false;PreparedDiskSha256='';HardwareReady=$false;Seeded=$false;ClonePayloadHashes=(Get-WVMCloneHashes $Guest);IsoPath='';Address='';HostPublicKey='';SeedSha256=''}
        Save-WVMRecord $record
    }
    $payload=Set-WVMClonePayload $record
    if($Guest -eq 'Windows'){. (Join-Path $payload 'Windows-Unattend.ps1');. (Join-Path $payload 'Windows-Image.ps1')}
    else{. (Join-Path $payload 'Ubuntu-Clone.ps1')}
    if($record.Phase -in @('Preparing','Creating')){
        if(-not $record.DiskCopied -and -not $image){$spec=Get-WVMImageSpec $Guest $record.ImageRoot;$image=Get-WVMBaseImage $spec;if(-not $image -or $image.ID -cne $record.ImageID){throw 'Original base image is unavailable; partial clone was not rebuilt.'}}
        Copy-WVMCloneDisk $record $image
        $record.Phase='Creating';Save-WVMRecord $record
        $vm=Initialize-WVMClone $record
        if(-not $record.Seeded){
            if((Get-FileHash -LiteralPath $record.DiskPath).Hash -cne $record.PreparedDiskSha256){throw 'Prepared clone disk changed before first-boot seeding; it was not mounted or reseeded.'}
            if($Guest -eq 'Windows'){$credential=Read-WindowsVMCredential $UserName;Set-WVMWindowsCloneSeed $record $credential}
            else{
                $secrets=Join-Path $root 'setup-secrets';if(-not(Test-Path -LiteralPath $secrets)){New-Item -ItemType Directory -Path $secrets|Out-Null}
                foreach($path in @((Join-Path $root 'ssh-ed25519'),(Join-Path $secrets 'host-ed25519'))){if(-not(Test-Path -LiteralPath $path)){New-UbuntuKey $path};if(-not(Test-Path -LiteralPath ($path+'.pub'))){throw 'Incomplete clone key retained.'}}
                $seed=Join-Path $secrets 'seed.iso'
                if(Test-Path -LiteralPath $seed){throw 'Unrecorded clone seed retained; inspect before retrying.'}
                $hostKey=Join-Path $secrets 'host-ed25519';$record.HostPublicKey=[IO.File]::ReadAllText($hostKey+'.pub').Trim()
                New-WVMUbuntuCloneSeed $record $secrets ([IO.File]::ReadAllText((Join-Path $root 'ssh-ed25519.pub')).Trim()) $hostKey
                $record.SeedSha256=(Get-FileHash -LiteralPath $seed).Hash
            }
            $record.Seeded=$true;Save-WVMRecord $record
        }
        $record.Phase='Booting';Save-WVMRecord $record
    }
    $vm=Get-WVMOwnedVM $record
    if($Guest -eq 'Ubuntu'){
        $seed=Join-Path $root 'setup-secrets\seed.iso'
        if($record.Phase -notin @('Cleanup','Complete')){
            if((Get-FileHash -LiteralPath $seed).Hash -cne $record.SeedSha256){throw 'Clone seed differs; VM was not started.'}
            if(-not @(Get-VMDvdDrive -VM $vm|Where-Object Path -eq $seed).Count){if($vm.State -ne 'Off'){throw 'Pending seed is detached; shut down before resuming.'};Add-VMDvdDrive -VM $vm -Path $seed}
        }
        if($vm.State -eq 'Off'){Set-UbuntuNetworkPolicy $record}else{Assert-UbuntuNetworkPolicy $record}
    }
    if($Guest -eq 'Windows' -and $record.Setup -eq 'Pending' -and -not $credential){$credential=Read-WindowsVMCredential $UserName}
    if($vm.State -notin @('Off','Saved','Running')){throw 'VM state is busy; retry later.'}
    if($vm.State -ne 'Running'){
        if(([uint64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB) -lt ($vm.MemoryStartup+2GB)){throw 'Not enough RAM; leave 2 GiB for the host. Clone retained.'}
        Start-VM -VM $vm|Out-Null
    }
    if($OpenConsole){Start-Process "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost','-G',$record.VMId)|Out-Null}
    if($Guest -eq 'Windows'){
        if($record.Setup -eq 'Pending'){Wait-WindowsSetup -VMId $record.VMId -Token $record.Token -DiskPath $record.DiskPath -Credential $credential;$record.Setup='Complete';$record.Phase='Ready';Save-WVMRecord $record}
    }else{
        $key=Join-Path $root 'ssh-ed25519';$known=Join-Path $root 'known_hosts'
        if($record.HostPublicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: [^\r\n]*)?$'){throw 'Invalid recorded clone SSH host key.'}
        if(-not(Test-Path -LiteralPath $key) -or -not(Test-Path -LiteralPath ($key+'.pub'))){throw 'Recorded clone SSH client identity is missing; it will not be replaced.'}
        Save-UbuntuText $known ('workstation-ubuntu-'+$record.Token+' '+$record.HostPublicKey+"`n")
        $address=Wait-UbuntuAddress $record $key $known
        Save-UbuntuText $known (('workstation-ubuntu-'+$record.Token+' '+$record.HostPublicKey+"`n")+($address+' '+$record.HostPublicKey+"`n"))
        $record.Address=$address
        if ($record.Phase -notin @('Cleanup','Complete')) {
            & (Join-Path $PSScriptRoot '..\ubuntu-26-04\Set-GuestAccount.ps1') -Address $address -UserName $UserName -IdentityFile $key -KnownHostsFile $known -InstallationId $record.Token -FinalizerPath (Join-Path $payload 'finalize-account.sh') -WaitForCloudInit
            $record.Phase='Cleanup'
            Save-WVMRecord $record
        }
        $vm=Get-WVMOwnedVM $record
        Get-VMDvdDrive -VM $vm|Where-Object Path -eq $seed|Set-VMDvdDrive -Path $null
        foreach($name in @('seed.iso','host-ed25519','host-ed25519.pub')){$path=Join-Path $root ('setup-secrets\'+$name);Assert-PackerPath $path;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
        $secrets=Join-Path $root 'setup-secrets';if((Test-Path -LiteralPath $secrets) -and -not @(Get-ChildItem -LiteralPath $secrets -Force).Count){Remove-Item -LiteralPath $secrets}
        $record.Phase='Complete';$record.Setup='Complete';Save-WVMRecord $record;Set-UbuntuSSHConfig $record
    }
    [pscustomobject]@{Name=$VMName;VMId=$record.VMId;Directory=$root;ImageID=$record.ImageID;State=[string](Get-VM -Id $record.VMId).State}
}finally{if($credential){$credential.Password.Dispose()};if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
