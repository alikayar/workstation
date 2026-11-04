#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$StageId,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-[0-9-]+$')][string]$ExpectedSid
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Set trusted native/module search paths before the first autoloading cmdlet.
$system = [Environment]::SystemDirectory
$env:Path = "$system;$system\WindowsPowerShell\v1.0;$system\OpenSSH"
$env:PSModulePath = "$system\WindowsPowerShell\v1.0\Modules"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.Owner.Value -ne 'S-1-5-32-544') { throw 'The elevated token must create administrator-owned objects. Installation was not started.' }
$sid = $identity.User.Value
if ($sid -cne $ExpectedSid) { throw 'Approve installation with the same Windows account.' }
# This is the explicit installation boundary. Subsequent wvm operations execute
# only this installed snapshot, never scripts or Git hooks from the checkout.
. (Join-Path $PSScriptRoot 'commands\VM-State.ps1')
function Protect-BackendDirectory([string]$Path, [switch]$Shared) {
    if (Test-Path -LiteralPath $Path) {
        $acl = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) { throw "Untrusted existing installation directory was preserved: $Path" }
        foreach ($entry in $acl.Access) {
            $principal = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($entry.AccessControlType -eq 'Allow' -and ($entry.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -and $principal -notin @('S-1-5-18', 'S-1-5-32-544')) { throw "Writable installation directory was preserved: $Path" }
        }
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked installation directories are not supported.' }
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $ownerSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($ownerSid)
    foreach ($principal in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($principal)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $reader = if ($Shared) { 'S-1-5-32-545' } else { $sid }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($reader)), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    if (Test-Path -LiteralPath $Path) { Set-Acl -LiteralPath $Path -AclObject $acl }
    else { [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null }
}
$stageRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Workstation\Package-Staging'
$stage = Assert-VMPath (Join-Path $stageRoot $StageId) $stageRoot
Assert-VMTree $stage $stageRoot
$programs = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Workstation'
$data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Workstation'
Protect-BackendDirectory $programs -Shared
Protect-BackendDirectory $data -Shared
$userPrograms = Join-Path $programs $sid
$userData = Join-Path $data $sid
Protect-BackendDirectory $userPrograms
Protect-BackendDirectory $userData
& "$env:SystemRoot\System32\icacls.exe" $data /grant '*S-1-5-83-0:RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not allow Hyper-V state traversal.' }
& "$env:SystemRoot\System32\icacls.exe" $userData /grant '*S-1-5-83-0:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not allow Hyper-V disk traversal.' }
$packages = Join-Path $userPrograms 'Packages'
Protect-BackendDirectory $packages
$destination = Join-Path $packages $StageId
if (Test-Path -LiteralPath $destination) { throw 'Package identity already exists; rerun the installer to create a fresh package.' }
Protect-BackendDirectory $destination
Copy-Item -LiteralPath (Join-Path $stage 'hyperv'), (Join-Path $stage 'payload'), (Join-Path $stage 'settings.json'), (Join-Path $stage 'setup.json') -Destination $destination -Recurse
$answers = Read-VMJson (Join-Path $destination 'setup.json')
$sshDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
$null = Assert-VMPath $answers.PublicKeyPath $sshDirectory
if ([IO.Path]::GetExtension($answers.PublicKeyPath) -ne '.pub' -or $answers.PublicKeyPath -match '["\r\n]') { throw 'Use a local SSH public key under your user .ssh directory.' }
$tools = Join-Path $destination 'tools'
Protect-BackendDirectory $tools
$archive = Join-Path $tools 'packer.zip'
Copy-Item -LiteralPath (Join-Path $stage 'packer.zip') -Destination $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine '1b3984ae7f5954cc3ae416b527ae5c5a747ea7bb7977366038609199be4a2710') { throw 'Packer archive checksum mismatch; no package was published.' }
Expand-Archive -LiteralPath $archive -DestinationPath $tools
Remove-Item -LiteralPath $archive
# Ownership, as well as DACLs, must prevent the unelevated caller changing permissions.
& "$env:SystemRoot\System32\icacls.exe" $destination /setowner '*S-1-5-32-544' /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect installed package ownership.' }
foreach ($name in @('Instances', 'Images', 'Results', 'Locks')) {
    $directory = Join-Path $userData $name
    Protect-BackendDirectory $directory
    if ($name -in @('Instances', 'Images')) {
        & "$env:SystemRoot\System32\icacls.exe" $directory /grant '*S-1-5-83-0:(OI)(CI)RX' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not allow Hyper-V disk access.' }
    }
}
$launcher = Join-Path $userPrograms 'Invoke-VM.ps1'
$temporary = Join-Path $userPrograms ($StageId + '.launcher.tmp')
Copy-Item -LiteralPath (Join-Path $destination 'hyperv\commands\Invoke-InstalledVM.ps1') -Destination $temporary
if (Test-Path -LiteralPath $launcher) { [IO.File]::Replace($temporary, $launcher, $null) }
else { [IO.File]::Move($temporary, $launcher) }
& "$env:SystemRoot\System32\icacls.exe" $launcher /setowner '*S-1-5-32-544' /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect launcher ownership.' }
# Publish last. Failed installation leaves the prior installed package selected.
Write-VMJson (Join-Path $userPrograms 'current.json') @{ Directory = $destination; Id = $StageId }
Write-Host 'Protected VM backend installed. Previous packages and VM disks were retained.'
