function Assert-PlainPath([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked path refused: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Assert-WindowsProImage([object]$Media) {
    $mounted = $false
    try {
        $image = Get-DiskImage -ImagePath $Media.Path
        if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $Media.Path -PassThru; $mounted = $true }
        $volumes = @($image | Get-Volume | Where-Object DriveLetter)
        if ($volumes.Count -ne 1) { throw 'Expected one installation-media volume.' }
        $root = [string]$volumes[0].DriveLetter + ':\'
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $root 'setup.exe')
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Windows Setup must have a valid Microsoft signature.' }
        $wim = Join-Path $root 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $root 'sources\install.esd' }
        $pro = @(Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq 'Windows 11 Pro')
        if ($pro.Count -ne 1) { throw 'Expected Windows 11 Pro, not Enterprise or Pro N.' }
        $detail = Get-WindowsImage -ImagePath $wim -Index $pro[0].ImageIndex
        if ($detail.EditionId -ne 'Professional' -or [int]$detail.Architecture -ne 9 -or [version]$detail.Version -ne [version]$Media.Version) { throw 'Expected the pinned Windows 11 Pro x64 build 26200.6584.' }
    } finally { if ($mounted) { Dismount-DiskImage -ImagePath $Media.Path | Out-Null } }
}

function Get-WindowsProMedia([string]$IsoPath) {
    # Pin the bytes, not the current release offered by Microsoft's download page.
    $media = [pscustomobject]@{
        Version = '10.0.26200.6584'
        Sha256 = 'D141F6030FED50F75E2B03E1EB2E53646C4B21E5386047CB860AF5223F102A32'
        Uri = 'https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso'
        Path = $IsoPath
    }
    if ($IsoPath) {
        $media.Path = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
        Assert-PlainPath $media.Path
        if ([IO.Path]::GetExtension($media.Path) -ine '.iso') { throw 'Select a Windows 11 ISO.' }
        if ((Get-FileHash -LiteralPath $media.Path -Algorithm SHA256).Hash -ine $media.Sha256) { throw 'ISO differs from the pinned Windows 11 25H2 x64 English build 26200.6584.' }
        return $media
    }
    $cache = Join-Path $env:ProgramData 'Workstation\Media'
    $media.Path = Join-Path $cache ('Windows11-26200.6584-x64-en-US-' + $media.Sha256.Substring(0, 12) + '.iso')
    Assert-PlainPath $media.Path
    $mutex = New-Object Threading.Mutex($false, ('Global\Workstation-WindowsISO-' + $media.Sha256))
    $locked = $false
    $partial = $null
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is preparing the Windows ISO. Retry after it finishes.' }
        if (Test-Path -LiteralPath $media.Path) {
            if ((Get-FileHash -LiteralPath $media.Path -Algorithm SHA256).Hash -ine $media.Sha256) { throw 'Cached Windows ISO hash differs; file preserved for inspection.' }
            return $media
        }
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        Assert-PlainPath $media.Path
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $drive = [IO.Path]::GetPathRoot($cache).Substring(0, 1)
        if ((Get-Volume -DriveLetter $drive).SizeRemaining -lt 12GB) { throw 'Leave at least 12 GiB free for Windows installation media.' }
        $partial = $media.Path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        Write-Host 'Downloading pinned Windows 11 25H2 x64 English media from Microsoft...'
        # Refuse redirects rather than silently fetching from an unapproved host.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $media.Uri -OutFile $partial -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3600
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $media.Sha256) { throw 'Downloaded ISO differs from the pinned Microsoft SHA256; VM creation stopped.' }
        [IO.File]::Move($partial, $media.Path)
        return $media
    } finally {
        try { if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial -Force } }
        finally {
            [Net.ServicePointManager]::SecurityProtocol = $protocol
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}
