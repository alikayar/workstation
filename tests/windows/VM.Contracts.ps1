# In-memory device inventories are explicit external-boundary substitutes.
function New-FakeVM([string]$Id, [string]$Path) {
    return [pscustomobject]@{ Id=$Id; Name='fixture-vm'; Notes='fixture'; Path=$Path;
        ConfigurationLocation=$Path; SnapshotFileLocation=$Path; SmartPagingFilePath=$Path;
        Drives=@(); DVDs=@(); Checkpoints=@(); Generation=2; ProcessorCount=2; MemoryStartup=2GB }
}
function Get-VMSnapshot { param($VM) return $VM.Checkpoints }
function Get-VMHardDiskDrive { param($VM, $VMSnapshot) if ($VMSnapshot) { return $VMSnapshot.Drives }; return $VM.Drives }
function Get-VMDvdDrive { param($VM, $VMSnapshot) if ($VMSnapshot) { return $VMSnapshot.DVDs }; return $VM.DVDs }

Add-Case 'Deletion paths respect directory boundaries and case-insensitive Windows identity' {
    param($directory)
    Assert-True (Test-DeletionPath (Join-Path $directory 'disk.vhdx') $directory)
    Assert-True (Test-DeletionPath $directory.ToUpperInvariant() $directory)
    Assert-True (-not (Test-DeletionPath ($directory + '-foreign\disk.vhdx') $directory))
    Assert-True (-not (Test-DeletionPath '' $directory))
    Assert-Equal (Get-WVMDeletionJournalPath 'Fixture-VM') (Get-WVMDeletionJournalPath 'fixture-vm')
    Assert-True ((Get-WVMDeletionJournalPath 'other-vm') -ne (Get-WVMDeletionJournalPath 'fixture-vm'))
}
Add-Case 'Disk inspection refuses cycles, unreadable parents and pass-through drives' {
    param($directory)
    $leaf = Join-Path $directory 'child.avhdx'; $parent = Join-Path $directory 'base.vhdx'
    Write-Fixture $leaf 'fake disk'; Write-Fixture $parent 'fake disk'
    function Get-VHD { param($Path) if ($Path -eq $leaf) { return @{ParentPath=$parent} }; return @{ParentPath=''} }
    Assert-Equal @(Get-DeletionDiskChain $leaf) @($leaf,$parent)
    function Get-VHD { param($Path) return @{ParentPath=$leaf} }
    $null = Assert-Throws { Get-DeletionDiskChain $leaf } 'cycle'
    function Get-VHD { param($Path) throw 'unreadable parent fixture' }
    $missing = Join-Path $directory 'missing.vhdx'
    Assert-Equal @(Get-DeletionDiskChain $missing -AllowMissingLeaf) @($missing)
    $null = Assert-Throws { Get-DeletionDiskChain $leaf -AllowMissingLeaf } 'unreadable parent'
    $null = Assert-Throws { Get-DeletionDiskChain '' } 'pass-through'
}
Add-Case 'Deletion refuses disks referenced by another VM or checkpoint chain' {
    param($directory)
    $base = Join-Path $directory 'base.vhdx'; $child = Join-Path $directory 'child.avhdx'
    Write-Fixture $base 'fake base'; Write-Fixture $child 'fake child'
    $plan = [pscustomobject]@{VMId='owned';Files=@($base);Metadata=$null}
    $other = New-FakeVM 'foreign' $directory
    function Get-VHD { param($Path) if ($Path -eq $child) { return @{ParentPath=$base} }; return @{ParentPath=''} }
    $other.Drives = @([pscustomobject]@{Path=$base})
    $null = Assert-Throws { Assert-VMDeletionReferences $plan @($other) } 'used by another VM'
    $other.Drives = @()
    $checkpoint = New-FakeVM 'checkpoint' $directory
    $checkpoint.Drives = @([pscustomobject]@{Path=$child})
    $other.Checkpoints = @($checkpoint)
    $null = Assert-Throws { Assert-VMDeletionReferences $plan @($other) } 'used by another VM'
    $other.Checkpoints = @()
    Assert-VMDeletionReferences $plan @($other)
}
Add-Case 'Deletion refuses shared setup media and foreign installation directories' {
    param($directory)
    $iso = Join-Path $directory 'seed.iso'; Write-Fixture $iso 'synthetic media'
    $other = New-FakeVM 'foreign' $directory
    $other.DVDs = @([pscustomobject]@{Path=$iso})
    $plan = [pscustomobject]@{VMId='owned';Files=@($iso);Metadata=$null}
    $null = Assert-Throws { Assert-VMDeletionReferences $plan @($other) } 'installation media'
    $other.DVDs = @()
    $plan.Metadata = [pscustomobject]@{Root=$directory}
    $null = Assert-Throws { Assert-VMDeletionReferences $plan @($other) } 'installation directory'
}
Add-Case 'Generic deletion plans keep shared ISOs and foreign GUID files outside the plan' {
    param($directory)
    $owned = '11111111-1111-1111-1111-111111111111'
    $foreign = '22222222-2222-2222-2222-222222222222'
    $config = Join-Path $directory 'shared-config'
    Write-Fixture (Join-Path $config ($owned + '.vmcx')) 'owned config'
    Write-Fixture (Join-Path $config ($foreign + '.vmcx')) 'foreign config'
    $iso = Join-Path $config 'shared.iso'; Write-Fixture $iso 'shared installer'
    $disk = Join-Path $directory 'disk.vhdx'; Write-Fixture $disk 'fake disk'
    $vm = New-FakeVM $owned $config
    $vm.Drives = @([pscustomobject]@{Path=$disk})
    $vm.DVDs = @([pscustomobject]@{Path=$iso})
    function Get-VHD { param($Path) return @{ParentPath=''} }
    function Get-DeletionRecord { param($VM) return $null }
    $plan = New-VMDeletionPlan $vm
    Assert-True ($disk -in $plan.Files)
    Assert-True ((Join-Path $config ($owned + '.vmcx')) -in $plan.Files)
    Assert-True ((Join-Path $config ($foreign + '.vmcx')) -notin $plan.Files)
    Assert-True ($iso -notin $plan.Files)
    Assert-True (Test-Path -LiteralPath $iso)
}
Add-Case 'Linked VM content is refused before a deletion plan can traverse it' {
    param($directory)
    $target = Join-Path $directory 'target'; Write-Fixture (Join-Path $target 'sentinel') 'retained'
    $tree = Join-Path $directory 'tree'; $null = [IO.Directory]::CreateDirectory($tree)
    $null = New-Item -ItemType Junction -Path (Join-Path $tree 'linked') -Target $target
    $null = Assert-Throws { Get-DeletionTree $tree } 'Linked VM content'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $target 'sentinel'))) 'retained'
}
Add-Case 'Recorded VM identity rejects foreign tokens and cannot adopt a missing VMId' {
    param($directory)
    $token = 'a' * 32
    $record = [pscustomobject]@{Schema=1;Backend='Image';Guest='Ubuntu';OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
        Token=$token;Name='fixture-vm';VMId='11111111-1111-1111-1111-111111111111';Root=$directory;CPUs=2;MemoryGB=2;DiskGB=40;DiskPath='';SwitchName='Default Switch';Phase='Complete'}
    $vm = New-FakeVM $record.VMId (Join-Path $directory 'machines\config')
    $vm.Notes = 'Workstation Ubuntu VM ' + $token
    $script:InventoryVM = $vm
    function Get-VM { return $script:InventoryVM }
    $record.Token = 'BAD'
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'ownership record'
    $record.Token = $token
    $vm.Notes = 'foreign identity'
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'identity changed'
    $vm.Notes = 'Workstation Ubuntu VM ' + $token
    $record.VMId = ''
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'cannot be adopted'
}
Add-Case 'Recorded VM checks disk, checkpoint, resources and network before accepting ownership' {
    param($directory)
    $disk = Join-Path $directory 'machines\disk.vhdx'; Write-Fixture $disk 'fake disk'
    $token = 'b' * 32
    $record = [pscustomobject]@{Schema=1;Backend='Image';Guest='Ubuntu';OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
        Token=$token;Name='fixture-vm';VMId='11111111-1111-1111-1111-111111111111';Root=$directory;CPUs=2;MemoryGB=2;DiskGB=40;DiskPath=$disk;SwitchName='Default Switch';Phase='Complete'}
    $vm = New-FakeVM $record.VMId (Join-Path $directory 'machines\config')
    $vm.Notes = 'Workstation Ubuntu VM ' + $token
    $vm.Drives = @([pscustomobject]@{Path=$disk})
    $script:InventoryVM = $vm
    function Get-VM { return $script:InventoryVM }
    function Get-VHD { param($Path) return @{ParentPath='';Size=40GB} }
    function Get-VMNetworkAdapter { param($VM) return [pscustomobject]@{SwitchName='Default Switch'} }
    Assert-Equal ([string](Get-WVMOwnedVM $record).Id) $record.VMId
    $vm.ProcessorCount = 4
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'resources differ'
    $vm.ProcessorCount = 2
    $vm.Checkpoints = @(New-FakeVM 'checkpoint' $vm.Path)
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'Unexpected VM checkpoint'
    $vm.Checkpoints = @()
    $vm.Drives = @([pscustomobject]@{Path=(Join-Path $directory 'foreign.vhdx')})
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'disk attachment differs'
    $vm.Drives = @([pscustomobject]@{Path=$disk})
    function Get-VMNetworkAdapter { param($VM) return [pscustomobject]@{SwitchName='Foreign switch'} }
    $null = Assert-Throws { Get-WVMOwnedVM $record } 'network attachment differs'
}
Add-Case 'IPv4 normalization handles prefix boundaries and refuses IPv6 or invalid masks' {
    param($directory)
    Assert-Equal (ConvertTo-UbuntuIPv4Prefix '192.168.56.123/24') '192.168.56.0/24'
    Assert-Equal (ConvertTo-UbuntuIPv4Prefix '192.168.56.123/0') '0.0.0.0/0'
    Assert-Equal (ConvertTo-UbuntuIPv4Prefix '192.168.56.123') '192.168.56.123/32'
    Assert-Equal (ConvertTo-UbuntuIPv4Prefix 'ANY') 'ANY'
    foreach ($value in @('::1','192.168.1.1/33','192.168.1.1/-1','192.168.1.1/24/1')) {
        $null = Assert-Throws { ConvertTo-UbuntuIPv4Prefix $value } ''
    }
}
Add-Case 'Ubuntu ACL contract limits host access to SSH return flow, DNS and DHCP' {
    param($directory)
    $topology = [pscustomobject]@{Gateway='192.168.56.1';Blocked=@('192.168.0.0/16','10.0.0.0/8')}
    $rules = @(Get-UbuntuNetworkRules $topology)
    Assert-Equal @($rules | Where-Object { $_.Action -eq 'Deny' -and $_.RemoteIPAddress -eq 'ANY' }).Count 2
    foreach ($prefix in $topology.Blocked) {
        $deny = @($rules | Where-Object { $_.Direction -eq 'Outbound' -and $_.Action -eq 'Deny' -and $_.RemoteIPAddress -eq $prefix })
        Assert-Equal $deny.Count 1
        Assert-True ($deny[0].Weight -gt 10000)
    }
    $inboundTcp = @($rules | Where-Object { $_.Action -eq 'Allow' -and $_.Direction -eq 'Inbound' -and $_['Protocol'] -eq 'TCP' })
    Assert-Equal $inboundTcp.Count 1
    Assert-Equal $inboundTcp[0]['LocalPort'] '22'
    Assert-Equal $inboundTcp[0]['RemoteIPAddress'] $topology.Gateway
    Assert-True $inboundTcp[0]['Stateful']
    $hostOutbound = @($rules | Where-Object { $_.Direction -eq 'Outbound' -and $_.Action -eq 'Allow' -and $_.RemoteIPAddress -eq $topology.Gateway })
    Assert-Equal $hostOutbound.Count 3
    foreach ($rule in $hostOutbound) { Assert-True ($rule['RemotePort'] -in @('53','67')) }
    Assert-Equal @($rules | Where-Object { $_.Action -eq 'Allow' -and $_.RemoteIPAddress -match ':' }).Count 0
    Assert-Equal @($rules | Where-Object { $_.Action -eq 'Allow' -and $_['Protocol'] -notin @('TCP','UDP') }).Count 0
}
Add-Case 'ACL reconciliation refuses extra, duplicate and missing rules' {
    param($directory)
    $expected = @(Get-UbuntuNetworkRules ([pscustomobject]@{Gateway='192.168.56.1';Blocked=@('192.168.0.0/16')}))
    Assert-UbuntuNetworkRules ([pscustomobject]@{Extended=$expected}) $expected -Exact
    $null = Assert-Throws { Assert-UbuntuNetworkRules ([pscustomobject]@{Extended=@($expected[0])}) $expected -Exact } ''
    $null = Assert-Throws { Assert-UbuntuNetworkRules ([pscustomobject]@{Extended=@($expected) + @($expected[0])}) $expected -Exact } ''
    $extra = @{Direction='Outbound';Action='Allow';RemoteIPAddress='192.168.56.1';Weight=65000}
    $null = Assert-Throws { Assert-UbuntuNetworkRules ([pscustomobject]@{Extended=@($expected) + @($extra)}) $expected -Exact } ''
    $numeric = $expected[2].Clone(); $numeric.Protocol = '6'; $numeric.RemoteIPAddress = '192.168.56.1/32'
    Assert-Equal (Get-UbuntuNetworkRuleKey $numeric) (Get-UbuntuNetworkRuleKey $expected[2])
}

