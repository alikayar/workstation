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
. "$PSScriptRoot\host\windows\hyperv\VM-Resources.ps1"

function Save-SetupInputs([object]$Answers) {
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $temporary = Join-Path $state ('setup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Answers | ConvertTo-Json -Depth 4), $utf8)
        if (Test-Path -LiteralPath $inputsPath) { [IO.File]::Replace($temporary, $inputsPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $inputsPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

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
        if (-not (Test-Path -LiteralPath $privateKey)) {
            if (Test-Path -LiteralPath $publicKey) { throw "Public key already exists without its private key: $publicKey. Restore the matching private key; setup will not replace the identity." }
            New-Item -ItemType Directory -Path (Split-Path $publicKey) -Force | Out-Null
            Write-Host 'Creating the dedicated Workstation SSH key automatically.'
            # ProcessStartInfo preserves the empty -N argument in Windows PowerShell 5.1.
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = (Get-Command ssh-keygen.exe -CommandType Application -ErrorAction Stop).Source
            $start.Arguments = '-q -t ed25519 -N "" -f "' + $privateKey + '"'
            $start.UseShellExecute = $false
            $keyProcess = [Diagnostics.Process]::Start($start)
            $keyProcess.WaitForExit()
            if ($keyProcess.ExitCode -ne 0) { throw 'SSH key creation did not finish.' }
            & icacls.exe $privateKey /inheritance:r /grant:r "*$($identity.User.Value):F" '*S-1-5-18:F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict permissions on the generated SSH private key.' }
        }
        if (-not (Test-Path -LiteralPath $publicKey)) {
            # Recover a missing .pub after an interrupted automatic key creation.
            # Existing encrypted private keys are left intact and never trigger a new identity.
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = (Get-Command ssh-keygen.exe -CommandType Application -ErrorAction Stop).Source
            $start.Arguments = '-y -P "" -f "' + $privateKey + '"'
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $keyProcess = [Diagnostics.Process]::Start($start)
            $derivedPublicKey = $keyProcess.StandardOutput.ReadToEnd()
            $null = $keyProcess.StandardError.ReadToEnd()
            $keyProcess.WaitForExit()
            if ($keyProcess.ExitCode -ne 0) { throw 'Could not recover the missing SSH public key. Restore the original .pub file for this private key; no replacement was generated.' }
            [IO.File]::WriteAllText($publicKey, $derivedPublicKey.Trim() + "`n", $utf8)
        }
        $fingerprint = Join-Path $vmState 'ssh-host-key.pub'
        if (Test-Path -LiteralPath $fingerprint) {
            Write-Host 'Expected SSH host fingerprint from the original installation:'
            & ssh-keygen.exe -lf $fingerprint
            if ($LASTEXITCODE -ne 0) { throw 'The saved public host key could not be read.' }
        }
        & "$PSScriptRoot\host\windows\hyperv\New-WorkstationVM.ps1" -GitName $inputs.GitName -GitEmail $inputs.GitEmail -PublicKeyPath $publicKey -CPUs $inputs.Resources.CPUs -MemoryMB $inputs.Resources.MemoryMB -DiskGB $inputs.Resources.DiskGB
        exit 0
    } catch {
        Write-Host $_ -ForegroundColor Red
        Read-Host 'Press Enter to return to setup' | Out-Null
        exit 1
    }
}
if ($isAdministrator) { throw 'Start .\setup.ps1 in a normal PowerShell window. It requests elevation when needed.' }
# Resolve saved settings before prompting or making host changes.
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows, reopen PowerShell and run setup again.' }
$existingInstallation = Join-Path $vmState 'installation.json'
$existing = if (Test-Path -LiteralPath $existingInstallation) { Get-Content -LiteralPath $existingInstallation -Raw | ConvertFrom-Json } else { $null }
$savedInputs = if (Test-Path -LiteralPath $inputsPath) { Get-Content -LiteralPath $inputsPath -Raw | ConvertFrom-Json } else { $null }
if ($null -ne $savedInputs -and $savedInputs.PSObject.Properties.Name -contains 'Resources') {
    $resources = Get-WorkstationVMResources -SavedResources $savedInputs.Resources
} elseif ($null -ne $existing -and $existing.Schema -eq 2) {
    $resources = Get-WorkstationVMResources -SavedResources $existing.Resources
} else {
    $resources = Get-WorkstationVMResources
    # Legacy VMs keep their configuration; questions are only for new installations.
    if ($null -eq $existing) { $resources = Read-WorkstationVMResources -Defaults $resources }
}
if ($null -ne $savedInputs) {
    if ($savedInputs.PSObject.Properties.Name -notcontains 'Resources') {
        $savedInputs | Add-Member -NotePropertyName Resources -NotePropertyValue $resources
        Save-SetupInputs $savedInputs
    }
} else {
    function Read-SetupValue([string]$Label, [string]$Default) {
        while ($true) {
            $prompt = if ([string]::IsNullOrWhiteSpace($Default)) { "$Label (required)" } else { "$Label [$Default]" }
            $answer = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
            if (-not [string]::IsNullOrWhiteSpace($answer)) { return $answer.Trim() }
            Write-Host "$Label is required." -ForegroundColor Yellow
        }
    }
    $name = & git.exe -C $PSScriptRoot config user.name
    $email = & git.exe -C $PSScriptRoot config user.email
    $publicKeyPath = "$env:USERPROFILE\.ssh\workstation_ed25519.pub"
    if ($null -ne $existing) {
        $name = $existing.GitName
        $email = $existing.GitEmail
        if (-not (Test-Path -LiteralPath $publicKeyPath)) {
            throw 'An existing VM has no saved setup answers or default public key. Restore setup.json and its original SSH key; setup will not generate a replacement identity.'
        }
    }
    $inputs = @{
        GitName = Read-SetupValue 'Git name' $name
        GitEmail = Read-SetupValue 'Git email' $email
        PublicKeyPath = $publicKeyPath
        Resources = $resources
    }
    Save-SetupInputs $inputs
}
& "$PSScriptRoot\host\windows\Install-Host.ps1"

Write-Host 'Windows will ask for administrator access to prepare SSH, Hyper-V and Ubuntu. Use this same account.'
Write-Host "VM resources: $($resources.CPUs) vCPUs, $($resources.MemoryMB) MiB RAM, $($resources.DiskGB) GiB disk. Existing VMs are not resized."
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
