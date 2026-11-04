# Stable, admin-owned entry point for Start menu and per-VM shortcuts.
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][ValidateSet('new', 'open', 'stop', 'destroy', 'list', 'template')][string]$Action = 'open',
    [Parameter(Position = 1)][string]$Name,
    [ValidateRange(0,64)][int]$CPUs = 0,
    [ValidateRange(0,131072)][int]$MemoryMB = 0,
    [switch]$Refresh,
    [switch]$FromShortcut
)
$ErrorActionPreference = 'Stop'
$package = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'current.json') -Raw | ConvertFrom-Json
& (Join-Path $package.Directory 'hyperv\commands\Invoke-VM.ps1') @PSBoundParameters
