#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Elevated,
    [string]$ExpectedSid
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run setup.ps1 on your Windows 11 Pro host.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$state = Join-Path $env:LOCALAPPDATA 'Workstation'
$inputsPath = Join-Path $state 'setup.json'
$vmState = Join-Path $state 'HyperV\workstation'
$utf8 = New-Object Text.UTF8Encoding($false)

if ($Elevated) {
    try {
        if (-not $isAdministrator -or $identity.User.Value -ne $ExpectedSid) {
            throw 'Approve elevation with the same Windows account that started setup.'
        }
        $inputs = Get-Content -LiteralPath $inputsPath -Raw | ConvertFrom-Json
        $ssh = Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
        $restart = $false
        if ($ssh.State -ne 'Installed') {
            $result = Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
            $restart = $result.RestartNeeded
        }
        $hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
        if ($hyperv.State -eq 'EnablePending') { exit 3010 }
        if ($hyperv.State -ne 'Enabled') {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
            $restart = $true
        }
        if ($restart) { exit 3010 }
        $env:Path += ";$env:SystemRoot\System32\OpenSSH"
        $publicKey = $inputs.PublicKeyPath
        $privateKey = $publicKey.Substring(0, $publicKey.Length - 4)
        if (-not (Test-Path -LiteralPath $publicKey)) {
            if (Test-Path -LiteralPath $privateKey) { throw "Private key already exists without its .pub file: $privateKey. Restore its public key before retrying." }
            New-Item -ItemType Directory -Path (Split-Path $publicKey) -Force | Out-Null
            Write-Host 'Creating your workstation SSH key. Choose a passphrase when prompted.'
            & ssh-keygen.exe -t ed25519 -f $privateKey
            if ($LASTEXITCODE -ne 0) { throw 'SSH key creation did not finish.' }
        }
        $fingerprint = Join-Path $vmState 'ssh-host-key.pub'
        if (Test-Path -LiteralPath $fingerprint) {
            Write-Host 'Expected SSH host fingerprint from the original installation:'
            & ssh-keygen.exe -lf $fingerprint
            if ($LASTEXITCODE -ne 0) { throw 'The saved public host key could not be read.' }
        }
        & "$PSScriptRoot\host\windows\New-WorkstationVM.ps1" -GitName $inputs.GitName -GitEmail $inputs.GitEmail -PublicKeyPath $publicKey
        exit 0
    } catch {
        Write-Host $_ -ForegroundColor Red
        Read-Host 'Press Enter to return to setup' | Out-Null
        exit 1
    }
}
if ($isAdministrator) { throw 'Start .\setup.ps1 in a normal PowerShell window. It requests elevation when needed.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows, reopen PowerShell and run setup again.' }
& "$PSScriptRoot\host\windows\Install-Host.ps1"

if (-not (Test-Path -LiteralPath $inputsPath)) {
    function Read-SetupValue([string]$Label, [string]$Default) {
        $answer = Read-Host "$Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if ([string]::IsNullOrWhiteSpace($answer)) { throw "$Label is required. Run setup again." }
        return $answer.Trim()
    }
    $name = & git.exe -C $PSScriptRoot config user.name
    $email = & git.exe -C $PSScriptRoot config user.email
    $existingInstallation = Join-Path $vmState 'installation.json'
    if (Test-Path -LiteralPath $existingInstallation) {
        $existing = Get-Content -LiteralPath $existingInstallation -Raw | ConvertFrom-Json
        $name = $existing.GitName
        $email = $existing.GitEmail
    }
    $inputs = @{
        GitName = Read-SetupValue 'Git name' $name
        GitEmail = Read-SetupValue 'Git email' $email
        PublicKeyPath = Read-SetupValue 'SSH public key (.pub; created if missing)' "$env:USERPROFILE\.ssh\workstation_ed25519.pub"
    }
    $inputs.PublicKeyPath = [IO.Path]::GetFullPath($inputs.PublicKeyPath)
    if ([IO.Path]::GetExtension($inputs.PublicKeyPath) -ne '.pub') { throw 'Choose a public key path ending in .pub.' }
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    [IO.File]::WriteAllText($inputsPath, ($inputs | ConvertTo-Json), $utf8)
}
Write-Host 'Windows will ask for administrator access to prepare SSH, Hyper-V and Ubuntu. Use this same account.'
$windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = '-NoLogo -NoProfile -File "' + $PSCommandPath + '" -Elevated -ExpectedSid ' + $identity.User.Value
$process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
if ($process.ExitCode -eq 3010) {
    Write-Host 'Restart Windows, return to this checkout, and run .\setup.ps1 again. Your answers are saved.'
    return
}
if ($process.ExitCode -ne 0) { throw 'Setup stopped. Resolve the error shown in the administrator window, then rerun .\setup.ps1.' }
$connection = Get-Content -LiteralPath (Join-Path $vmState 'connection.json') -Raw | ConvertFrom-Json
$inputs = Get-Content -LiteralPath $inputsPath -Raw | ConvertFrom-Json
$privateKey = $inputs.PublicKeyPath.Substring(0, $inputs.PublicKeyPath.Length - 4).Replace('\', '/')
if ($privateKey -match '["\r\n]' -or $connection.Address -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $connection.User -notmatch '^[a-z][a-z0-9_]{0,30}$') {
    throw 'Unexpected connection data. SSH configuration was left unchanged.'
}
$sshDirectory = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
$configPath = Join-Path $sshDirectory 'config'
$config = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
$pattern = '(?ms)^# BEGIN workstation setup\r?\n.*?^# END workstation setup\r?\n?'
$remaining = [regex]::Replace($config, $pattern, '')
if ($remaining -match '(?im)^\s*Host\s+[^\r\n]*\bworkstation\b') {
    throw 'An unmanaged workstation SSH alias already exists. Preserve it and update its address manually; the VM is ready.'
}
$block = @"
# BEGIN workstation setup
Host workstation
    HostName $($connection.Address)
    User $($connection.User)
    IdentityFile "$privateKey"
    IdentitiesOnly yes
    ForwardAgent no
Host *
# END workstation setup
"@
$updated = $block + "`r`n" + $remaining
if ($updated -cne $config) {
    if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination "$configPath.workstation-backup" -Force }
    [IO.File]::WriteAllText("$configPath.tmp", $updated, $utf8)
    Move-Item -LiteralPath "$configPath.tmp" -Destination $configPath -Force
}
Write-Host 'Ready. Reopen Windows Terminal and select Workstation.'
Write-Host 'Connect: ssh workstation'
Write-Host 'Editor:  code --remote ssh-remote+workstation /home/dev/projects/workstation'
$fingerprint = Join-Path $vmState 'ssh-host-key.pub'
if (Test-Path -LiteralPath $fingerprint) {
    Write-Host 'Compare this fingerprint with the first SSH connection before accepting:'
    & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -lf $fingerprint
} else {
    Write-Host 'Compare the first SSH host fingerprint with your original installer output before accepting.'
}
