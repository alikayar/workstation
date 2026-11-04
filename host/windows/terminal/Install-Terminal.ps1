#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run terminal setup on Windows.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run terminal setup in a normal PowerShell window as your desktop user.' }

function Update-TerminalProcessPath {
    $paths = @($env:Path, [Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))
    $env:Path = (($paths -join ';') -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';'
}
Update-TerminalProcessPath
foreach ($package in @(
    @{ Id = 'Microsoft.PowerShell'; Command = 'pwsh.exe' },
    @{ Id = 'Microsoft.WindowsTerminal'; Command = 'wt.exe' },
    @{ Id = 'Starship.Starship'; Command = 'starship.exe' }
)) {
    if (Get-Command $package.Command -CommandType Application -ErrorAction SilentlyContinue) { continue }
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'Install or update App Installer from Microsoft Store, then reopen PowerShell and rerun terminal setup.' }
    # Windows PowerShell can treat native stderr as an error even on exit zero.
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $winget.Source install --id $package.Id --exact --source winget --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    if ($exitCode -ne 0) { throw "Installation failed for $($package.Id) (exit $exitCode). Rerun after resolving the package-manager error." }
    Update-TerminalProcessPath
    if (-not (Get-Command $package.Command -CommandType Application -ErrorAction SilentlyContinue)) { throw "$($package.Id) was installed but its command is not available. Reopen PowerShell and rerun terminal setup." }
}
$starshipPath = (Get-Command starship.exe -CommandType Application -ErrorAction Stop).Source

$StarshipPath = (Resolve-Path -LiteralPath $StarshipPath).ProviderPath
if (-not (Test-Path -LiteralPath $StarshipPath -PathType Leaf) -or [IO.Path]::GetExtension($StarshipPath) -ine '.exe') { throw 'Select the installed Starship executable.' }

function Write-ChangedText([string]$Path, [string]$Content) {
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Content) { return }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
$source = Join-Path $PSScriptRoot '..\..\..\dotfiles\starship\starship.toml'
$prompt = [IO.File]::ReadAllText($source)
# Distinguish local commands from the Ubuntu prompt without maintaining a second theme.
$prompt += @'

[hostname]
ssh_only = false
format = '[host:$hostname]($style) '
style = 'bold cyan'
'@
$startupContent = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerShell-Profile.ps1'))
$destination = Join-Path $env:LOCALAPPDATA 'Workstation\Terminal'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Write-ChangedText (Join-Path $destination 'starship.toml') $prompt
Write-ChangedText (Join-Path $destination 'runtime.json') (@{ StarshipPath = $StarshipPath } | ConvertTo-Json)
$startup = Join-Path $destination 'PowerShell-Profile.ps1'
Write-ChangedText $startup $startupContent

