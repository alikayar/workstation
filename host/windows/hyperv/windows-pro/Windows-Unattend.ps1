function Read-WindowsVMCredential([string]$UserName) {
    while ($true) {
        $password = Read-Host "Password for $UserName" -AsSecureString
        $confirmation = Read-Host 'Confirm password' -AsSecureString
        try {
            $credential = New-Object Management.Automation.PSCredential($UserName, $password)
            $other = New-Object Management.Automation.PSCredential($UserName, $confirmation)
            if ($password.Length -eq 0 -or $password.Length -gt 127) { Write-Host 'Use a nonempty password of at most 127 characters.'; $password.Dispose(); continue }
            if ($credential.GetNetworkCredential().Password -cne $other.GetNetworkCredential().Password) { Write-Host 'Passwords differ. Try again.'; $password.Dispose(); continue }
            return $credential
        } finally { $confirmation.Dispose() }
    }
}

function New-WindowsAnswerXml([Management.Automation.PSCredential]$Credential, [string]$Token, [int]$DiskGB) {
    if ($Token -notmatch '^[a-f0-9]{32}$' -or $DiskGB -lt 64 -or $DiskGB -gt 2048) { throw 'Invalid Windows setup inputs.' }
    $xml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Autounattend.xml'))
    $xml = $xml.Replace('__WINDOWS_SIZE_MB__', [string]($DiskGB * 1024 - 260 - 16 - 1024 - 2)).Replace('__COMPUTER_SUFFIX__', $Token.Substring(0, 12)).Replace('__TOKEN__', $Token)
    $xml = $xml.Replace('__USERNAME__', [Security.SecurityElement]::Escape($Credential.UserName))
    # Insert the password last so its contents are never interpreted as template tokens.
    return $xml.Replace('__PASSWORD__', [Security.SecurityElement]::Escape($Credential.GetNetworkCredential().Password))
}

function Wait-WindowsSetup([guid]$VMId, [string]$Token, [string]$DiskPath, [Management.Automation.PSCredential]$Credential) {
    Write-Host 'Waiting for Windows Setup (up to 45 minutes). Ctrl+C retains the VM for resume.'
    $deadline = (Get-Date).AddMinutes(45)
    $nextUpdate = Get-Date
    do {
        $vm = Get-VM -Id $VMId
        if ($vm.Notes -cne ('Workstation Windows VM ' + $Token)) { throw 'VM identity changed while waiting; setup media retained.' }
        $disks = @(Get-VMHardDiskDrive -VM $vm)
        if ($disks.Count -ne 1 -or $disks[0].Path -ine $DiskPath) { throw 'VM disk changed while waiting; setup media retained.' }
        $job = $null
        $verified = $false
        $identityMismatch = $false
        try {
            $job = Invoke-Command -VMId $VMId -Credential $Credential -AsJob -ArgumentList $Token -ScriptBlock {
                param($ExpectedToken)
                $ErrorActionPreference = 'Stop'
                $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
                if ([int]$setup.SystemSetupInProgress -ne 0 -or [int]$setup.OOBEInProgress -ne 0) { return $false }
                if ((Get-ItemProperty 'HKLM:\SOFTWARE\Workstation\WindowsSetup').Token -cne $ExpectedToken) { return 'IdentityMismatch' }
                if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_COMPLETE') { return $false }
                Set-WinHomeLocation -GeoId 235 | Out-Null
                foreach ($file in @('C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml', 'C:\autounattend.xml')) {
                    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
                }
                return $true
            }
            $finished = Wait-Job -Job $job -Timeout 15
            if ($finished -and $job.State -eq 'Completed') {
                $result = @(Receive-Job -Job $job -ErrorAction Stop)
                $verified = $result.Count -eq 1 -and $result[0] -is [bool] -and $result[0]
                $identityMismatch = $result.Count -eq 1 -and $result[0] -is [string] -and $result[0] -ceq 'IdentityMismatch'
            }
        } catch { Write-Verbose 'Guest setup is not ready for authenticated verification.' }
        finally {
            if ($job) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
        if ($identityMismatch) { throw 'Guest setup identity differs; no host setup media was removed.' }
        if ($verified) { return }
        if ((Get-Date) -ge $nextUpdate) { Write-Host 'Windows Setup is still pending.'; $nextUpdate = (Get-Date).AddMinutes(1) }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw 'Windows setup verification timed out. The owned VM and protected setup media were retained; rerun with the same name and password to resume.'
}
