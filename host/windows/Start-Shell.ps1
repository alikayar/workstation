# Loaded only by the Workstation Terminal profiles, not by agent or provisioning commands.
$runtime = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.json') -Raw -ErrorAction Stop | ConvertFrom-Json
$starshipPath = $runtime.StarshipPath
$env:STARSHIP_CONFIG = Join-Path $PSScriptRoot 'starship.toml'
if (Get-Module -ListAvailable PSReadLine) {
    Import-Module PSReadLine
    if (-not [Console]::IsOutputRedirected -and $Host.UI.SupportsVirtualTerminal -and
        (Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
        Set-PSReadLineOption -PredictionSource History
        if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionViewStyle')) {
            Set-PSReadLineOption -PredictionViewStyle InlineView
        }
    }
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}
# Use the executable selected by setup. Terminal may refresh PATH when opening
# a tab, so discovery here would lose portable or newly installed applications.
$starshipInit = & $starshipPath init powershell --print-full-init
if ($LASTEXITCODE -ne 0) { throw "Starship initialization failed (exit $LASTEXITCODE)." }
Invoke-Expression ($starshipInit | Out-String)