$pwsh = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
# Own only these files; Terminal merges the fragment with the user's existing settings.
$fragments = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Workstation'
New-Item -ItemType Directory -Path $fragments -Force | Out-Null
$fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$fontPath = Join-Path $fontDirectory 'Workstation-JetBrainsMonoNF-v3.4.0.ttf'
# Pinned from the upstream v3.4.0 font artifact; check before registering or loading it.
$fontSha256 = '0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9'
New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $fontPath)) {
    $download = "$fontPath.download"
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.4.0/patched-fonts/JetBrainsMono/Ligatures/Regular/JetBrainsMonoNerdFont-Regular.ttf' -OutFile $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $fontSha256) {
            throw 'Downloaded font SHA-256 mismatch. The font was not installed.'
        }
        Move-Item -LiteralPath $download -Destination $fontPath
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $protocol
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download }
    }
}
if ((Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash -ne $fontSha256) {
    throw "Font SHA-256 mismatch at $fontPath. Inspect that file before retrying; it was not registered or loaded."
}
$fontRegistry = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
if (-not (Test-Path $fontRegistry)) { New-Item -Path $fontRegistry -Force | Out-Null }
$fontName = 'Workstation JetBrainsMono Nerd Font Regular (TrueType)'
$fontKey = Get-Item -LiteralPath $fontRegistry
try { $registered = $fontKey.GetValue($fontName, $null) } finally { $fontKey.Close() }
if ($registered -ne $fontPath) {
    New-ItemProperty -Path $fontRegistry -Name $fontName -Value $fontPath -PropertyType String -Force | Out-Null
}
# Register for the current session too; no administrator rights or system-wide font changes.
if (-not ('WorkstationFont' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WorkstationFont {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResourceEx(string path, uint flags, IntPtr reserved);
}
'@
}
Add-Type -AssemblyName System.Drawing
$installedFonts = [System.Drawing.Text.InstalledFontCollection]::new()
try { $fontAvailable = $installedFonts.Families.Name -contains 'JetBrainsMono Nerd Font' } finally { $installedFonts.Dispose() }
if (-not $fontAvailable -and [WorkstationFont]::AddFontResourceEx($fontPath, 0, [IntPtr]::Zero) -eq 0) {
    throw 'The font could not be loaded. Sign out and back in before retrying.'
}
$scheme = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'slate-glass.json') -Raw | ConvertFrom-Json
$profiles = @(
    @{ guid = '{b3de38ac-e576-41d4-a1a4-375df22409f4}'; name = 'Workstation'; executable = $pwsh },
    @{ guid = '{987c66a7-47cd-4a29-a75a-fdb36cd5ae90}'; name = 'Workstation (Windows PowerShell 5.1)'; executable = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
) | ForEach-Object {
    [ordered]@{
        guid = $_.guid; name = $_.name
        commandline = '"' + $_.executable + '" -NoLogo -NoProfile -NoExit -File "' + $startup + '"'
        startingDirectory = '%USERPROFILE%'
        colorScheme = $scheme.name
        font = [ordered]@{ face = 'JetBrainsMono Nerd Font'; size = 13; weight = 'normal' }
        opacity = 62; useAcrylic = $true; padding = '20, 16'
        cursorShape = 'bar'; hidden = $false
    }
}
$fragment = [ordered]@{ profiles = @($profiles); schemes = @($scheme) } | ConvertTo-Json -Depth 8
Write-ChangedText (Join-Path $fragments 'workstation.json') $fragment
function Set-DefaultTerminalProfile([string]$Content) {
    # Tokenize JSONC so comments, nested properties and formatting survive unchanged.
    $tokens = @([regex]::Matches($Content, '(?s)//[^\r\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}\[\]:,]|[^\s{}\[\]:,]+') | Where-Object { $_.Value -notmatch '^/' })
    if ($tokens.Count -lt 2 -or $tokens[0].Value -ne '{' -or $tokens[-1].Value -ne '}') { throw 'Terminal settings must contain a JSON object; settings were retained.' }
    $depth = 0
    $valueToken = $null
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($depth -eq 1 -and $token.Value.StartsWith('"') -and $i + 2 -lt $tokens.Count -and $tokens[$i + 1].Value -eq ':') {
            $name = ConvertFrom-Json ('[' + $token.Value + ']')
            if ($name -eq 'defaultProfile') {
                if ($null -ne $valueToken -or -not $tokens[$i + 2].Value.StartsWith('"')) { throw 'Ambiguous defaultProfile in Terminal settings; settings were retained.' }
                $valueToken = $tokens[$i + 2]
            }
        }
        if ($token.Value -eq '{' -or $token.Value -eq '[') { $depth++ }
        if ($token.Value -eq '}' -or $token.Value -eq ']') { $depth-- }
    }
    if ($depth -ne 0) { throw 'Unbalanced Terminal settings; settings were retained.' }
    $value = '"{b3de38ac-e576-41d4-a1a4-375df22409f4}"'
    if ($null -ne $valueToken) { return $Content.Remove($valueToken.Index, $valueToken.Length).Insert($valueToken.Index, $value) }
    $comma = if ($tokens.Count -gt 2) { ',' } else { '' }
    return $Content.Insert($tokens[0].Index + 1, "`r`n    `"defaultProfile`": $value$comma`r`n")
}
$settingsPaths = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if (-not $settingsPaths) {
    $packaged = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction Stop
    $settingsDirectory = if ($packaged) { Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState' } else { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal' }
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $settingsPaths = @(Join-Path $settingsDirectory 'settings.json')
}
foreach ($settingsPath in $settingsPaths) {
    $original = if (Test-Path -LiteralPath $settingsPath) { [IO.File]::ReadAllText($settingsPath) } else { '{}' }
    $updated = Set-DefaultTerminalProfile $original
    if ($updated -ceq $original) { continue }
    if (Test-Path -LiteralPath $settingsPath) {
        $backup = $settingsPath + '.workstation-backup'
        if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($settingsPath, $backup, $false) }
        if ([IO.File]::ReadAllText($settingsPath) -cne $original) { throw 'Terminal settings changed during installation. Rerun setup.' }
    }
    Write-ChangedText $settingsPath $updated
}
Write-Host 'Reopen Windows Terminal. Workstation is now the default profile.'
