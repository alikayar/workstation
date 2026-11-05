#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates or resumes an owned Ubuntu Server 26.04 Hyper-V VM without installer questions.
.DESCRIPTION
Run in elevated 64-bit PowerShell on Windows 11 Pro x64. If Hyper-V is disabled,
it is enabled without an automatic restart; reboot Windows and rerun to continue.
Name and resources show defaults; Enter accepts them. The sudo password is entered
into Ubuntu's passwd over authenticated SSH after installation, never into files.
Packer prepares a reusable clean base; new VMs copy it and use cloud-init. Existing guests resume without
rebuilding. PowerShell 7 delegates to 5.1. Packer and its plugin use a private tool folder.
Host-side adapter isolation is installed while the VM is Off. An existing running VM
without this policy must first be shut down normally. Only the Default Switch is supported.
#>
[CmdletBinding()]
param(
    [string]$ImageRoot = "$env:ProgramData\Workstation\Images",
    [string]$IsoPath,
    [ValidatePattern('^[a-z][a-z0-9-]{0,61}[a-z0-9]$')][string]$VMName = 'workstation-ubuntu-26-04',
    [string]$VMRoot = "$env:ProgramData\Workstation\UbuntuVMs",
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,63}$')][string]$SwitchName = 'Default Switch',
    [ValidateRange(2, 64)][int]$CPUs = 4,
    [ValidateRange(4, 32)][int]$MemoryGB = 8,
    [ValidateRange(40, 2048)][int]$DiskGB = 80,
    [ValidatePattern('^[a-z][a-z0-9_]{0,30}$')][string]$UserName = 'dev',
    [switch]$OpenConsole
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\shared\New-ImageVM.ps1') -Guest 'Ubuntu' @PSBoundParameters
