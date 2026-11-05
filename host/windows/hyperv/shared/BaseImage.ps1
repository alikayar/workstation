. (Join-Path $PSScriptRoot 'Packer.ps1')

function New-WVMPrivateDirectory([string]$Path, [switch]$ImageStore) {
    Assert-PackerPath $Path
    if (Test-Path -LiteralPath $Path) { throw "Directory already exists; retained: $Path" }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $sids = @('S-1-5-18', 'S-1-5-32-544')
    if (-not $ImageStore) { $sids += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    foreach ($sid in $sids) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))) }
    [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
}

function Assert-WVMImageACL([string]$Path) {
    Assert-PackerPath $Path
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Image storage must be owned by Administrators or SYSTEM.' }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Image storage permits unprivileged writes; image refused.' }
    }
}

function Protect-WVMImageFile([string]$Path) {
    Assert-PackerPath $Path
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','Allow')))}
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Save-WVMImagePayload([object]$Spec,[object]$Record) {
    foreach($entry in $Spec.Sources.PSObject.Properties){
        $destination=Join-Path (Join-Path $Record.Root 'payload') $entry.Name
        Assert-PackerPath $destination
        if(-not(Test-Path -LiteralPath $destination)){
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
            Copy-Item -LiteralPath (Join-Path $Spec.SourceRoot $entry.Name) -Destination $destination
        }
        if((Get-FileHash -LiteralPath $destination).Hash -cne $entry.Value){throw 'Image source changed during snapshot; build retained.'}
    }
    Assert-WVMImagePayload $Record
}

function Get-WVMImageSpec([ValidateSet('Windows','Ubuntu')][string]$Guest, [string]$ImageRoot) {
    if ($ImageRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'ImageRoot must be an absolute local drive path.' }
    $ImageRoot = [IO.Path]::GetFullPath($ImageRoot).TrimEnd('\')
    Assert-PackerPath $ImageRoot
    $Guest = if ($Guest -eq 'Windows') { 'Windows' } else { 'Ubuntu' }
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $folder = if ($Guest -eq 'Windows') { 'windows-pro' } else { 'ubuntu-26-04' }
    $version = if ($Guest -eq 'Windows') { '25h2-26200.6584-r1' } else { '26.04.1-r1' }
    $media = if ($Guest -eq 'Windows') { 'd141f6030fed50f75e2b03e1eb2e53646c4b21e5386047cb860af5223f102a32' } else { 'cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927' }
    [string[]]$names = @('shared/Packer.ps1','shared/VM.ps1','shared/BaseImage.ps1','shared/Build-BaseImage.ps1','shared/Image-Build.ps1','shared/Seed-ISO.ps1',
        ($folder + '/image/base.pkr.hcl'))
    if ($Guest -eq 'Windows') { $names += @('windows-pro/Windows-Media.ps1','windows-pro/Autounattend.xml','windows-pro/image/Windows-Image.ps1') }
    else { $names += @('ubuntu-26-04/Ubuntu-Setup.ps1','ubuntu-26-04/image/seal-image.sh') }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $hashes = [ordered]@{}; $lines = @('workstation-image-v1', $Guest, $version, $media)
    foreach ($name in $names) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $sourceRoot $name) -Algorithm SHA256).Hash
        $lines += $name + '=' + $hashes[$name]
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $root = Join-Path (Join-Path $ImageRoot $folder) ($version + '-' + $id.Substring(0,16))
    [pscustomobject]@{ Guest=$Guest; Folder=$folder; Version=$version; ID=$id; Root=$root; ImageRoot=$ImageRoot; SourceRoot=$sourceRoot; Sources=[pscustomobject]$hashes; MediaSha256=$media; DiskGB=$(if($Guest -eq 'Windows'){64}else{40}); BuilderName=('wvm-image-' + $Guest.ToLowerInvariant() + '-' + $id.Substring(0,16)) }
}

