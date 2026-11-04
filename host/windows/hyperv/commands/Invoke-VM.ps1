#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][ValidateSet('new', 'open', 'stop', 'destroy', 'list', 'template')][string]$Action = 'open',
    [Parameter(Position = 1)][string]$Name,
    [ValidateRange(0, 64)][int]$CPUs = 0,
    [ValidateRange(0, 131072)][int]$MemoryMB = 0,
    [switch]$Refresh,
    [switch]$FromShortcut
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'VM-State.ps1')
function Set-VMConnection([object]$Connection) {
    $store = Get-VMStore
    $ssh = Join-Path $env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Path $ssh -Force | Out-Null
    $path = Join-Path $ssh 'config'
    $config = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
    $pattern = '(?ms)^# BEGIN workstation VM commands\r?\n.*?^# END workstation VM commands\r?\n?'
    $remaining = [regex]::Replace($config, $pattern, '')
    if ($remaining -match ('(?im)^\s*Host\s+[^\r\n]*\b' + [regex]::Escape($Connection.Alias) + '\b')) { throw 'An unmanaged SSH alias uses this VM name. Its configuration was preserved.' }
    $include = (Join-Path $store.Connections '*\ssh.conf').Replace('\', '/')
    $block = "# BEGIN workstation VM commands`r`nInclude `"$include`"`r`nHost *`r`n# END workstation VM commands`r`n"
    $updated = $block + $remaining
    $identity = $Connection.IdentityFile.Replace('\', '/')
    $known = $Connection.KnownHostsFile.Replace('\', '/')
    if ($identity -match '["\r\n]' -or $known -match '["\r\n]') { throw 'Unexpected SSH path.' }
    $fragment = "Host $($Connection.Alias)`n    HostName $($Connection.Address)`n    User dev`n    IdentityFile `"$identity`"`n    UserKnownHostsFile `"$known`"`n    IdentitiesOnly yes`n    StrictHostKeyChecking yes`n    ForwardAgent no`n    ForwardX11 no`n    PermitLocalCommand no`n    ExitOnForwardFailure yes`n"
    Save-VMHostPin $Connection.KnownHostsFile $Connection.Address $Connection.HostPublicKey
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Connection.Directory 'ssh.conf'), $fragment, $encoding)
    if ($updated -cne $config) {
        if ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllText($path) -cne $config) { throw 'SSH config changed during this operation. Retry; the user edit was preserved.' }
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination "$path.workstation-vm-backup" -Force }
        $temporary = "$path.workstation-vm.tmp"
        [IO.File]::WriteAllText($temporary, $updated, $encoding)
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    }
}
function Set-VMShortcuts([object]$Connection) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($item in @(@{ File = 'Open'; Action = 'open' }, @{ File = 'Stop'; Action = 'stop' }, @{ File = 'Destroy'; Action = 'destroy' })) {
            $path = Join-Path $Connection.Directory ($item.File + '.lnk')
            $link = $shell.CreateShortcut($path)
            $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $arguments = '-NoLogo -NoProfile -File "' + (Join-Path (Get-VMStore).ProgramRoot 'Invoke-VM.ps1') + '" -Action ' + $item.Action + ' -Name ' + $Connection.Name + ' -FromShortcut'
            if ((Test-Path -LiteralPath $path) -and ($link.TargetPath -ine $target -or $link.Arguments -cne $arguments)) { throw "Unmanaged shortcut preserved: $path" }
            $link.TargetPath = $target; $link.Arguments = $arguments; $link.WorkingDirectory = $env:USERPROFILE
            $link.Description = "$($item.File) temporary VM $($Connection.Name)"
            $link.Save()
        }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Use wvm on the Windows host.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Start wvm from a normal desktop terminal. Only the Hyper-V worker is elevated; the editor must stay unelevated.' }
    if ($CPUs -eq 1 -or ($MemoryMB -ne 0 -and $MemoryMB -lt 4096)) { throw 'Use at least 2 CPUs and 4096 MiB RAM, or omit these options to reuse setup defaults.' }
    if ($Refresh -and $Action -ne 'template') { throw '-Refresh is only valid with wvm template.' }
    if ($Action -eq 'destroy' -and [string]::IsNullOrWhiteSpace($Name)) { throw 'Specify the exact temporary VM name: wvm destroy takehome.' }
    $store = Get-VMStore
    if ($Action -in @('new', 'open', 'stop')) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $names = @()
            if (Test-Path -LiteralPath $store.Instances) {
                $names = @(Get-ChildItem -LiteralPath $store.Instances -Directory | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'instance.json')) } | Select-Object -ExpandProperty Name | Sort-Object)
            }
            if ($Action -ne 'new' -and -not $names.Count) { throw 'No managed temporary VMs. Create one with wvm new.' }
            if ($names.Count) { Write-Host ('Temporary VMs: ' + ($names -join ', ')) }
            $default = if ($Action -eq 'new') { 'takehome' } else { $names[0] }
            $Name = Read-Host "VM name [$default]"
            if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $default }
        }
    }
    if ($Action -notin @('list', 'template')) { $Name = $Name.Trim().ToLowerInvariant(); Assert-VMName $Name }
    $operationTarget = if ($Action -eq 'template') { 'Ubuntu template image' } else { $Name }
    if ($Action -ne 'list' -and -not $PSCmdlet.ShouldProcess($operationTarget, "VM action: $Action")) { return }
    $id = [Guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $store.Requests ($id + '.result.json')
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $worker = Join-Path $PSScriptRoot 'VM-Worker.ps1'
    Write-Host "VM action: $Action. Log: $(Join-Path $store.Requests ($id + '.log'))"
    $arguments = '-NoLogo -NoProfile -File "' + $worker + '" -RequestId ' + $id + ' -ExpectedSid ' + $identity.User.Value + ' -Action ' + $Action + ' -CPUs ' + $CPUs + ' -MemoryMB ' + $MemoryMB
    if ($Name) { $arguments += ' -Name ' + $Name }
    if ($Refresh) { $arguments += ' -Refresh' }
    $needsImage = -not (Test-Path -LiteralPath (Join-Path $store.Images 'current.json')) -or (Test-Path -LiteralPath (Join-Path $store.Images 'build.json'))
    $style = if ($Action -eq 'template' -or ($Action -eq 'new' -and $needsImage)) { 'Normal' } else { 'Hidden' }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle $style -PassThru
    $null = $process.Handle
    $process.WaitForExit()
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'VM worker did not return a result. Inspect its log; existing disks were preserved.' }
    $result = Read-VMJson $resultPath
    if (-not $result.OK) { throw $result.Error }
    if ($Action -eq 'list') { $result.Data | Format-Table Name, State, CPUs, MemoryMB, DiskGB; return }
    if ($Action -eq 'template') { Write-Host "Ubuntu image ready: $($result.Data.ImageId)"; return }
    if ($Action -eq 'destroy') {
        $directory = Assert-VMPath (Join-Path $store.Connections $Name) $store.Connections
        $marker = Join-Path $directory 'connection.json'
        if ((Test-Path -LiteralPath $marker) -and (Read-VMJson $marker).InstallationId -ceq $result.Data.InstallationId) {
            Assert-VMTree $directory $store.Connections
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
    if ($Action -in @('stop', 'destroy')) { Write-Host "$Name : $Action completed."; return }
    $connection = $result.Data
    $null = Assert-VMPath $connection.Directory $store.Connections
    $marker = Join-Path $connection.Directory 'connection.json'
    if (Test-Path -LiteralPath $connection.Directory) {
        if (-not (Test-Path -LiteralPath $marker) -or (Read-VMJson $marker).InstallationId -cne $connection.InstallationId) { throw 'Unrecognized connection directory was preserved.' }
    } else { New-Item -ItemType Directory -Path $connection.Directory -Force | Out-Null }
    Write-VMJson $marker @{ InstallationId = $connection.InstallationId; Name = $connection.Name }
    Set-VMConnection $connection
    & (Join-Path $PSScriptRoot '..\guest\Set-GuestAccount.ps1') -Address $connection.Address -UserName dev -IdentityFile $connection.IdentityFile -KnownHostsFile $connection.KnownHostsFile -InstallationId $connection.InstallationId -FinalizerPath $connection.FinalizerPath -WaitForCloudInit
    Set-VMShortcuts $connection
    $settings = Read-VMJson (Join-Path $store.Commands 'settings.json')
    if (-not (Test-Path -LiteralPath $settings.VSCodePath)) { throw "VM is ready. Connect with ssh $($connection.Alias), or rerun host application setup to refresh the VS Code path." }
    . (Join-Path $PSScriptRoot 'VM-Editor.ps1')
    $editor = Initialize-VMEditor $settings.VSCodePath $connection.InstallationId
    $null = Start-VMEditor $settings.VSCodePath $editor $connection.Alias
    Write-Host "Ready: $Name. SSH: ssh $($connection.Alias)"
} catch {
    if ($FromShortcut) { Write-Host $_ -ForegroundColor Red; Read-Host 'Press Enter to close' | Out-Null; exit 1 }
    throw
}
