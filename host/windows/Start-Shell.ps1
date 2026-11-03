# Loaded only by the Workstation Terminal profiles, not by agent or provisioning commands.
$env:STARSHIP_CONFIG = Join-Path $PSScriptRoot 'starship.toml'
if (Get-Module -ListAvailable PSReadLine) {
    Import-Module PSReadLine
    if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
        Set-PSReadLineOption -PredictionSource History
        if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionViewStyle')) {
            Set-PSReadLineOption -PredictionViewStyle InlineView
        }
    }
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}
if (Get-Command starship.exe -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship.exe init powershell | Out-String)
}
