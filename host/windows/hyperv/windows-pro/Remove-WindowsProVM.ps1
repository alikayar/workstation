#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Deletes an owned Windows Pro VM and its files, or cleans its orphaned files.
.DESCRIPTION
Requires the installation record or an interrupted-deletion journal. Shared ISO
cache is retained. -Force permits powering off a running or saved VM; it does
not bypass ownership checks or the active installation lock. Supports -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VMName,
    [string]$VMRoot = "$env:ProgramData\Workstation\WindowsVMs",
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$arguments = @{ Guest = 'Windows'; VMName = $VMName; VMRoot = $VMRoot; Force = $Force }
foreach ($name in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}
& (Join-Path $PSScriptRoot '..\shared\Remove-OwnedVM.ps1') @arguments
