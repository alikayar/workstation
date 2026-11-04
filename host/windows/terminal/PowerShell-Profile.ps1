#Requires -Version 5.1
# Loaded explicitly by the Workstation profile or a standalone interactive shell.
$vmCommands = Join-Path $PSScriptRoot '..\Commands\hyperv\commands\Shell-Commands.ps1'
if ((Test-Path -LiteralPath $vmCommands) -and -not (Get-Command wvm -ErrorAction SilentlyContinue)) {
    . $vmCommands
}
$runtime = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.json') -Raw -ErrorAction Stop | ConvertFrom-Json
$starshipPath = $runtime.StarshipPath
if (-not $starshipPath -or -not (Test-Path -LiteralPath $starshipPath -PathType Leaf)) { throw 'Recorded Starship executable is missing. Rerun terminal/Install-Terminal.ps1 to refresh the recorded path.' }
$env:STARSHIP_CONFIG = Join-Path $PSScriptRoot 'starship.toml'
# PSReadLine requires a real console; redirected startup must not alter its key bindings.
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and (Get-Module -ListAvailable PSReadLine)) {
    Import-Module PSReadLine
    if ($Host.UI.SupportsVirtualTerminal -and
        (Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
        Set-PSReadLineOption -PredictionSource History
        if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionViewStyle')) {
            Set-PSReadLineOption -PredictionViewStyle InlineView
        }
    }
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}
# A new Terminal tab can rebuild PATH; use the executable selected during setup.
$starshipInit = & $starshipPath init powershell --print-full-init
if ($LASTEXITCODE -ne 0) { throw "Starship initialization failed (exit $LASTEXITCODE)." }
Invoke-Expression ($starshipInit | Out-String)
