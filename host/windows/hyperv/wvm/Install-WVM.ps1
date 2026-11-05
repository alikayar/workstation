#Requires -Version 5.1
<#
.SYNOPSIS
Installs the wvm command pointing to this checkout; no host packages or VMs are installed.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Run this installer in 64-bit Windows PowerShell.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Install wvm in a normal PowerShell window as your desktop user.' }

$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'windows-pro\Windows-Media.ps1')
$entry = Join-Path $PSScriptRoot 'wvm.ps1'
$directory = Join-Path $env:LOCALAPPDATA 'Workstation\bin'
$launcher = Join-Path $directory 'wvm.cmd'
$installedEntry = Join-Path $directory 'wvm.ps1'
$locationPath = Join-Path $directory 'wvm-location.json'
foreach ($path in @($entry, $directory, $launcher, $installedEntry, $locationPath)) { Assert-PlainPath $path }
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'The wvm entry point is missing from this checkout.' }
$marker = 'rem Workstation managed wvm launcher v1'
if (Test-Path -LiteralPath $launcher) {
    $lines = @(Get-Content -LiteralPath $launcher -TotalCount 2)
    if ($lines.Count -lt 2 -or $lines[1] -cne $marker) { throw 'Existing wvm.cmd is not managed by Workstation; file preserved.' }
}
if (Test-Path -LiteralPath $locationPath) {
    $prior = Get-Content -LiteralPath $locationPath -Raw | ConvertFrom-Json
    if ($prior.Schema -ne 1 -or $prior.ManagedBy -cne 'Workstation wvm') { throw 'Existing wvm location record is not managed; files preserved.' }
}
if (Test-Path -LiteralPath $installedEntry) {
    $lines = @(Get-Content -LiteralPath $installedEntry -TotalCount 2)
    if ($lines.Count -lt 2 -or $lines[1] -cne '# Workstation managed wvm dispatcher v1') { throw 'Existing wvm.ps1 is not managed by Workstation; file preserved.' }
}
foreach ($command in @(Get-Command wvm -All -ErrorAction SilentlyContinue)) {
    if (-not (($command.CommandType -eq 'Application' -and $command.Source -ieq $launcher) -or ($command.CommandType -eq 'ExternalScript' -and $command.Source -ieq $installedEntry))) { throw 'Another wvm command already exists; it was not replaced.' }
}
$content = @(
    '@echo off', $marker, 'setlocal DisableDelayedExpansion',
    '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0wvm.ps1" %*',
    'exit /b %errorlevel%', ''
) -join "`r`n"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
function Save-WVMFile([string]$Path, [string]$Content, [Text.Encoding]$Encoding = (New-Object Text.UTF8Encoding($true))) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, $Encoding)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
$entryText = @'
#Requires -Version 5.1
# Workstation managed wvm dispatcher v1
$ErrorActionPreference = 'Stop'
$location = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wvm-location.json') -Raw | ConvertFrom-Json
if ($location.Schema -ne 1 -or $location.ManagedBy -cne 'Workstation wvm' -or $location.SourceRoot -notmatch '^[a-zA-Z]:[\\/]') {
    throw 'Invalid wvm location record; rerun Install-WVM.ps1.'
}
$entry = Join-Path $location.SourceRoot 'wvm\wvm.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Checkout entry is missing; rerun Install-WVM.ps1 from its new location.' }
# Native -File preserves command-line option parsing without evaluating user text.
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $entry @args
exit $LASTEXITCODE
'@
# Keep Unicode checkout paths out of CMD; PowerShell reads them from the UTF-8 record.
$location = @{ Schema = 1; ManagedBy = 'Workstation wvm'; SourceRoot = $sourceRoot }
Save-WVMFile $locationPath ($location | ConvertTo-Json)
Save-WVMFile $installedEntry $entryText
# The launcher is ASCII so CMD does not need a code-page change.
Save-WVMFile $launcher $content ([Text.Encoding]::ASCII)

$userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
if ($directory -in @($userPath -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).Trim().Trim('"').TrimEnd('\') })) {
    Write-Host 'wvm is already on the user PATH.'
} else {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $directory).TrimStart(';'), 'User')
}
if ($directory -notin @($env:Path -split ';' | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') })) { $env:Path += ';' + $directory }
Write-Host 'wvm installed for this user. Run wvm help; create requires an administrator PowerShell window.'
Write-Host 'Keep this checkout in place; rerun Install-WVM.ps1 after moving it. Restart your Windows session if another terminal retains an old PATH.'
