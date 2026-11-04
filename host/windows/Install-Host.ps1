#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on the Windows host.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run host application setup in a normal PowerShell window as your desktop user.'
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'Install or update App Installer from Microsoft Store, then reopen PowerShell.'
}

$code = Get-Command code.cmd -ErrorAction SilentlyContinue
if (-not $code) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
    )
    $codePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $codePath) {
        & winget.exe install --id Microsoft.VisualStudioCode --exact --source winget --scope user --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "VS Code installation failed (exit $LASTEXITCODE)." }
        $codePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
    }
} else { $codePath = $code.Source }
if (-not (Test-Path -LiteralPath $codePath)) { throw 'VS Code CLI was not found after installation.' }

foreach ($package in @(
    @{ Id = 'Microsoft.WindowsTerminal'; Command = 'wt.exe' },
    @{ Id = 'Microsoft.PowerShell'; Command = 'pwsh.exe' },
    @{ Id = 'Starship.Starship'; Command = 'starship.exe' }
)) {
    if (-not (Get-Command $package.Command -ErrorAction SilentlyContinue)) {
        & winget.exe install --id $package.Id --exact --source winget --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Installation failed for $($package.Id) (exit $LASTEXITCODE)." }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
        if (-not (Get-Command $package.Command -ErrorAction SilentlyContinue)) {
            throw "$($package.Id) was installed but its command is not available. Reopen PowerShell and rerun this script."
        }
    }
}
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Workstation\setup.json')) {
    & (Join-Path $PSScriptRoot 'Install-VMCommands.ps1') -CodePath $codePath
} else {
    Write-Host 'Run setup.ps1 to choose VM defaults and install the protected wvm commands.'
}
$pwshPath = (Get-Command pwsh.exe).Source
$starshipPath = (Get-Command starship.exe -CommandType Application -ErrorAction Stop).Source
& $pwshPath -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'terminal\Set-Terminal.ps1') -StarshipPath $starshipPath
if ($LASTEXITCODE -ne 0) { throw 'Terminal configuration did not finish. Rerun after resolving the reported error.' }
Write-Host 'VS Code and the Workstation terminal profiles are ready. The isolated editor installs Remote - SSH on first wvm open.'
