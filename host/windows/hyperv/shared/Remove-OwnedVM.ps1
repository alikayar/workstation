#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Deletes an exact Hyper-V VM and its exclusive disks, regardless of installer.
.DESCRIPTION
Checks live VM/checkpoint references before unregistering and before deleting files.
An administrator-only journal supports interrupted cleanup. Shared installation
ISOs are retained. Force permits power-off; it never bypasses reference checks.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VMName,
    [string]$VMRoot,
    [ValidateSet('Windows','Ubuntu')][string]$Guest,
    [switch]$Force
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -eq 'Core') {
    $parameters=@{}
    foreach($entry in $PSBoundParameters.GetEnumerator()){
        $parameters[$entry.Key]=if($entry.Value -is [Management.Automation.SwitchParameter]){[bool]$entry.Value}else{$entry.Value}
    }
    $parameters.WhatIf=[bool]$WhatIfPreference
    $data=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize(@{Script=$PSCommandPath;Parameters=$parameters;Confirm=[string]$ConfirmPreference})))
    $program='$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('''+$data+''')));$ConfirmPreference=[Management.Automation.ConfirmImpact]$p.Confirm;$a=$p.Parameters;& $p.Script @a'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program)))
    if($LASTEXITCODE){throw 'VM deletion worker failed.'}
    return
}
Import-Module Hyper-V
. (Join-Path $PSScriptRoot 'BaseImage.ps1')

function Test-DeletionPath([string]$Path,[string]$Directory) {
    if(-not $Path -or -not $Directory){return $false}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $boundary=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return $full -ieq $boundary -or $full.StartsWith($boundary+'\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-DeletionDiskChain([string]$Path,[switch]$AllowMissingLeaf) {
    if(-not $Path){throw 'Physical/pass-through disks cannot be deleted as VM files.'}
    $seen=@{}
    while($Path){
        $Path=[IO.Path]::GetFullPath($Path)
        Assert-PackerPath $Path
        if($seen.ContainsKey($Path)){throw 'Disk chain contains a cycle.'}
        $seen[$Path]=$true
        $Path
        # Retain the leaf reference even when its file is gone; it has no readable parent chain.
        # A missing parent of an existing disk still fails inspection.
        if($AllowMissingLeaf -and $seen.Count -eq 1 -and -not(Test-Path -LiteralPath $Path)){return}
        $Path=(Get-VHD -Path $Path).ParentPath
    }
}

function Get-DeletionVersions($VM) {
    @{Value=$VM;Snapshot=$false}
    foreach($snapshot in @(Get-VMSnapshot -VM $VM)){@{Value=$snapshot;Snapshot=$true}}
}

function Get-DeletionRecord($VM) {
    # Optional cleanup metadata, not a schema/version gate. Live identity is authoritative.
    $cursor=[IO.Path]::GetFullPath($VM.Path)
    while($cursor){
        foreach($file in @('windows-vm.json','ubuntu-vm.json')){
            $path=Join-Path $cursor $file
            Assert-PackerPath $path
            if(-not(Test-Path -LiteralPath $path)){continue}
            try { $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json }
            catch { continue }
            if (@('VMId','Root','Name','Token','OwnerSID') | Where-Object { -not $record.PSObject.Properties[$_] }) { continue }
            if(-not $record.PSObject.Properties['VMId'] -or [string]$record.VMId -ine [string]$VM.Id){continue}
            if(-not $record.PSObject.Properties['Root'] -or $record.Root -ine $cursor -or $record.Name -ine $VM.Name){continue}
            if([IO.Path]::GetFileName($cursor) -ine $VM.Name){continue}
            $family=if($file -eq 'ubuntu-vm.json'){'Ubuntu'}else{'Windows'}
            if($record.Token -cnotmatch '^[a-f0-9]{32}$' -or $VM.Notes -cne ('Workstation '+$family+' VM '+$record.Token)){continue}
            return [pscustomobject]@{Root=$cursor;Guest=$family;Token=$record.Token;OwnerSID=$record.OwnerSID}
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-DeletionTree([string]$Root) {
    Assert-PackerPath $Root
    if(-not(Test-Path -LiteralPath $Root)){return}
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while($pending.Count){
        $directory=$pending.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked VM content cannot be deleted.'}
            $item
            if($item.PSIsContainer){$pending.Push($item.FullName)}
        }
    }
}

function New-VMDeletionPlan($VM) {
    $files=@();$directories=@();$roots=@();$ids=@([string]$VM.Id)
    foreach($version in @(Get-DeletionVersions $VM)){
        $value=$version.Value
        $ids += [string]$value.Id
        foreach($property in @('Path','ConfigurationLocation','SnapshotFileLocation','SmartPagingFilePath')){
            if($value.PSObject.Properties[$property] -and $value.$property){$roots += [IO.Path]::GetFullPath($value.$property)}
        }
        $drives=if($version.Snapshot){@(Get-VMHardDiskDrive -VMSnapshot $value)}else{@(Get-VMHardDiskDrive -VM $value)}
        foreach($drive in $drives){
            foreach($disk in @(Get-DeletionDiskChain $drive.Path -AllowMissingLeaf)){
                $files += $disk
                foreach($suffix in @('.rct','.mrt')){if(Test-Path -LiteralPath ($disk+$suffix)){$files += $disk+$suffix}}
                $directories += Split-Path -Parent $disk
            }
        }
    }
    $metadata=Get-DeletionRecord $VM
    if($metadata){
        $roots += $metadata.Root
        $directories += $metadata.Root
        foreach($item in @(Get-DeletionTree $metadata.Root)){
            if($item.PSIsContainer){$directories += $item.FullName}else{$files += $item.FullName}
        }
    } else {
        # Shared Hyper-V directories are not recursively deleted. Select only this VM's GUID files.
        foreach($root in @($roots|Select-Object -Unique)){
            foreach($item in @(Get-DeletionTree $root)){
                if($item.PSIsContainer){continue}
                if($item.BaseName -in $ids -and $item.Extension -in @('.vmcx','.vmrs','.vmgs','.xml','.bin','.vsv','.slp')){
                    $files += $item.FullName
                    $directories += $item.DirectoryName
                }
            }
            $directories += $root
        }
    }
    [pscustomobject]@{
        Schema=1;Name=$VM.Name;VMId=[string]$VM.Id;Notes=[string]$VM.Notes
        OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Files=@($files|Sort-Object -Unique);Directories=@($directories|Sort-Object -Unique)
        Metadata=$metadata
    }
}

function Assert-VMDeletionReferences($Plan,[object[]]$Inventory) {
    $wanted=@{};foreach($path in $Plan.Files){Assert-PackerPath $path;$wanted[[IO.Path]::GetFullPath($path)]=$true}
    foreach($vm in $Inventory){
        if([string]$vm.Id -eq $Plan.VMId){continue}
        foreach($version in @(Get-DeletionVersions $vm)){
            $value=$version.Value
            foreach($property in @('Path','ConfigurationLocation','SnapshotFileLocation','SmartPagingFilePath')){
                if($value.PSObject.Properties[$property] -and $value.$property){
                    if($Plan.Metadata -and (Test-DeletionPath $value.$property $Plan.Metadata.Root)){throw 'Another VM uses this installation directory.'}
                    # Even in a shared configuration directory, foreign GUID files cannot be removed.
                    foreach($path in $Plan.Files){
                        if((Test-DeletionPath $path $value.$property) -and [IO.Path]::GetFileNameWithoutExtension($path) -ieq [string]$value.Id){throw 'Another VM uses a planned configuration file.'}
                    }
                }
            }
            $disks=if($version.Snapshot){@(Get-VMHardDiskDrive -VMSnapshot $value)}else{@(Get-VMHardDiskDrive -VM $value)}
            $dvds=if($version.Snapshot){@(Get-VMDvdDrive -VMSnapshot $value)}else{@(Get-VMDvdDrive -VM $value)}
            foreach($dvd in $dvds){if($dvd.Path -and $wanted.ContainsKey([IO.Path]::GetFullPath($dvd.Path))){throw 'Another VM uses planned installation media.'}}
            foreach($drive in $disks){
                if(-not $drive.Path){continue}
                foreach($disk in @(Get-DeletionDiskChain $drive.Path -AllowMissingLeaf)){
                    if($wanted.ContainsKey($disk)){throw "Disk is used by another VM or checkpoint: $disk"}
                }
            }
        }
    }
}

$hash=[Security.Cryptography.SHA256]::Create()
try{$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($VMName.ToLowerInvariant()))).Replace('-','')}finally{$hash.Dispose()}
$journalRoot=Join-Path $env:ProgramData 'Workstation\Deletions'
$journalPath=Join-Path $journalRoot ($key+'.json')
Assert-PackerPath $journalPath
$locks=@()
try{
    # Coordinate with current creation and lifecycle commands, without needing an OS record.
    foreach($name in @('Windows','Ubuntu')){
        $mutex=New-Object Threading.Mutex($false,('Global\Workstation-'+$name+'VM-'+$VMName.ToLowerInvariant()))
        $locked=$false
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){$mutex.Dispose();throw 'Another operation is using this VM.'}
        $locks += $mutex
    }
    $inventory=@(Get-VM)
    $matches=@($inventory|Where-Object Name -eq $VMName)
    if($matches.Count -gt 1){throw 'VM name is ambiguous.'}
    $vm=if($matches.Count){$matches[0]}else{$null}
    if(Test-Path -LiteralPath $journalPath){
        Assert-WVMImageACL $journalRoot
        Assert-WVMImageACL $journalPath
        $plan=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        if($plan.Schema -ne 1 -or $plan.Name -ine $VMName -or $plan.OwnerSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Deletion journal identity differs.'}
        if($vm -and ([string]$vm.Id -ne $plan.VMId -or [string]$vm.Notes -cne $plan.Notes)){throw 'A different VM now has this name.'}
    }else{
        if(-not $vm){Write-Host "VM not found and no pending deletion: $VMName";return}
        $plan=New-VMDeletionPlan $vm
    }
    $identityLock=New-Object Threading.Mutex($false,('Global\Workstation-WVM-'+$plan.VMId))
    $locked=$false
    try{$locked=$identityLock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){$identityLock.Dispose();throw 'Another power operation is using this VM.'}
    $locks += $identityLock
    if($VMRoot -and $plan.Metadata -and [IO.Path]::GetFullPath((Join-Path $VMRoot $VMName)) -ine $plan.Metadata.Root){throw 'VMRoot does not match the VM directory.'}
    if($plan.Metadata){Assert-PackerIdle $plan.Metadata.Root}
    Assert-VMDeletionReferences $plan $inventory
    if($vm -and $vm.State -ne 'Off' -and -not $Force){throw 'Shut down the VM first, or explicitly use -Force.'}
    $description="$VMName [$($plan.VMId)]; $(@($plan.Files).Count) exclusive files"
    if(-not $PSCmdlet.ShouldProcess($description,'Delete VM, checkpoints and exclusive disks/files')){return}
    if(-not(Test-Path -LiteralPath $journalRoot)){New-WVMPrivateDirectory $journalRoot -ImageStore}
    Assert-WVMImageACL $journalRoot
    if(-not(Test-Path -LiteralPath $journalPath)){
        Save-PackerText $journalPath ($plan|ConvertTo-Json -Depth 12)
        Protect-WVMImageFile $journalPath
    }
    if($vm){
        $current=Get-VM -Id $plan.VMId
        if($current.Name -ine $plan.Name -or [string]$current.Notes -cne $plan.Notes){throw 'VM identity changed before deletion.'}
        if($current.State -ne 'Off'){
            if(-not $Force){throw 'VM started during deletion.'}
            Stop-VM -VM $current -TurnOff -Force -Confirm:$false
        }
        # Rebuild the plan after power-off; checkpoint/disk changes require a fresh invocation.
        $currentPlan=New-VMDeletionPlan (Get-VM -Id $plan.VMId)
        if(@($currentPlan.Files | Where-Object { $_ -notin $plan.Files }).Count){throw 'VM files changed; deletion journal retained for inspection.'}
        Assert-VMDeletionReferences $plan @(Get-VM)
        Remove-VM -VM $current -Force -Confirm:$false
    }
    $remaining=@(Get-VM)
    if(@($remaining|Where-Object { [string]$_.Id -eq $plan.VMId -or $_.Name -eq $plan.Name }).Count){throw 'VM identity/name still registered; files retained.'}
    Assert-VMDeletionReferences $plan $remaining
    if($plan.Metadata){Assert-PackerIdle $plan.Metadata.Root}
    foreach($path in $plan.Files){
        Assert-PackerPath $path
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path -Force).PSIsContainer){throw 'Planned file became a directory.'}
            Remove-Item -LiteralPath $path -Force -Confirm:$false
        }
    }
    foreach($directory in @($plan.Directories|Sort-Object Length -Descending)){
        if (-not [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory).TrimEnd('\'))) { continue }
        Assert-PackerPath $directory
        if((Test-Path -LiteralPath $directory) -and -not @(Get-ChildItem -LiteralPath $directory -Force).Count){
            Remove-Item -LiteralPath $directory -Confirm:$false
        }
    }
    if($plan.Metadata -and $plan.Metadata.Guest -eq 'Ubuntu' -and $plan.Metadata.OwnerSID -ceq $plan.OwnerSID){
        . (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Setup.ps1')
        Remove-UbuntuSSHConfig $plan.Metadata
    }
    Remove-Item -LiteralPath $journalPath -Force -Confirm:$false
    Write-Host "Deleted $VMName, its exclusive disks and VM files. Shared installation media retained."
}finally{
    foreach($mutex in $locks){$mutex.ReleaseMutex();$mutex.Dispose()}
}
