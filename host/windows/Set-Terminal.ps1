#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$StarshipPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Run this script on the Windows host.' }

# Resolve dependencies during setup, before Terminal can rebuild the environment
# for a new tab. Portable installs can supply the executable explicitly.
if (-not $StarshipPath) {
    $StarshipPath = (Get-Command starship.exe -CommandType Application -ErrorAction Stop).Source
}
$StarshipPath = (Resolve-Path -LiteralPath $StarshipPath -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $StarshipPath -PathType Leaf) -or [IO.Path]::GetExtension($StarshipPath) -ne '.exe') {
    throw 'Select the installed Starship executable.'
}

# Own only these files; Terminal merges the fragment with the user's existing settings.
$destination = Join-Path $env:LOCALAPPDATA 'Workstation\Terminal'
$fragments = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Workstation'
New-Item -ItemType Directory -Path $destination, $fragments -Force | Out-Null
function Write-ChangedText([string]$Path, [string]$Content) {
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Content) { return }
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
$source = Join-Path $PSScriptRoot '..\..\dotfiles\starship\starship.toml'
$prompt = [IO.File]::ReadAllText($source)
# Share the VM layout; a permanent host label makes local commands easy to distinguish.
$prompt += @'

[hostname]
ssh_only = false
format = '[host:$hostname]($style) '
style = 'bold cyan'
'@
Write-ChangedText (Join-Path $destination 'starship.toml') $prompt
Write-ChangedText (Join-Path $destination 'Start-Shell.ps1') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start-Shell.ps1')))
Write-ChangedText (Join-Path $destination 'runtime.json') (@{ StarshipPath = $StarshipPath } | ConvertTo-Json)

$fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$fontPath = Join-Path $fontDirectory 'Workstation-JetBrainsMonoNF-v3.4.0.ttf'
# Pinned from the upstream v3.4.0 font artifact; check before registering or loading it.
$fontSha256 = '0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9'
New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $fontPath)) {
    $download = "$fontPath.download"
    try {
        Invoke-WebRequest 'https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.4.0/patched-fonts/JetBrainsMono/Ligatures/Regular/JetBrainsMonoNerdFont-Regular.ttf' -OutFile $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $fontSha256) {
            throw 'Downloaded font SHA-256 mismatch. The font was not installed.'
        }
        Move-Item -LiteralPath $download -Destination $fontPath
    } finally {
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
$startup = Join-Path $destination 'Start-Shell.ps1'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
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
Write-Host 'Reopen Windows Terminal and select Workstation. You can make it the default in Settings > Startup.'
Write-Host 'Use Workstation (Windows PowerShell 5.1) for the Hyper-V trial. Existing profiles and settings were preserved.'
