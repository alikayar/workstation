# A separate VS Code data/extension directory reduces exposure of the personal
# editor profile. It is still a host application, not an OS security sandbox.
function Initialize-VMEditor([string]$CodePath, [string]$InstallationId) {
    if ($InstallationId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid editor instance identity.' }
    $installation = Split-Path (Split-Path $CodePath)
    if ($env:VSCODE_PORTABLE -or (Test-Path -LiteralPath (Join-Path $installation 'data'))) { throw 'Portable VS Code overrides profile isolation. Use the installed VS Code for temporary assignment VMs.' }
    $store = Get-VMStore
    $profile = Assert-VMPath (Join-Path $store.Editor $InstallationId) $store.Editor
    $data = Join-Path $profile 'data'
    $extensions = Join-Path $store.Editor 'extensions'
    $user = Join-Path $data 'User'
    New-Item -ItemType Directory -Path $user, $extensions -Force | Out-Null
    $sshConfig = Join-Path $profile 'ssh_config'
    $include = (Join-Path $store.Connections '*\ssh.conf').Replace('\', '/')
    [IO.File]::WriteAllText($sshConfig, "Include `"$include`"`nHost *`n    ForwardAgent no`n    ForwardX11 no`n    PermitLocalCommand no`n    IdentityAgent none`n    ProxyCommand none`n    ProxyJump none`n", (New-Object Text.UTF8Encoding($false)))
    $path = Join-Path $user 'settings.json' 
    $settings = if (Test-Path -LiteralPath $path) { Read-VMJson $path } else { [pscustomobject]@{} }
    $policy = @{
        'security.workspace.trust.enabled' = $true
        'security.workspace.trust.startupPrompt' = 'always'
        'security.workspace.trust.untrustedFiles' = 'newWindow'
        'remote.autoForwardPorts' = $false
        'remote.restoreForwardedPorts' = $false
        'remote.localPortHost' = 'localhost'
        'remote.SSH.enableAgentForwarding' = $false
        'remote.SSH.path' = (Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe')
        'remote.SSH.configFile' = $sshConfig
        'remote.SSH.defaultExtensions' = @()
        'extensions.ignoreRecommendations' = $true
        'task.allowAutomaticTasks' = 'off'
        'telemetry.telemetryLevel' = 'off'
    }
    foreach ($key in $policy.Keys) { $settings | Add-Member -NotePropertyName $key -NotePropertyValue $policy[$key] -Force }
    Write-VMJson $path $settings
    $arguments = @('--user-data-dir', $data, '--extensions-dir', $extensions, '--sync', 'off')
    $installed = @(& $CodePath @arguments --list-extensions)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the isolated editor profile.' }
    # Never silently load local extensions added to this managed profile.
    $allowed = @('ms-vscode-remote.remote-ssh', 'ms-vscode-remote.remote-ssh-edit', 'ms-vscode.remote-explorer')
    $unexpected = @($installed | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count) { throw ('Extra host extensions in the managed editor profile. Review/remove them before opening an untrusted VM: ' + ($unexpected -join ', ')) }
    if ($installed -notcontains 'ms-vscode-remote.remote-ssh') {
        & $CodePath @arguments --install-extension ms-vscode-remote.remote-ssh | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not install Remote - SSH in the isolated editor profile.' }
    }
    return $arguments
}


# Use the GUI executable for window launch. CLI operations (extension management)
# stay synchronous, but the editor window must not hold the calling terminal.
function Start-VMEditor([string]$CodePath, [string[]]$ProfileArguments, [string]$Alias) {
    if ($Alias -cnotmatch '^ws-[a-z][a-z0-9-]{0,30}[a-z0-9]$') { throw 'Invalid managed editor alias.' }
    $executable = Join-Path (Split-Path (Split-Path $CodePath)) 'Code.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'VS Code GUI executable is missing. Rerun host application setup.' }
    $arguments = @($ProfileArguments) + @('--new-window', '--remote', ('ssh-remote+' + $Alias), '/home/dev/projects')
    $quoted = @($arguments | ForEach-Object {
        if ($_ -match '["\r\n]') { throw 'Unexpected editor argument.' }
        '"' + [regex]::Replace($_, '(\\+)$', '$1$1') + '"'
    })
    $process = Start-Process -FilePath $executable -ArgumentList ($quoted -join ' ') -WindowStyle Normal -PassThru
    try { return $process.Id } finally { $process.Dispose() }
}