function New-TestImageACL([string]$Owner, [string]$Writer) {
    $acl = [pscustomobject]@{OwnerSID=$Owner;Access=@()}
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) return New-Object Security.Principal.SecurityIdentifier($this.OwnerSID) }
    if ($Writer) {
        $acl.Access = @([pscustomobject]@{AccessControlType=[Security.AccessControl.AccessControlType]::Allow;
            FileSystemRights=[Security.AccessControl.FileSystemRights]::Write;IdentityReference=(New-Object Security.Principal.SecurityIdentifier($Writer))})
    }
    return $acl
}
Add-Case 'Base image ACL checks reject user owners and unprivileged write rules' {
    param($directory)
    $script:ImageACL = New-TestImageACL 'S-1-5-32-544' ''
    function Get-Acl { param($LiteralPath) return $script:ImageACL }
    Assert-WVMImageACL $directory
    $script:ImageACL = New-TestImageACL 'S-1-5-32-545' ''
    $null = Assert-Throws { Assert-WVMImageACL $directory } 'owned by Administrators or SYSTEM'
    $script:ImageACL = New-TestImageACL 'S-1-5-32-544' 'S-1-5-32-545'
    $null = Assert-Throws { Assert-WVMImageACL $directory } 'unprivileged writes'
}
Add-Case 'Base image manifest checks identity, real file hash and disk shape' {
    param($directory)
    $disk = Join-Path $directory 'base.vhdx'; Write-Fixture $disk 'synthetic base image bytes'
    $spec = [pscustomobject]@{Root=$directory;ImageRoot=$directory;ID='fixture-id';Guest='Ubuntu';MediaSha256=('a' * 64);DiskGB=40}
    $manifest = @{Schema=1;Phase='Ready';ID=$spec.ID;Guest='Ubuntu';MediaSha256=$spec.MediaSha256;DiskSha256=(Get-FileHash -LiteralPath $disk).Hash;DiskGB=40}
    $script:ImageACL = New-TestImageACL 'S-1-5-32-544' ''
    function Get-Acl { param($LiteralPath) return $script:ImageACL }
    function Get-VHD { param($Path) return @{ParentPath='';Size=40GB} }
    Write-Fixture (Join-Path $directory 'image.json') ($manifest | ConvertTo-Json)
    Assert-Equal (Get-WVMBaseImage $spec).DiskPath $disk
    $manifest.ID = 'foreign-id'
    Write-Fixture (Join-Path $directory 'image.json') ($manifest | ConvertTo-Json)
    $null = Assert-Throws { Get-WVMBaseImage $spec } 'manifest differs'
    $manifest.ID = $spec.ID
    Write-Fixture (Join-Path $directory 'image.json') ($manifest | ConvertTo-Json)
    function Get-VHD { param($Path) return @{ParentPath='foreign-parent.vhdx';Size=40GB} }
    $null = Assert-Throws { Get-WVMBaseImage $spec } 'standalone disk'
    Write-Fixture $disk 'tampered image bytes'
    $null = Assert-Throws { Get-WVMBaseImage $spec } 'disk changed'
}
Add-Case 'Cloning reads the published base image after a noisy first build and reuses it' {
    param($directory)
    $library = Export-TestFunctions 'host/windows/hyperv/shared/New-ImageVM.ps1' ((Split-Path -Leaf $directory) + '\clone-image')
    . $library
    $builder = Join-Path (Split-Path -Parent $library) 'Build-BaseImage.ps1'
    Write-Fixture $builder @'
param($Guest, $ImageRoot, $IsoPath, [switch]$OpenConsole)
Write-Output 'Packer: configuration validated.'
$manifestPath = Join-Path $ImageRoot 'image.json'
Move-Item -LiteralPath (Join-Path $ImageRoot 'image.pending.json') -Destination $manifestPath
Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
'@

    $disk = Join-Path $directory 'base.vhdx'
    Write-Fixture $disk 'synthetic base image bytes'
    $spec = [pscustomobject]@{Root=$directory;ImageRoot=$directory;ID='fixture-id';Guest='Ubuntu';MediaSha256=('a' * 64);DiskGB=40}
    $manifest = @{Schema=1;Phase='Ready';ID=$spec.ID;Guest=$spec.Guest;MediaSha256=$spec.MediaSha256;DiskSha256=(Get-FileHash -LiteralPath $disk).Hash;DiskGB=40}
    Write-Fixture (Join-Path $directory 'image.pending.json') ($manifest | ConvertTo-Json)
    $script:ImageACL = New-TestImageACL 'S-1-5-32-544' ''
    function Get-Acl { param($LiteralPath) return $script:ImageACL }
    function Get-VHD { param($Path) return @{ParentPath='';Size=40GB} }

    $images = @(Get-WVMCloneBaseImage $spec)
    Assert-Equal $images.Count 1
    Assert-Equal $images[0].ID $spec.ID
    Assert-Equal $images[0].DiskPath $disk
    Assert-Equal (Get-WVMCloneBaseImage $spec).DiskPath $disk
}
Add-Case 'Frozen recovery payload rejects changed bytes and path traversal' {
    param($directory)
    $hashes = [ordered]@{}
    for ($index=0; $index -lt 8; $index++) {
        $name = 'shared/fixture-' + $index + '.ps1'
        $path = Join-Path (Join-Path $directory 'payload') $name
        Write-Fixture $path '# synthetic build payload'
        $hashes[$name] = (Get-FileHash -LiteralPath $path).Hash
    }
    $record = [pscustomobject]@{Root=$directory;SourceHashes=[pscustomobject]$hashes}
    Assert-WVMImagePayload $record
    Write-Fixture (Join-Path $directory 'payload\shared\fixture-0.ps1') '# altered payload'
    $null = Assert-Throws { Assert-WVMImagePayload $record } 'payload changed'
    $hashes.Remove('shared/fixture-0.ps1')
    $hashes['../outside.ps1'] = 'a' * 64
    $record.SourceHashes = [pscustomobject]$hashes
    $null = Assert-Throws { Assert-WVMImagePayload $record } 'Invalid image-build payload entry'
}

