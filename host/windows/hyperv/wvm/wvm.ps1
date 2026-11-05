#Requires -Version 5.1
# Workstation managed wvm dispatcher v1
<#
.SYNOPSIS
Selects a guest OS and runs its existing Hyper-V installation command.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][ValidateSet('create', 'list', 'start', 'stop', 'delete', 'image', 'help')][string]$Command = 'help',
    [ValidateSet('ubuntu-26-04', 'windows-pro')][string]$OS,
    [Parameter(Position = 1)][string]$VMName,
    [string]$VMRoot,
    [string]$ImageRoot = "$env:ProgramData\Workstation\Images",
    [string]$IsoPath,
    [string]$SwitchName,
    [ValidateRange(2, 64)][int]$CPUs,
    [ValidateRange(4, 32)][int]$MemoryGB,
    [ValidateRange(40, 2048)][int]$DiskGB,
    [string]$UserName,
    [switch]$NestedVirtualization,
    [switch]$OpenConsole,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Command -eq 'help') {
    Write-Output @'
wvm create                         Select Ubuntu Server 26.04 or Windows 11 Pro.
wvm create -OS ubuntu-26-04         Create or resume an Ubuntu VM.
wvm create -OS windows-pro          Create or resume a Windows VM.
wvm list                           List all local Hyper-V VMs without changing them.
wvm start NAME                     Start the exact named VM; optionally -OpenConsole.
wvm stop NAME                      Shut down the exact named VM normally.
wvm delete NAME                    Delete a Workstation-owned VM and its files (asks).
wvm delete NAME -WhatIf             Preview ownership and deletion checks.
wvm delete NAME -Force              Explicitly allow power-off before confirmed deletion.
wvm image build -OS windows-pro    Build/reuse a versioned generalized Windows base.
wvm image build -OS ubuntu-26-04   Build/reuse a versioned clean Ubuntu base.
wvm image list                    List published base images.
wvm help                           Show this help.

Run create/start/stop/delete in administrator, 64-bit PowerShell on Windows 11 x64.
Optional: -VMName -VMRoot -IsoPath -SwitchName -CPUs -MemoryGB -DiskGB
          -UserName -OpenConsole
Windows only: -NestedVirtualization
Omitted settings use the selected installer's prompts/defaults or saved VM record.
Passwords are requested by the selected installer, never command-line arguments.
'@
    return
}
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Run wvm in 64-bit PowerShell on Windows 11 x64.'
}
if ($Command -eq 'create' -and ($WhatIfPreference -or $PSBoundParameters.ContainsKey('WhatIf') -or $PSBoundParameters.ContainsKey('Force'))) { throw '-WhatIf and -Force are not supported for create.' }
if ($Command -in @('start','stop','delete')) {
    if ([string]::IsNullOrWhiteSpace($VMName)) { throw "Supply the exact VM name: wvm $Command NAME" }
    foreach ($name in @('OS','ImageRoot','IsoPath','SwitchName','CPUs','MemoryGB','DiskGB','UserName','NestedVirtualization')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "-$name applies only to create." }
    }
    if ($Command -ne 'start' -and $OpenConsole) { throw '-OpenConsole applies only to create/start.' }
    if ($Command -ne 'delete' -and $Force) { throw '-Force applies only to delete; stop always requests normal shutdown.' }
}
if ($Command -in @('list','start','stop','delete','image') -and $PSVersionTable.PSEdition -eq 'Core') {
    $parameters = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $parameters[$entry.Key] = if ($entry.Value -is [Management.Automation.SwitchParameter]) { [bool]$entry.Value } else { $entry.Value }
    }
    $payload = [Management.Automation.PSSerializer]::Serialize(@{ Script=$PSCommandPath; Parameters=$parameters; WhatIf=[bool]$WhatIfPreference; Confirm=[string]$ConfirmPreference })
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $program = '$p=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $encoded + '''))); $WhatIfPreference=$p.WhatIf; $ConfirmPreference=[Management.Automation.ConfirmImpact]$p.Confirm; $parameters=$p.Parameters; & $p.Script @parameters'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program)))
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell worker failed; inspect its preceding error.' }
    return
}
$sourceRoot = Split-Path -Parent $PSScriptRoot
$locationPath = Join-Path $PSScriptRoot 'wvm-location.json'
if (Test-Path -LiteralPath $locationPath) {
    $location = Get-Content -LiteralPath $locationPath -Raw | ConvertFrom-Json
    if ($location.Schema -ne 1 -or $location.ManagedBy -cne 'Workstation wvm' -or $location.SourceRoot -notmatch '^[a-zA-Z]:[\\/]') { throw 'Invalid wvm location record; rerun Install-WVM.ps1.' }
    $sourceRoot = $location.SourceRoot
}
if ($Command -eq 'list') {
    foreach ($name in @('OS', 'VMName', 'VMRoot', 'IsoPath', 'SwitchName', 'CPUs', 'MemoryGB', 'DiskGB', 'UserName', 'NestedVirtualization', 'OpenConsole', 'Force', 'ImageRoot')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "-$name applies only to wvm create." }
    }
    try {
        Import-Module Hyper-V
        $vms = @(Get-VM | Sort-Object Name)
    } catch {
        throw ('Cannot read Hyper-V inventory. Hyper-V must be enabled and this account needs Hyper-V access; try an administrator PowerShell window. Details: ' + $_.Exception.Message)
    }
    if (-not $vms.Count) { Write-Output 'No Hyper-V VMs found.'; return }
    $vms | Select-Object Name, State, @{Name='CPUs'; Expression={$_.ProcessorCount}},
        @{Name='AssignedGiB'; Expression={[Math]::Round($_.MemoryAssigned / 1GB, 2)}},
        @{Name='StartupGiB'; Expression={[Math]::Round($_.MemoryStartup / 1GB, 2)}}, Uptime | Format-Table -AutoSize
    return
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this wvm command in an administrator PowerShell window. No VM was changed.'
}

