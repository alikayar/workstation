#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates or resumes an owned Windows 11 Pro Hyper-V installation VM.
.DESCRIPTION
Run from an elevated 64-bit Windows PowerShell 5.1 or PowerShell 7 window.
PowerShell 7 delegates to the inbox Windows PowerShell engine. New VMs use
an independent copy of a Packer-built generalized base; existing installations are preserved.
Omitted name/resource parameters are prompted with defaults. Installation media
is verified/downloaded only when building a missing base image.
Existing unrelated VMs and disks are never adopted, resized or deleted.
#>
[CmdletBinding()]
param(
    [string]$ImageRoot = "$env:ProgramData\Workstation\Images",
    [string]$IsoPath,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VMName = 'workstation-windows-pro',
    [string]$VMRoot = "$env:ProgramData\Workstation\WindowsVMs",
    [string]$SwitchName = 'Default Switch',
    [ValidateRange(2, 64)][int]$CPUs = 4,
    [ValidateRange(4, 128)][int]$MemoryGB = 8,
    [ValidateRange(64, 2048)][int]$DiskGB = 120,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,19}$')][string]$UserName = 'dev',
    [switch]$NestedVirtualization,
    [switch]$OpenConsole
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\shared\New-ImageVM.ps1') -Guest 'Windows' @PSBoundParameters
