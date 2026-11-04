# Loaded only in the managed interactive Workstation terminal profiles.
function global:wvm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)][ValidateSet('new', 'open', 'stop', 'destroy', 'list', 'template')][string]$Action = 'open',
        [Parameter(Position = 1)][string]$Name,
        [ValidateRange(0, 64)][int]$CPUs = 0,
        [ValidateRange(0, 131072)][int]$MemoryMB = 0,
        [switch]$Refresh
    )
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ("Workstation\" + $sid)
    $package = Get-Content -LiteralPath (Join-Path $root 'current.json') -Raw | ConvertFrom-Json
    & (Join-Path $package.Directory 'hyperv\commands\Invoke-VM.ps1') @PSBoundParameters
}
