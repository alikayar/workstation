#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Ask','Install','Skip')][string]$Extensions = 'Ask')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run VS Code setup on Windows.' }
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use 64-bit PowerShell on Windows x64.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run VS Code setup as your normal desktop user.' }
$script:VSCodeVersion = '1.145.0'
$script:VSCodeInstallerURL = 'https://vscode.download.prss.microsoft.com/dbazure/download/stable/a717861c07586a53d83b80d742cd3f59b20a6273/VSCodeUserSetup-x64-1.145.0.exe'
$script:VSCodeInstallerSHA256 = '3f7c8b905cfd4795b9d5ff9cfded9085bd2fa14a1d5001e94d07c89f021d9950'

function Find-VSCode {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
    $command = Get-Command code.cmd -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $executable = Join-Path (Split-Path -Parent (Split-Path -Parent $candidate)) 'Code.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { continue }
        $version = (Get-Item -LiteralPath $executable).VersionInfo
        if ($version.ProductName -cne 'Visual Studio Code' -or $version.ProductVersion -notmatch '^\d+\.\d+\.\d+$') { continue }
        return [pscustomobject]@{CodePath=$candidate;Version=$version.ProductVersion}
    }
    return $null
}
function Assert-VSCodeInstaller([string]$Path) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $script:VSCodeInstallerSHA256) {
        throw 'VS Code installer SHA256 mismatch; nothing executed.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'VS Code installer must have a valid Microsoft signature; nothing executed.'
    }
}
function Install-PinnedVSCode {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('workstation-vscode-' + [guid]::NewGuid().ToString('N'))
    $installer = Join-Path $directory ('VSCodeUserSetup-x64-' + $script:VSCodeVersion + '.exe')
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "Downloading pinned VS Code Stable $script:VSCodeVersion (x64, current user)..."
        Invoke-WebRequest -UseBasicParsing -Uri $script:VSCodeInstallerURL -MaximumRedirection 0 -TimeoutSec 600 -OutFile $installer
        Assert-VSCodeInstaller $installer
        $process = Start-Process -FilePath $installer -ArgumentList @('/SP-','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/MERGETASKS=!runcode,addtopath') -WindowStyle Hidden -Wait -PassThru
        try {
            if ($process.ExitCode -ne 0) { throw "VS Code installer exited with code $($process.ExitCode)." }
        } finally { $process.Dispose() }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $protocol
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
        # Remove only the empty directory created by this invocation.
        Remove-Item -LiteralPath $directory -ErrorAction SilentlyContinue
    }
}
function Initialize-VSCode {
    $installed = Find-VSCode
    if ($installed) {
        Write-Host "VS Code is already installed: $($installed.Version). Keeping this installation."
        return $installed
    }
    Write-Host 'VS Code Stable is not installed.'
    do {
        $answer = (Read-Host "Install VS Code Stable $script:VSCodeVersion for this user? [Y/n]").Trim()
    } while ($answer -notmatch '^(|y|yes|n|no)$')
    if ($answer -match '^(n|no)$') {
        Write-Host 'VS Code installation declined. Settings and extensions were not changed.'
        return $null
    }
    Install-PinnedVSCode
    $installed = Find-VSCode
    if (-not $installed -or $installed.Version -cne $script:VSCodeVersion) { throw 'Pinned VS Code installation could not be verified; configuration stopped.' }
    Write-Host "VS Code Stable $($installed.Version) installed successfully."
    return $installed
}