function Get-WVMBaseImage([object]$Spec, [switch]$Pending) {
    $path = Join-Path $Spec.Root $(if($Pending){'image.pending.json'}else{'image.json'})
    Assert-PackerPath $path
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($item in @($Spec.ImageRoot, $Spec.Root, $path, (Join-Path $Spec.Root 'base.vhdx'))) { Assert-WVMImageACL $item }
    $image = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($image.Schema -ne 1 -or $image.Phase -cne 'Ready' -or $image.ID -cne $Spec.ID -or $image.Guest -cne $Spec.Guest -or $image.MediaSha256 -ine $Spec.MediaSha256 -or $image.DiskSha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $image.DiskGB -ne $Spec.DiskGB) { throw 'Base-image manifest differs; no VM will use it.' }
    $disk = Join-Path $Spec.Root 'base.vhdx'
    if ((Get-FileHash -LiteralPath $disk).Hash -cne $image.DiskSha256) { throw 'Base-image disk changed; no VM will use it.' }
    $vhd = Get-VHD -Path $disk
    if ($vhd.ParentPath -or $vhd.Size -ne ($Spec.DiskGB * 1GB)) { throw 'Base image must be a standalone disk of the recorded size.' }
    $image | Add-Member -NotePropertyName DiskPath -NotePropertyValue $disk
    return $image
}

function Assert-WVMImagePayload([object]$Record) {
    if (@($Record.SourceHashes.PSObject.Properties).Count -lt 8) { throw 'Incomplete image-build recovery payload.' }
    foreach ($entry in $Record.SourceHashes.PSObject.Properties) {
        if ($entry.Name -cnotmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*/[A-Za-z0-9_.-]+\.(ps1|xml|hcl|sh)$' -or $entry.Value -cnotmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid image-build payload entry.' }
        $path = Join-Path (Join-Path $Record.Root 'payload') $entry.Name
        Assert-PackerPath $path
        if ((Get-FileHash -LiteralPath $path).Hash -cne $entry.Value) { throw 'Frozen image-build payload changed; build retained.' }
    }
}

function Invoke-WVMWindowsDisk([string]$DiskPath, [string]$MountPath, [scriptblock]$Action, [switch]$ReadOnly) {
    Assert-PackerPath $DiskPath; Assert-PackerPath $MountPath
    if (Test-Path -LiteralPath $MountPath) { throw 'Offline mount directory already exists; retained for inspection.' }
    # Generalized copies share GPT identifiers; never attach two of them to the host concurrently.
    $mutex=New-Object Threading.Mutex($false,'Global\Workstation-OfflineWindowsImage')
    $locked=$false
    $mounted = $false; $attached = $false; $created = $false; $partition = $null
    try {
        try{$locked=$mutex.WaitOne(300000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Another offline Windows image operation is active; retry later.'}
        if((Get-VHD -Path $DiskPath).Attached){throw 'Disk is already attached; it was not mounted or detached by this operation.'}
        New-Item -ItemType Directory -Path $MountPath | Out-Null
        $created=$true
        $vhd = Mount-VHD -Path $DiskPath -NoDriveLetter -ReadOnly:$ReadOnly -PassThru
        $mounted = $true
        $disk = $vhd | Get-Disk
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
        $partitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}' })
        if ($partitions.Count -ne 1) { throw 'Expected one Windows data partition.' }
        $partition = $partitions[0]
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath ($MountPath + '\')
        $attached = $true
        if (-not (Test-Path -LiteralPath (Join-Path $MountPath 'Windows\System32\config\SOFTWARE'))) { throw 'Windows system hive was not found.' }
        & $Action $MountPath
    } finally {
        try { if ($attached) { Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath ($MountPath + '\') } }
        finally {
            try {
                if ($mounted) { Dismount-VHD -Path $DiskPath }
                if ($created -and (Test-Path -LiteralPath $MountPath)) { Remove-Item -LiteralPath $MountPath }
            } finally { if($locked){$mutex.ReleaseMutex()};$mutex.Dispose() }
        }
    }
}
