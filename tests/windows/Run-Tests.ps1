#Requires -Version 5.1
[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this suite on Windows; no Hyper-V or installed Codex is required.' }
$script:Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $Output) { $Output = Join-Path ([IO.Path]::GetTempPath()) ('ws-windows-' + [guid]::NewGuid().ToString('N')) }
$script:RunRoot = [IO.Path]::GetFullPath($Output)
if ($RunRoot.StartsWith($Repository.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $RunRoot -ieq $Repository) { throw 'Keep test artifacts outside the checkout.' }
$cursor = $RunRoot
while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked artifact paths are refused.' }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
}
if ((Test-Path -LiteralPath $RunRoot) -and @(Get-ChildItem -LiteralPath $RunRoot -Force).Count) { throw 'Output must be new or empty.' }
$null = [IO.Directory]::CreateDirectory($RunRoot)
$script:Results = New-Object 'Collections.Generic.List[object]'
$script:Sources = [ordered]@{}
foreach ($relative in @('tests/windows/Run-Tests.ps1','tests/windows/Host.Contracts.ps1','tests/windows/VM.Contracts.ps1','tests/fixtures/windows/CodexConfigServer.cs')) {
    $Sources[$relative] = (Get-FileHash -LiteralPath (Join-Path $Repository $relative) -Algorithm SHA256).Hash
}
$Sources['host/windows/wvm/wvm.ps1'] = (Get-FileHash -LiteralPath (Join-Path $Repository 'host/windows/wvm/wvm.ps1')).Hash
$script:Cases = New-Object 'Collections.Generic.List[object]'
function Assert-True([bool]$Condition, [string]$Message = 'Expected true') { if (-not $Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string]$Message = 'Values differ') {
    $a = ConvertTo-Json -InputObject $Actual -Depth 40 -Compress
    $b = ConvertTo-Json -InputObject $Expected -Depth 40 -Compress
    if ($a -cne $b) { throw ($Message + ': expected ' + $b + '; actual ' + $a) }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught) { throw 'Expected a failure; operation succeeded.' }
    if ($Pattern -and $caught -notmatch $Pattern) { throw ('Unexpected failure: ' + $caught) }
    return $caught
}
function Write-Fixture([string]$Path, [string]$Content) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}
function Export-TestFunctions([string]$RelativePath, [string]$Directory) {
    # Parse actual sources and copy only top-level function definitions. Never dot-source
    # installer entrypoints, #Requires workers or their module-import/bootstrap code.
    $path = Join-Path $Repository $RelativePath
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Cannot load functions from $RelativePath" }
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    if (-not $definitions.Count) { throw "No top-level functions in $RelativePath" }
    $Sources[$RelativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $target = Join-Path (Join-Path $RunRoot $Directory) 'Functions.ps1'
    Write-Fixture $target (($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n")
    return $target
}
function Add-Case([string]$Name, [scriptblock]$Body) { $Cases.Add(@{ Name=$Name; Body=$Body }) }

# Fail closed at external command boundaries. Individual cases can replace these
# functions with deterministic inventories, never live Hyper-V/network operations.
foreach ($name in @('Get-VM','Get-VHD','Get-VMSnapshot','Get-VMHardDiskDrive','Get-VMDvdDrive','Get-VMNetworkAdapter',
                    'Get-VMSecurity','Get-VMFirmware','Get-VMProcessor','Set-VM','Start-VM','Stop-VM','Remove-VM',
                    'Mount-VHD','Dismount-VHD','Get-VMSwitch','Get-NetAdapter','Get-NetIPAddress','Get-NetRoute',
                    'Add-VMNetworkAdapterExtendedAcl','Remove-VMNetworkAdapterExtendedAcl','Invoke-WebRequest')) {
    Set-Item -Path ('Function:script:' + $name) -Value { throw 'Unexpected external operation in a Windows contract test.' }
}
. (Export-TestFunctions 'host/windows/hyperv/shared/Packer.ps1' 'packer')
. (Export-TestFunctions 'host/windows/hyperv/shared/VM.ps1' 'vm')
. (Export-TestFunctions 'host/windows/hyperv/shared/BaseImage.ps1' 'base-image')
. (Export-TestFunctions 'host/windows/hyperv/shared/WVM-Lifecycle.ps1' 'lifecycle')
. (Export-TestFunctions 'host/windows/hyperv/shared/VM-Resources.ps1' 'resources')
. (Export-TestFunctions 'host/windows/hyperv/shared/Remove-OwnedVM.ps1' 'deletion')
. (Export-TestFunctions 'host/windows/hyperv/ubuntu-26-04/Ubuntu-Network.ps1' 'network')
. (Export-TestFunctions 'host/windows/hyperv/ubuntu-26-04/Configure-Workstation.ps1' 'selection')
. (Export-TestFunctions 'host/windows/terminal/Install-Terminal.ps1' 'terminal')
. (Export-TestFunctions 'host/windows/wvm/Doctor.ps1' 'doctor')
. (Export-TestFunctions 'host/windows/vscode/Install-VSCode.ps1' 'vscode')
. (Export-TestFunctions 'host/windows/codex/Setup-Codex.ps1' 'codex')
. (Export-TestFunctions 'host/windows/hyperv/windows-pro/Windows-Unattend.ps1' 'unattend')
Write-Fixture (Join-Path $RunRoot 'codex\Instructions.md') 'Synthetic Workstation instructions.'
Copy-Item -LiteralPath (Join-Path $Repository 'host/windows/hyperv/windows-pro/Autounattend.xml') -Destination (Join-Path $RunRoot 'unattend\Autounattend.xml')

$script:ConfigPeer = Join-Path $RunRoot 'CodexConfigServer.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is required for the isolated RPC fixture.' }
& $compiler /nologo /target:exe /reference:System.Web.Extensions.dll ('/out:' + $ConfigPeer) (Join-Path $Repository 'tests/fixtures/windows/CodexConfigServer.cs')
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the synthetic Codex config peer.' }

. (Join-Path $PSScriptRoot 'Host.Contracts.ps1')
. (Join-Path $PSScriptRoot 'VM.Contracts.ps1')
foreach ($case in $Cases) {
    $directory = Join-Path $RunRoot ('case-' + ($Results.Count + 1))
    $null = [IO.Directory]::CreateDirectory($directory)
    Set-Answers @()
    $started = [DateTime]::UtcNow
    $record = [ordered]@{ name=$case.Name; status='failed'; directory=$directory }
    try {
        & $case.Body $directory *> (Join-Path $directory 'case.log')
        $record.status = 'passed'
        Write-Host ('PASS ' + $case.Name)
    } catch {
        $record.error = $_.Exception.Message
        Write-Host ('FAIL ' + $case.Name + ': ' + $_.Exception.Message)
    }
    $record.seconds = ([DateTime]::UtcNow - $started).TotalSeconds
    $Results.Add([pscustomobject]$record)
}
$failed = @($Results | Where-Object status -ne 'passed').Count
$report = [ordered]@{ shell=$PSVersionTable.PSVersion.ToString(); edition=$PSVersionTable.PSEdition; os=[Environment]::OSVersion.VersionString; compiler=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion; tests=$Results.Count; failures=$failed; skipped=0; sources=$Sources; cases=@($Results.ToArray());
    boundary='Real functions and temporary files; synthetic Codex JSON-RPC peer and Hyper-V inventories. No live VM, installer, personal settings or network policy is changed.' }
Write-Fixture (Join-Path $RunRoot 'result.json') ($report | ConvertTo-Json -Depth 12)
Write-Host ('Artifacts retained: ' + $RunRoot)
if ($failed) { exit 1 }
