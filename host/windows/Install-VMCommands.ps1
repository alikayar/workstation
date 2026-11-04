#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CodePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Install VM commands on Windows.' }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# Prepare the Git bundle as the desktop user. No elevated Git commands, hooks,
# checkout scripts or user PATH tools are involved in later wvm operations.
$changes = & git.exe -C $repo status --porcelain
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Commit or stash the checkout before installing VM commands; the reusable image uses a committed snapshot.' }
$revision = & git.exe -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not determine the repository revision.' }
$branch = & git.exe -C $repo symbolic-ref --short HEAD
if ($LASTEXITCODE -ne 0) { throw 'Check out a branch before installing VM commands.' }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$installedRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ("Workstation\" + $sid)
$pointer = Join-Path $installedRoot 'current.json'
$reuse = $false
if (Test-Path -LiteralPath $pointer) {
    $selected = (Get-Content -LiteralPath $pointer -Raw | ConvertFrom-Json).Directory
    $metadata = Get-Content -LiteralPath (Join-Path $selected 'payload\repository.json') -Raw | ConvertFrom-Json
    $installedSettings = Get-Content -LiteralPath (Join-Path $selected 'settings.json') -Raw | ConvertFrom-Json
    $installedAnswers = Get-Content -LiteralPath (Join-Path $selected 'setup.json') -Raw
    $answers = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'Workstation\setup.json') -Raw
    $reuse = $metadata.Revision -ceq $revision -and $metadata.Branch -ceq $branch -and $installedSettings.VSCodePath -ieq (Resolve-Path -LiteralPath $CodePath).ProviderPath -and $installedAnswers -ceq $answers
}
if (-not $reuse) {
    $stageId = [Guid]::NewGuid().ToString('N')
    $destination = Join-Path $env:LOCALAPPDATA ("Workstation\Package-Staging\" + $stageId)
    $commandDirectory = Join-Path $destination 'hyperv\commands'
    $payload = Join-Path $destination 'payload'
    New-Item -ItemType Directory -Path $commandDirectory, (Join-Path $destination 'hyperv\guest'), $payload -Force | Out-Null
    foreach ($name in @('Invoke-VM.ps1', 'VM-Worker.ps1', 'VM-State.ps1', 'VM-Image.ps1', 'Seed-ISO.ps1', 'VM-Policy.ps1', 'VM-Editor.ps1', 'Invoke-InstalledVM.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "hyperv\commands\$name") -Destination (Join-Path $commandDirectory $name)
    }
    foreach ($name in @('VM-Resources.ps1', 'New-WorkstationVM.ps1', 'ubuntu.pkr.hcl')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "hyperv\$name") -Destination (Join-Path $destination "hyperv\$name")
    }
    foreach ($name in @('Set-GuestAccount.ps1', 'seal-image.sh', 'provision-workstation.sh', 'finalize-account.sh')) {
        $content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "hyperv\guest\$name")).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $destination "hyperv\guest\$name"), $content, (New-Object Text.UTF8Encoding($false)))
    }
    & git.exe -C $repo bundle create (Join-Path $payload 'workstation.bundle') HEAD $branch
    if ($LASTEXITCODE -ne 0) { throw 'Could not freeze the repository bundle.' }
    foreach ($name in @('provision-workstation.sh', 'finalize-account.sh')) {
        Copy-Item -LiteralPath (Join-Path $destination "hyperv\guest\$name") -Destination (Join-Path $payload $name)
    }
    Copy-Item -LiteralPath (Join-Path $destination 'hyperv\ubuntu.pkr.hcl') -Destination (Join-Path $payload 'ubuntu.pkr.hcl')
    . (Join-Path $commandDirectory 'VM-State.ps1')
    Write-VMJson (Join-Path $payload 'repository.json') @{ Revision = $revision; Branch = $branch }
    Copy-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Workstation\setup.json') -Destination (Join-Path $destination 'setup.json')
    Write-VMJson (Join-Path $destination 'settings.json') @{ VSCodePath = (Resolve-Path -LiteralPath $CodePath).ProviderPath }
    # Download without elevation; the elevated installer checks the pinned upstream
    # archive digest after copying it into the protected package.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_windows_amd64.zip' -OutFile (Join-Path $destination 'packer.zip')
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = '-NoLogo -NoProfile -File "' + (Join-Path $PSScriptRoot 'hyperv\Install-VMBackend.ps1') + '" -StageId ' + $stageId + ' -ExpectedSid ' + $sid
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
    $null = $process.Handle
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'Protected VM backend installation failed. Prior VM data and installed package were retained.' }
}
. (Join-Path $PSScriptRoot 'hyperv\commands\VM-State.ps1')
$installedRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ("Workstation\" + $sid)
$destination = (Read-VMJson (Join-Path $installedRoot 'current.json')).Directory
$commandDirectory = Join-Path $destination 'hyperv\commands'
# This unelevated shim is only a launcher. Every privileged operation uses the
# immutable package selected in the admin-owned Program Files registry.
$shim = Join-Path $env:LOCALAPPDATA 'Workstation\Commands\hyperv\commands'
New-Item -ItemType Directory -Path $shim -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hyperv\commands\Shell-Commands.ps1') -Destination (Join-Path $shim 'Shell-Commands.ps1') -Force
$programs = [Environment]::GetFolderPath('Programs')
$shortcuts = Join-Path $programs 'Workstation'
New-Item -ItemType Directory -Path $shortcuts -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
try {
    foreach ($item in @(@{ Name = 'New temporary VM'; Action = 'new' }, @{ Name = 'Open temporary VM'; Action = 'open' }, @{ Name = 'Stop temporary VM'; Action = 'stop' })) {
        $path = Join-Path $shortcuts ($item.Name + '.lnk')
        $link = $shell.CreateShortcut($path)
        $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = '-NoLogo -NoProfile -File "' + (Join-Path $installedRoot 'Invoke-VM.ps1') + '" -Action ' + $item.Action + ' -FromShortcut'
        if ((Test-Path -LiteralPath $path) -and ($link.TargetPath -ine $target -or $link.Arguments -cne $arguments)) { throw "Unmanaged shortcut preserved: $path" }
        $link.TargetPath = $target; $link.Arguments = $arguments; $link.WorkingDirectory = $env:USERPROFILE; $link.Description = $item.Name
        $link.Save()
    }
    $path = Join-Path $shortcuts 'VM folders.lnk'
    $link = $shell.CreateShortcut($path)
    $target = "$env:SystemRoot\explorer.exe"
    $instances = Join-Path $env:LOCALAPPDATA 'Workstation\Connections'
    New-Item -ItemType Directory -Path $instances -Force | Out-Null
    $arguments = '"' + $instances + '"'
    if ((Test-Path -LiteralPath $path) -and ($link.TargetPath -ine $target -or $link.Arguments -cne $arguments)) { throw "Unmanaged shortcut preserved: $path" }
    $link.TargetPath = $target; $link.Arguments = $arguments; $link.Description = 'Temporary VMs and their Open, Stop and Destroy shortcuts'; $link.Save()
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
Write-Host 'VM commands and Start menu shortcuts installed. Reopen a Workstation terminal to use wvm.'
