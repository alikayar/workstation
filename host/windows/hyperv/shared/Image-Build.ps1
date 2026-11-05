. (Join-Path $PSScriptRoot 'VM.ps1')
. (Join-Path $PSScriptRoot 'BaseImage.ps1')

function Get-WVMBuilder([object]$Record, [switch]$Register) {
    if ($Record.ImageID -cnotmatch '^[a-f0-9]{64}$' -or $Record.Guest -cnotin @('Windows','Ubuntu')) { throw 'Invalid image-builder record.' }
    Assert-WVMImagePayload $Record
    Get-WVMOwnedVM $Record -RegisterBuild:$Register
}

function Assert-WVMWindowsGeneralized([object]$Record) {
    Invoke-WVMWindowsDisk $Record.DiskPath (Join-Path $Record.Root 'verify-mount') -ReadOnly -Action {
        param($mount)
        $seal = Get-Content -LiteralPath (Join-Path $mount 'ProgramData\Workstation\BaseImage\sealed.json') -Raw | ConvertFrom-Json
        if ($seal.ImageID -cne $Record.ImageID -or $seal.Token -cne $Record.Token) { throw 'Windows sealing identity differs; image refused.' }
        $hive = Join-Path $Record.Root 'verify-software'
        if (Test-Path -LiteralPath $hive) { throw 'Previous verification hive retained; inspect before retrying.' }
        $source = Join-Path $mount 'Windows\System32\config\SOFTWARE'
        foreach ($suffix in @('','.LOG1','.LOG2')) { if (Test-Path -LiteralPath ($source+$suffix)) { Copy-Item -LiteralPath ($source+$suffix) -Destination ($hive+$suffix) } }
        $key = 'WVMImage-' + $Record.Token
        $loaded = $false
        try {
            & "$env:WINDIR\System32\reg.exe" load ('HKLM\'+$key) $hive | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not load the private verification copy of SOFTWARE.' }
            $loaded = $true
            $state = (Get-ItemProperty ('Registry::HKEY_LOCAL_MACHINE\'+$key+'\Microsoft\Windows\CurrentVersion\Setup\State')).ImageState
            if ($state -cne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Sysprep has not generalized Windows to OOBE; image refused.' }
        } finally {
            if ($loaded) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                & "$env:WINDIR\System32\reg.exe" unload ('HKLM\'+$key) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Verification hive remains loaded; files retained.' }
            }
            foreach ($suffix in @('','.LOG1','.LOG2')) { if (Test-Path -LiteralPath ($hive+$suffix)) { Remove-Item -LiteralPath ($hive+$suffix) } }
        }
    }
}

function Complete-WVMImageBuild([string]$RecordPath, [switch]$Resume) {
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if ($record.Guest -eq 'Ubuntu') { . (Join-Path $PSScriptRoot '..\ubuntu-26-04\Ubuntu-Setup.ps1') }
    $null = Get-WVMBuilder $record -Register
    $processPath = Join-Path $record.Root 'setup-process.json'
    Save-PackerText $processPath (@{Id=$PID;Started=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}|ConvertTo-Json)
    try {
        if ($record.Guest -eq 'Ubuntu' -and -not $record.Generalized -and -not $record.SealAttested) {
            if ((Get-WVMBuilder $record).State -ne 'Running') { throw 'Ubuntu builder is not running and has no sealing attestation; inspect it before retrying.' }
            $key = Join-Path $record.Root 'ssh-ed25519'; $known = Join-Path $record.Root 'known_hosts'
            $address = Wait-UbuntuAddress $record $key $known
            $options = @('-F','NUL','-i',$key,'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','ForwardAgent=no','-o','StrictHostKeyChecking=yes','-o',('HostKeyAlias=workstation-ubuntu-'+$record.Token),'-o',('UserKnownHostsFile="'+$known.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=NUL','-o','ConnectTimeout=10')
            $ssh = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
            $target = $record.UserName+'@'+$address
            Wait-UbuntuFirstBoot -Ssh $ssh -Options $options -Target $target -InstallationId $record.Token
            $sourceScript = Join-Path $record.Root 'payload\ubuntu-26-04\image\seal-image.sh'
            $script = Join-Path $record.Root 'seal-upload.sh'
            Save-UbuntuText $script ([IO.File]::ReadAllText($sourceScript).Replace("`r`n","`n"))
            $remote = '/tmp/wvm-image-seal-'+$record.Token+'.sh'
            & (Join-Path ([Environment]::SystemDirectory) 'OpenSSH\scp.exe') @options $script ($target+':'+$remote)
            if ($LASTEXITCODE -ne 0) { throw 'Image sealing program upload failed.' }
            $preference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& $ssh @options $target ('sudo -n sh '+$remote+' '+$record.ImageID+' '+$record.Token+' wvmimage'))
                $exitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $preference }
            $marker = 'WORKSTATION-IMAGE-SEALED:'+$record.ImageID+':'+$record.Token
            if ($exitCode -notin @(0,255) -or @($output | Where-Object { [string]$_ -ceq $marker }).Count -ne 1) { throw 'Ubuntu sealing was not attested by its pinned session; image retained, not published.' }
            $record.SealAttested = $true; Save-WVMRecord $record
        }
        $deadline = (Get-Date).AddMinutes(70)
        do {
            $vm = Get-WVMBuilder $record
            if ($vm.State -eq 'Off') { break }
            if ((Get-Date) -ge $deadline) { throw 'Image builder did not shut down after generalization; no forced power-off.' }
            $parentPath = Join-Path $record.Root 'packer-process.json'
            if (-not $Resume -and -not (Test-Path -LiteralPath $parentPath)) { throw 'Packer parent record disappeared; builder retained.' }
            if (-not $Resume -and (Test-Path -LiteralPath $parentPath)) {
                $saved = Get-Content -LiteralPath $parentPath -Raw | ConvertFrom-Json
                $parent = Get-Process -Id $saved.Id -ErrorAction SilentlyContinue
                if (-not $parent -or $parent.StartTime.ToUniversalTime().Ticks -ne [long]$saved.Started) { throw 'Image Packer parent exited; builder retained.' }
            }
            Start-Sleep -Seconds 3
        } while ($true)
        if ($record.Guest -eq 'Windows') { Assert-WVMWindowsGeneralized $record }
        elseif (-not $record.SealAttested) { throw 'Ubuntu sealing proof is missing.' }
        # Pin a byte-for-byte sealed disk before Packer exports/unregisters its temporary VM.
        $hash=(Get-FileHash -LiteralPath $record.DiskPath).Hash
        $sealed=Join-Path $record.Root 'sealed.vhdx'
        $partial=$sealed+'.partial'
        foreach($path in @($sealed,$partial)){Assert-PackerPath $path}
        if(-not(Test-Path -LiteralPath $sealed)){
            if(-not(Test-Path -LiteralPath $partial)){Copy-Item -LiteralPath $record.DiskPath -Destination $partial}
            if((Get-FileHash -LiteralPath $partial).Hash -cne $hash){throw 'Partial sealed disk differs; image was not attested.'}
            [IO.File]::Move($partial,$sealed)
        }
        if((Get-FileHash -LiteralPath $sealed).Hash -cne $hash){throw 'Sealed disk differs; image was not attested.'}
        $record.SealedDiskSha256=$hash
        $record.Generalized=$true; Save-WVMRecord $record
    } finally { if(Test-Path -LiteralPath $processPath){Remove-Item -LiteralPath $processPath} }
}