function Read-ExtensionChoice([string]$Choice) {
    if ($Choice -eq 'Install') { return $true }
    if ($Choice -eq 'Skip') { return $false }
    do {
        $answer = (Read-Host 'Install Remote SSH and the bundled static Workstation appearance? [Y/n]').Trim()
    } while ($answer -notmatch '^(|y|yes|n|no)$')
    return $answer -match '^(|y|yes)$'
}
function ConvertTo-SettingsMap($Value) {
    if ($null -eq $Value) { return $null }
    $type = $Value.GetType().FullName
    if ($type -eq 'Newtonsoft.Json.Linq.JValue') { return $Value.Value }
    if ($Value -is [array] -or $type -eq 'Newtonsoft.Json.Linq.JArray') {
        $items = New-Object 'Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-SettingsMap $item)) }
        return ,$items.ToArray()
    }
    if ($type -eq 'Newtonsoft.Json.Linq.JObject') {
        $map = [ordered]@{}
        # Enumerate directly: sending a single JProperty through the PowerShell
        # pipeline can unwrap its child tokens and lose the property name.
        foreach ($property in $Value.Properties()) { $map[$property.Name] = ConvertTo-SettingsMap $property.Value }
        return $map
    }
    if ($type -eq 'System.Management.Automation.PSCustomObject') {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = ConvertTo-SettingsMap $property.Value }
        return $map
    }
    return $Value
}
function Read-Settings([string]$Text) {
    # Strip comments first, then trailing commas; quoted strings survive both passes.
    $keepStrings = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value.StartsWith('"')) { return $match.Value }
        return [regex]::Replace($match.Value, '[^\r\n]', ' ')
    }
    $clean = [regex]::Replace($Text, '"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/', $keepStrings)
    $clean = [regex]::Replace($clean, '"(?:\\.|[^"\\])*"|,\s*(?=[}\]])', $keepStrings)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # Use PowerShell's bundled JSON reader without converting date-like strings.
        $inputReader = New-Object IO.StringReader($clean)
        $reader = New-Object Newtonsoft.Json.JsonTextReader($inputReader)
        $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $reader.MaxDepth = 100
        try {
            $raw = [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader)
            if ($reader.Read()) { throw 'Unexpected content after VS Code settings.' }
            $value = ConvertTo-SettingsMap $raw
        } finally { $reader.Close(); $inputReader.Dispose() }
    } else {
        $value = ConvertTo-SettingsMap (ConvertFrom-Json -InputObject $clean)
    }
    if ($value -isnot [Collections.IDictionary]) { throw 'VS Code settings must be an object.' }
    return $value
}
function Test-VSCodeSettingEqual($Left, $Right) {
    if ($Left -is [Collections.IDictionary] -and $Right -is [Collections.IDictionary]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        foreach ($key in $Right.Keys) {
            if (-not $Left.Contains($key) -or -not (Test-VSCodeSettingEqual $Left[$key] $Right[$key])) { return $false }
        }
        return $true
    }
    if ($Left -is [array] -and $Right -is [array]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($index=0; $index -lt $Right.Count; $index++) {
            if (-not (Test-VSCodeSettingEqual $Left[$index] $Right[$index])) { return $false }
        }
        return $true
    }
    $existing = ConvertTo-Json -InputObject $Left -Depth 100 -Compress
    $proposed = ConvertTo-Json -InputObject $Right -Depth 100 -Compress
    return $existing -ceq $proposed
}
function Confirm-VSCodeOverride([string]$Key, $Existing, $Proposed) {
    Write-Warning "VS Code setting conflict: $Key"
    Write-Host ('Current:  ' + (ConvertTo-Json -InputObject $Existing -Depth 100 -Compress))
    Write-Host ('Proposed: ' + (ConvertTo-Json -InputObject $Proposed -Depth 100 -Compress))
    do { $answer = (Read-Host 'Override this value? [y/N]').Trim() } while ($answer -notmatch '^(|y|yes|n|no)$')
    return $answer -match '^(y|yes)$'
}
function Merge-VSCodeSettings([Collections.IDictionary]$Current, [Collections.IDictionary]$Defaults, [string]$Prefix = '') {
    foreach ($key in $Defaults.Keys) {
        $label = if ($Prefix) { $Prefix + ' / ' + $key } else { $key }
        if (-not $Current.Contains($key)) { $Current[$key] = $Defaults[$key] }
        elseif ($Current[$key] -is [Collections.IDictionary] -and $Defaults[$key] -is [Collections.IDictionary]) {
            Merge-VSCodeSettings $Current[$key] $Defaults[$key] $label
        } elseif (-not (Test-VSCodeSettingEqual $Current[$key] $Defaults[$key])) {
            if (Confirm-VSCodeOverride $label $Current[$key] $Defaults[$key]) { $Current[$key] = $Defaults[$key] }
        }
    }
}
function Get-VSCodeExtensions([string]$CodePath) {
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $CodePath --list-extensions --show-versions)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    if ($exitCode -ne 0) { throw 'Could not inspect installed VS Code extensions; configuration stopped.' }
    $installed = @{}
    foreach ($line in $output) {
        if ([string]$line -match '^([a-zA-Z0-9_-]+\.[a-zA-Z0-9._-]+)@(\S+)$') {
            $installed[$Matches[1]] = $Matches[2]
        }
    }
    return $installed
}
function Install-WorkstationAppearance {
    param([string]$ExtensionsRoot = (Join-Path $HOME '.vscode\extensions'))
    $source = Join-Path $PSScriptRoot 'appearance'
    # Refuse linked ancestors as well as linked package contents before copying.
    foreach ($root in @($source, $extensionsRoot)) {
        $cursor = $root
        while ($cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Linked appearance path retained: $cursor"
            }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    }
    $items = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (-not $item.PSIsContainer -and $item.Extension -notin @('.json', '.svg', '.png', '.txt'))) {
            throw "Unexpected appearance asset: $($item.FullName)"
        }
    }
    $manifest = Read-Settings ([IO.File]::ReadAllText((Join-Path $source 'package.json')))
    if ($manifest['publisher'] -cne 'workstation-local' -or $manifest['name'] -cne 'appearance' -or $manifest['version'] -cnotmatch '^\d+\.\d+\.\d+$') {
        throw 'Unexpected Workstation appearance identity.'
    }
    foreach ($key in @('main', 'browser', 'scripts', 'dependencies', 'extensionDependencies', 'extensionPack', 'activationEvents')) {
        if ($manifest.Contains($key)) { throw "Static appearance must not declare $key." }
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $destination = Join-Path $extensionsRoot ('workstation-local.appearance-' + $manifest['version'])
    if (Test-Path -LiteralPath $destination) {
        $existing = Get-Item -LiteralPath $destination -Force
        if (-not $existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Existing appearance destination is not an independent directory; retained.'
        }
        $installedItems = @(Get-ChildItem -LiteralPath $destination -Recurse -Force)
        if (@($installedItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or
            @($installedItems | Where-Object { -not $_.PSIsContainer }).Count -ne $files.Count) {
            throw 'Existing appearance contents differ; retained for review.'
        }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($source.Length + 1)
            $target = Join-Path $destination $relative
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Get-FileHash -LiteralPath $target).Hash -cne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                throw 'Existing appearance contents differ; retain them and bump the bundled version for a deliberate update.'
            }
        }
        Write-Host 'Workstation Appearance is already installed with identical contents.'
        return
    }
    New-Item -ItemType Directory -Path $extensionsRoot -Force | Out-Null
    $staging = Join-Path $extensionsRoot ('.workstation-appearance-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        foreach ($file in $files) {
            $target = Join-Path $staging $file.FullName.Substring($source.Length + 1)
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
        # Directory.Move refuses a destination created concurrently; never overwrite it.
        [IO.Directory]::Move($staging, $destination)
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    Write-Host 'Installed static Workstation Appearance from this checkout. Restart VS Code to load it.'
}
function Install-VSCodeExtensions([string]$CodePath, [Collections.IDictionary]$Installed) {
    $added = @()
    foreach ($extension in @('ms-vscode-remote.remote-ssh')) {
        if ($Installed.Contains($extension)) {
            Write-Host "Extension already installed: $extension ($($Installed[$extension])). Keeping this version."
            continue
        }
        $preference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $CodePath --install-extension $extension
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $preference }
        if ($exitCode -ne 0) { throw "Extension installation failed: $extension (exit $exitCode). Rerun setup to retry." }
        $added += $extension
    }
    if ($added.Count) {
        $verified = Get-VSCodeExtensions $CodePath
        foreach ($extension in $added) {
            if (-not $verified.Contains($extension)) { throw "Extension was not found after installation: $extension. Settings were not changed." }
        }
    }
}
$installed = Initialize-VSCode
if (-not $installed) { return }
$codePath = $installed.CodePath
$installExtensions = Read-ExtensionChoice $Extensions
if ($installExtensions -and [version]$installed.Version -lt [version]'1.104.0') {
    throw 'Workstation Appearance requires VS Code 1.104.0 or newer. Update VS Code explicitly or skip the optional bundle.'
}
$installedExtensions = if ($installExtensions) { Get-VSCodeExtensions $codePath } else { @{} }
$path = Join-Path $env:APPDATA 'Code\User\settings.json'
$directory = Split-Path -Parent $path
if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked settings file retained; configure it manually.' }
$original = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null }
$current = if ($null -ne $original) { Read-Settings $original } else { [ordered]@{} }
if ($current -isnot [Collections.IDictionary]) { throw 'VS Code settings must be an object.' }
$before = ConvertTo-Json -InputObject $current -Depth 100
$defaults = Read-Settings ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'settings.json')))
if ($installExtensions) {
    $defaults['workbench.colorTheme'] = 'Workstation Macchiato'
    $defaults['workbench.iconTheme'] = 'workstation-icons'
}
Merge-VSCodeSettings $current $defaults
if ($installExtensions) {
    Install-WorkstationAppearance
    Install-VSCodeExtensions $codePath $installedExtensions
    foreach ($extension in @('catppuccin.catppuccin-vsc', 'vscode-icons-team.vscode-icons')) {
        if ($installedExtensions.Contains($extension)) {
            Write-Warning "Upstream extension retained: $extension. After confirming the local appearance, uninstall it in VS Code to stop its code and updates."
        }
    }
}
$updated = ConvertTo-Json -InputObject $current -Depth 100
if ($updated -cne $before) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $backup = $path + '.workstation.bak'
    if ((Test-Path -LiteralPath $backup) -and ((Get-Item -LiteralPath $backup).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked settings backup retained; inspect it before retrying.' }
    $latest = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null }
    if ($latest -cne $original) { throw 'VS Code settings changed during setup; rerun to review the latest values.' }
    $temporary = Join-Path $directory ('.workstation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $updated + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, $backup) }
        else { [IO.File]::Move($temporary, $path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
Write-Host 'VS Code setup completed. Restart VS Code after appearance installation; reopen integrated terminals.'