Add-Case 'Power lifecycle WhatIf never starts or stops a VM' {
    param($directory)
    $vm = New-FakeVM ([guid]::NewGuid().ToString()) $directory
    $vm | Add-Member -NotePropertyName State -NotePropertyValue 'Off'
    $script:InventoryVM = $vm
    $script:PowerTarget = [pscustomobject]@{VM=$vm;Record=$null;Guest='Windows'}
    function Get-WVMTarget { param($VMName,$VMRoot) return $script:PowerTarget }
    function Get-VM { param($Id) return $script:InventoryVM }
    Invoke-WVMPower -Action start -VMName $vm.Name -WhatIf | Out-Null
    Assert-Equal $vm.State 'Off'
    $vm.State = 'Running'
    Invoke-WVMPower -Action stop -VMName $vm.Name -WhatIf | Out-Null
    Assert-Equal $vm.State 'Running'
}
Add-Case 'Power lifecycle rejects paused states and incomplete installations' {
    param($directory)
    $vm = New-FakeVM ([guid]::NewGuid().ToString()) $directory
    $vm | Add-Member -NotePropertyName State -NotePropertyValue 'Paused'
    $script:PowerTarget = [pscustomobject]@{VM=$vm;Record=$null;Guest='Windows'}
    function Get-WVMTarget { param($VMName,$VMRoot) return $script:PowerTarget }
    $null = Assert-Throws { Invoke-WVMPower -Action start -VMName $vm.Name -WhatIf } 'busy or paused'
    $vm.State = 'Saved'
    $null = Assert-Throws { Invoke-WVMPower -Action stop -VMName $vm.Name -WhatIf } 'running VM'
    $vm.State = 'Off'
    $script:PowerTarget.Guest = 'Ubuntu'
    $script:PowerTarget.Record = [pscustomobject]@{Root=$directory;Phase='Pending'}
    $null = Assert-Throws { Invoke-WVMPower -Action start -VMName $vm.Name -WhatIf } 'Installation is incomplete'
}
Add-Case 'Power lifecycle rechecks identity after acquiring its operation lock' {
    param($directory)
    $vm = New-FakeVM ([guid]::NewGuid().ToString()) $directory
    $vm | Add-Member -NotePropertyName State -NotePropertyValue 'Off'
    $script:PowerTarget = [pscustomobject]@{VM=$vm;Record=$null;Guest='Windows'}
    $replacement = New-FakeVM ([guid]::NewGuid().ToString()) $directory
    $script:ReplacementTarget = [pscustomobject]@{VM=$replacement;Record=$null;Guest='Windows'}
    $script:LookupCount = 0
    function Get-WVMTarget {
        param($VMName,$VMRoot)
        $script:LookupCount++
        if ($script:LookupCount -eq 1) { return $script:PowerTarget }
        return $script:ReplacementTarget
    }
    $null = Assert-Throws { Invoke-WVMPower -Action start -VMName $vm.Name -WhatIf } 'VM changed before the power operation'
}