if ($Command -eq 'image') {
    if ($VMName -notin @('build','list')) { throw 'Use wvm image build or wvm image list.' }
    if($WhatIfPreference -and $VMName -eq 'build'){throw 'Image builds do not support WhatIf; no builder was created.'}
    foreach($name in @('VMRoot','SwitchName','CPUs','MemoryGB','DiskGB','UserName','NestedVirtualization','Force','WhatIf')){
        if($PSBoundParameters.ContainsKey($name)){throw "-$name is not supported for image commands."}
    }
    if($VMName -eq 'list'){
        if($PSBoundParameters.ContainsKey('IsoPath') -or $OpenConsole){throw 'Image list does not use installation media or a console.'}
        . (Join-Path $sourceRoot 'shared\BaseImage.ps1')
        Assert-PackerPath $ImageRoot
        if(-not(Test-Path -LiteralPath $ImageRoot)){Write-Output 'No base images published.';return}
        Assert-WVMImageACL $ImageRoot
        $rows=@(foreach($folder in @('windows-pro','ubuntu-26-04')){
            if($OS -and $folder -ne $OS){continue}
            $path=Join-Path $ImageRoot $folder;Assert-PackerPath $path
            if(Test-Path -LiteralPath $path){
                foreach($directory in @(Get-ChildItem -LiteralPath $path -Directory)){
                    $manifest=Join-Path $directory.FullName 'image.json';Assert-PackerPath $manifest
                    if(Test-Path -LiteralPath $manifest){$image=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json;if($image.Schema -eq 1 -and $image.Phase -ceq 'Ready'){$image|Select-Object Guest,Version,ID,DiskGB,BuiltAt}}
                }
            }
        })
        if($rows.Count){$rows|Format-Table -AutoSize}else{Write-Output 'No base images published.'}
        return
    }
}
if ($Command -in @('start','stop','delete')) {
    Import-Module Hyper-V
    . (Join-Path $sourceRoot 'shared\WVM-Lifecycle.ps1')
    $options = @{ VMName=$VMName }
    if ($PSBoundParameters.ContainsKey('VMRoot')) { $options.VMRoot=$VMRoot }
    foreach ($name in @('WhatIf','Confirm')) {
        if ($PSBoundParameters.ContainsKey($name)) { $options[$name]=$PSBoundParameters[$name] }
    }
    if ($Command -eq 'delete') {
        $target = Get-WVMTarget $VMName $VMRoot -AllowOrphan
        if (-not $target.Record) { throw 'Only Workstation-owned VMs can be deleted.' }
        $options.VMRoot = Split-Path -Parent $target.Record.Root
        $options.Guest = $target.Guest
        $options.Force = $Force
        & (Join-Path $sourceRoot 'shared\Remove-OwnedVM.ps1') @options
    } else {
        $options.Action = $Command
        if ($Command -eq 'start') { $options.OpenConsole=$OpenConsole }
        Invoke-WVMPower @options
    }
    return
}
if (-not $PSBoundParameters.ContainsKey('OS')) {
    Write-Host '1) Ubuntu Server 26.04'
    Write-Host '2) Windows 11 Pro (25H2)'
    do {
        $choice = (Read-Host 'Guest OS [1]').Trim()
        if (-not $choice) { $choice = '1' }
        switch ($choice) {
            '1' { $OS = 'ubuntu-26-04' }
            '2' { $OS = 'windows-pro' }
            default { Write-Host 'Choose 1 or 2.' -ForegroundColor Yellow }
        }
    } while (-not $OS)
}
if ($Command -eq 'image') {
    $family=if($OS -eq 'windows-pro'){'Windows'}else{'Ubuntu'}
    $options=@{Guest=$family;ImageRoot=$ImageRoot;OpenConsole=$OpenConsole}
    if($PSBoundParameters.ContainsKey('IsoPath')){$options.IsoPath=$IsoPath}
    & (Join-Path $sourceRoot 'shared\Build-BaseImage.ps1') @options
    return
}
if ($OS -eq 'ubuntu-26-04' -and $NestedVirtualization) {
    throw '-NestedVirtualization is supported only for Windows Pro. No VM was changed.'
}

$arguments = @{}
# Forward only explicit options, so each installer keeps its own defaults and resume checks.
foreach ($name in @('VMName', 'VMRoot', 'ImageRoot', 'IsoPath', 'SwitchName', 'CPUs', 'MemoryGB', 'DiskGB', 'UserName', 'OpenConsole')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}
if ($OS -eq 'windows-pro' -and $PSBoundParameters.ContainsKey('NestedVirtualization')) {
    $arguments.NestedVirtualization = $NestedVirtualization
}
$relativePath = if ($OS -eq 'windows-pro') { 'windows-pro\New-WindowsProVM.ps1' } else { 'ubuntu-26-04\New-UbuntuVM.ps1' }
$target = Join-Path $sourceRoot $relativePath
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'The selected installer is missing. Keep the checkout in place or rerun Install-WVM.ps1 from its new location.' }
& $target @arguments
