function Get-VMImage([string]$Id) {
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid image identity.' }
    $store = Get-VMStore
    $directory = Assert-VMPath (Join-Path $store.Images $Id) $store.Images
    $record = Read-VMJson (Join-Path $directory 'image.json')
    if ($record.Schema -ne 1 -or $record.Id -cne $Id -or $record.State -ne 'Ready' -or $record.UserName -ne 'dev') { throw 'Image is not ready.' }
    $base = Assert-VMPath (Join-Path $directory 'base.vhdx') $directory
    $null = Assert-VMPath (Join-Path $directory 'finalize-account.sh') $directory
    if (-not (Test-Path -LiteralPath $base) -or -not (Get-Item -LiteralPath $base).IsReadOnly) { throw 'The immutable base image is missing or writable.' }
    if ((Get-VHD -Path $base).ParentPath) { throw 'A published image must be a standalone disk.' }
    return @{ Directory = $directory; Base = $base; Record = $record }
}
function Remove-VMImageBuilder([object]$Build) {
    $store = Get-VMStore
    $directory = Assert-VMPath (Join-Path $store.Images ('build-' + $Build.Id)) $store.Images
    $state = Join-Path $directory $Build.VMName
    $vm = Get-VM -Name $Build.VMName -ErrorAction SilentlyContinue
    $manifest = Join-Path $state 'installation.json'
    if (Test-Path -LiteralPath $manifest) {
        $installation = Read-VMJson $manifest
        if ($installation.Purpose -ne 'TemplateBuilder' -or $installation.Id -cne $Build.InstallationId) { throw 'Image builder ownership differs; it was preserved.' }
    } elseif ($vm -or $Build.Stage -ne 'Published' -or $Build.InstallationId -cnotmatch '^[a-f0-9]{32}$') {
        throw 'Image builder ownership record is missing. It was preserved.'
    }
    if ($vm) {
        if ([string]$vm.Id -cne $Build.VMId -or $vm.State -ne 'Off') { throw 'Image builder must retain its recorded identity and be off before cleanup.' }
        $null = Assert-VMPath $vm.Path $directory
    }
    if (Test-Path -LiteralPath $directory) { Assert-VMTree $directory $store.Images }
    Assert-NoOtherDiskUsers @{ Directory = $directory } $vm
    if ($vm) { Remove-VM -VM $vm -Force }
    # Only the dedicated factory directory; published images are sibling directories.
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    Remove-Item -LiteralPath (Join-Path $store.Images 'build.json')
}
function Get-OrCreateVMImage([object]$Settings, [object]$Setup, [bool]$Refresh) {
    $store = Get-VMStore
    New-Item -ItemType Directory -Path $store.Images -Force | Out-Null
    $guard = [IO.File]::Open((Join-Path $store.Images 'template.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $current = Join-Path $store.Images 'current.json'
        $buildPath = Join-Path $store.Images 'build.json'
        $build = $null
        if (Test-Path -LiteralPath $buildPath) {
            $build = Read-VMJson $buildPath
            if ($build.Id -notmatch '^[a-f0-9]{32}$' -or $build.VMName -cne ('ws-image-' + $build.Id.Substring(0, 12))) { throw 'Invalid image build record.' }
            if ($build.Stage -eq 'Published') {
                $published = Get-VMImage $build.Id
                try { Remove-VMImageBuilder $build; $build = $null }
                catch {
                    if ($Refresh) { throw 'Finish the previous stopped image builder cleanup before refreshing the image.' }
                    Write-Warning "Image is ready, but builder cleanup needs attention: $($_.Exception.Message)"
                    return $published
                }
            }
        }
        if ($null -eq $build -and (Test-Path -LiteralPath $current) -and -not $Refresh) {
            return Get-VMImage (Read-VMJson $current).Id
        }
        if ($null -eq $build) {
            $id = [Guid]::NewGuid().ToString('N')
            $build = [pscustomobject]@{ Id = $id; VMName = ('ws-image-' + $id.Substring(0, 12)); VMId = ''; InstallationId = ''; Stage = 'Provisioning'; PackageDirectory = $store.Commands }
            Write-VMJson $buildPath $build
        }
        $package = $build.PackageDirectory
        $packages = [IO.Path]::GetDirectoryName($store.Commands)
        $null = Assert-VMPath $package $packages
        $Setup = Read-VMJson (Join-Path $package 'setup.json')
        $builderRoot = Assert-VMPath (Join-Path $store.Images ('build-' + $build.Id)) $store.Images
        $state = Join-Path $builderRoot $build.VMName
        $directory = Assert-VMPath (Join-Path $store.Images $build.Id) $store.Images
        if ($build.Stage -eq 'Provisioning') {
            Write-Host 'Preparing the clean Ubuntu image once. Later new VMs reuse it without reinstalling tools.'
            $entry = Join-Path $package 'hyperv\New-WorkstationVM.ps1'
            if (-not (Test-Path -LiteralPath $entry)) { throw 'Repository moved. Rerun host setup to update the VM command installation.' }
            $arguments = @{ GitName = $Setup.GitName; GitEmail = $Setup.GitEmail; PublicKeyPath = $Setup.PublicKeyPath; VMName = $build.VMName; StateRoot = $builderRoot; CPUs = $Setup.Resources.CPUs; MemoryMB = $Setup.Resources.MemoryMB; DiskGB = $Setup.Resources.DiskGB; KnownHostsFile = (Join-Path $state 'known_hosts'); TemplateBuild = $true; PreparedPayload = (Join-Path $package 'payload'); TrustedPackerPath = (Join-Path $package 'tools\packer.exe') }
            # Older pinned recovery packages keep their original cache behavior.
            if ((Get-Command -Name $entry).Parameters.ContainsKey('CacheDirectory')) { $arguments.CacheDirectory = Join-Path $store.Root 'Cache' }
            & $entry @arguments | Out-Host
            $installation = Read-VMJson (Join-Path $state 'installation.json')
            $builder = Get-VM -Name $build.VMName -ErrorAction Stop
            $null = Assert-VMPath $builder.Path $state
            if ($installation.Purpose -ne 'TemplateBuilder') { throw 'Only a fresh dedicated image builder may be sealed.' }
            $build.VMId = [string]$builder.Id
            $build.InstallationId = $installation.Id
            $build.Stage = 'Sealing'
            Write-VMJson $buildPath $build
        }
        if ($build.Stage -eq 'Sealing') {
            $builder = Get-VM -Name $build.VMName -ErrorAction Stop
            if ([string]$builder.Id -cne $build.VMId -or $builder.State -ne 'Running') { throw 'Interrupted image sealing needs inspection. The builder was preserved.' }
            $address = Wait-VMAddress $build.VMName
            $key = (Get-Content -LiteralPath (Join-Path $state 'ssh-host-key.pub') -Raw).Trim() -split '\s+'
            if ($key[0] -ne 'ssh-ed25519') { throw 'Unexpected builder SSH host key.' }
            $known = Join-Path $state 'known_hosts'
            [IO.File]::WriteAllText($known, "$address $($key[0]) $($key[1])`n", (New-Object Text.UTF8Encoding($false)))
            $private = $Setup.PublicKeyPath.Substring(0, $Setup.PublicKeyPath.Length - 4)
            $options = @('-F', 'NUL', '-o', 'IdentityAgent=none', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes', '-i', $private, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', ('UserKnownHostsFile="' + $known.Replace('\', '/') + '"'), '-o', 'ConnectTimeout=15')
            $target = "dev@$address"
            & (Join-Path ([Environment]::SystemDirectory) 'OpenSSH\scp.exe') @options (Join-Path $package 'hyperv\guest\seal-image.sh') "${target}:.local/state/workstation-seal-image.sh"
            if ($LASTEXITCODE -ne 0) { throw 'Could not upload the image sealer.' }
            # Shutdown may close SSH with 255 after confirmed sealing.
            $seal = Invoke-VMNative (Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe') ($options + @($target, "sudo -n sh .local/state/workstation-seal-image.sh $($build.InstallationId) dev"))
            $sshExit = $seal.ExitCode
            $output = $seal.Output
            if ($sshExit -notin @(0, 255)) { throw 'Image sealer failed; the builder was retained.' }
            if ($output -notcontains "WORKSTATION_IMAGE_SEALED=$($build.InstallationId)") { throw 'Image sealing was not confirmed; no image was published.' }
            $build.Stage = 'Sealed'
            Write-VMJson $buildPath $build
        }
        if ($build.Stage -eq 'Sealed') {
            $deadline = (Get-Date).AddMinutes(3)
            do {
                $builder = Get-VM -Name $build.VMName -ErrorAction Stop
                if ([string]$builder.Id -cne $build.VMId) { throw 'Builder identity changed.' }
                if ($builder.State -eq 'Off') { break }
                Start-Sleep -Seconds 2
            } while ((Get-Date) -lt $deadline)
            if ($builder.State -ne 'Off') { throw 'Image builder did not shut down. No disk was copied.' }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $disk = @(Get-VMHardDiskDrive -VM $builder)
            if ($disk.Count -ne 1) { throw 'Unexpected image builder disk layout.' }
            $null = Assert-VMPath $disk[0].Path $state
            $base = Assert-VMPath (Join-Path $directory 'base.vhdx') $directory
            $null = Assert-VMPath (Join-Path $directory 'finalize-account.sh') $directory
            $temporary = Join-Path $directory 'base.pending.vhdx'
            if (-not (Test-Path -LiteralPath $base)) {
                if (-not (Test-Path -LiteralPath $temporary)) { Convert-VHD -Path $disk[0].Path -DestinationPath $temporary -VHDType Dynamic | Out-Null }
                $vhd = Get-VHD -Path $temporary
                $installation = Read-VMJson (Join-Path $state 'installation.json')
                if ($vhd.ParentPath -or $vhd.Size -ne ([long]$installation.Resources.DiskGB * 1GB)) { throw 'Incomplete base image conversion; inspect the retained builder.' }
                Move-Item -LiteralPath $temporary -Destination $base
            }
            $installation = Read-VMJson (Join-Path $state 'installation.json')
            Copy-Item -LiteralPath (Join-Path $state 'payload\finalize-account.sh') -Destination (Join-Path $directory 'finalize-account.sh') -Force
            $record = @{ Schema = 1; Id = $build.Id; State = 'Ready'; UserName = 'dev'; Resources = $installation.Resources; Revision = $installation.Revision; SHA256 = (Get-FileHash -LiteralPath $base -Algorithm SHA256).Hash }
            (Get-Item -LiteralPath $base).IsReadOnly = $true
            Write-VMJson (Join-Path $directory 'image.json') $record
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            & icacls.exe $directory /inheritance:r /grant:r "*$($sid):(OI)(CI)RX" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-83-0:(OI)(CI)RX' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not protect the immutable image directory.' }
            Write-VMJson $current @{ Id = $build.Id }
            $build.Stage = 'Published'
            Write-VMJson $buildPath $build
        }
        if ($build.Stage -ne 'Published') { throw 'Unknown image build stage.' }
        $image = Get-VMImage $build.Id
        try { Remove-VMImageBuilder $build }
        catch { Write-Warning "Image is ready, but its stopped builder cleanup needs attention: $($_.Exception.Message)" }
        return $image
    } finally { $guard.Dispose() }
}
