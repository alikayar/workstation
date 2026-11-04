#Requires -Version 5.1
# Local regressions with mocked Hyper-V discovery: no VM mutations or external dependencies.
param([string]$TemporaryRoot = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repo 'host\windows\hyperv\commands\VM-State.ps1')
$fixture = Join-Path $TemporaryRoot ('workstation-state-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture, (Join-Path $fixture 'Instances'), (Join-Path $fixture 'Locks') -Force | Out-Null
function Get-VMStore { return @{ Root = $fixture; Instances = (Join-Path $fixture 'Instances') } }
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
    Write-Host "PASS $Message"
}
try {
    $path = Join-Path $fixture 'record.json'
    Write-VMJson $path @{ Value = 'before' }
    Write-VMJson $path @{ Value = 'after' }
    Assert ((Read-VMJson $path).Value -ceq 'after') 'Atomic replacement works on an existing JSON record'
    $failed = $false
    try { $null = Assert-VMPath (Join-Path $fixture '..\outside\disk.vhdx') $fixture } catch { $failed = $true }
    Assert $failed 'Sibling traversal is refused'
    $failed = $false
    try { Assert-VMName 'UPPERCASE' } catch { $failed = $true }
    Assert $failed 'Managed API names require lowercase'
    $name = 'test-vm'
    $directory = Join-Path $fixture ('Instances\' + $name)
    $journal = Join-Path $fixture ('Locks\' + $name + '.delete.json')
    $record = @{ Schema = 1; Kind = 'Temporary'; Name = $name; VMName = ('ws-' + $name); Id = [guid]::NewGuid().ToString('N'); ImageId = [guid]::NewGuid().ToString('N'); VMId = [string][guid]::NewGuid(); Phase = 'Deleting' }
    Write-VMJson $journal $record
    Restore-VMDeletionRecord $name $journal $directory
    $restored = Read-VMJson (Join-Path $directory 'instance.json')
    Assert ($restored.Id -ceq $record.Id -and $restored.VMId -ceq $record.VMId) 'Deletion journal restores a record lost during partial directory removal'
    Restore-VMDeletionRecord $name $journal $directory
    Assert ((Read-VMJson (Join-Path $directory 'instance.json')).Id -ceq $record.Id) 'Repeated journal recovery preserves original VM ownership'
    $restored.Id = [guid]::NewGuid().ToString('N')
    Write-VMJson (Join-Path $directory 'instance.json') $restored
    $before = [IO.File]::ReadAllText((Join-Path $directory 'instance.json'))
    $failed = $false
    try { Restore-VMDeletionRecord $name $journal $directory } catch { $failed = $true }
    Assert ($failed -and [IO.File]::ReadAllText((Join-Path $directory 'instance.json')) -ceq $before) 'A stale deletion journal cannot replace another VM generation'
    $known = Join-Path $fixture 'known_hosts'
    Save-VMHostPin $known '192.0.2.1' 'ssh-ed25519 AAAA'
    Save-VMHostPin $known '192.0.2.1' 'ssh-ed25519 AAAA'
    Assert (@([IO.File]::ReadAllLines($known)).Count -eq 1) 'Repeated host identity pinning does not duplicate entries'
    $before = [IO.File]::ReadAllText($known)
    $failed = $false
    try { Save-VMHostPin $known '192.0.2.1' 'ssh-ed25519 BBBB' } catch { $failed = $true }
    Assert ($failed -and [IO.File]::ReadAllText($known) -ceq $before) 'A changed host key is rejected without replacing the trusted pin'
    Save-VMHostPin $known '192.0.2.2' 'ssh-ed25519 AAAA'
    Assert (@([IO.File]::ReadAllLines($known)).Count -eq 2) 'A DHCP address change keeps the same trusted guest identity'
    $secondKnown = Join-Path $fixture 'second_known_hosts'
    Save-VMHostPin $secondKnown '192.0.2.1' 'ssh-ed25519 BBBB'
    Assert ([IO.File]::ReadAllText($known) -match 'AAAA' -and [IO.File]::ReadAllText($secondKnown) -notmatch 'AAAA') 'Different VM generations can reuse an IP with separate trust stores'
    $engine = (Get-Process -Id $PID).Path
    $native = Invoke-VMNative $engine @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "[Console]::Error.WriteLine('native diagnostic'); exit 7")
    Assert ($native.ExitCode -eq 7 -and ($native.Output -join ' ') -match 'native diagnostic') 'Native stderr preserves the actual exit code and full diagnostic'
    $native = Invoke-VMNative $engine @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "[Console]::Error.WriteLine('harmless diagnostic'); exit 0")
    Assert ($native.ExitCode -eq 0 -and ($native.Output -join ' ') -match 'harmless diagnostic') 'Native stderr alone does not turn success into failure'
    Assert ($ErrorActionPreference -ceq 'Stop') 'Native execution restores the caller error preference'
    # Model stale KVP and a bridge address: an SSH banner is insufficient.
    $script:probeAddresses = @()
    $script:observedVMId = 'owned'
    function Get-VM { param($Name) [pscustomobject]@{Id=$script:observedVMId} }
    function Get-VMNetworkAdapter { param($VMName) [pscustomobject]@{IPAddresses=@('192.0.2.1','192.0.2.2','192.0.2.2','169.254.1.1')} }
    function Test-VMSSHBanner { param($Address) return $true }
    $selected = Wait-VMAddress 'test-vm' { param($Address) $script:probeAddresses += $Address; return ($Address -eq '192.0.2.2') } 'owned'
    Assert ($selected -ceq '192.0.2.2' -and $script:probeAddresses.Count -eq 2) 'Discovery skips stale SSH addresses and returns only a verified identity'
    $script:observedVMId = 'replacement'
    $failed = $false
    try { $null = Wait-VMAddress 'test-vm' { throw 'Must not probe a replacement VM' } 'owned' } catch { $failed = $_.Exception.Message -match 'Hyper-V identity changed' }
    Assert $failed 'VM replacement while waiting refuses before probing another identity'
    $script:assigned = @()
    $script:collision = $false
    $vm = [pscustomobject]@{ Id = 'owned' }
    function Get-VM { [pscustomobject]@{ Id = 'other' } }
    function Get-VMNetworkAdapter {
        param([Parameter(ValueFromPipeline)]$VM, [switch]$ManagementOS)
        process {
            if ($ManagementOS) { return }
            if ($VM.Id -eq 'owned') { [pscustomobject]@{MacAddress='020000000001'} }
            elseif ($script:collision) { [pscustomobject]@{MacAddress='020000000001'} }
            else { [pscustomobject]@{MacAddress='020000000002'} }
        }
    }
    function Set-VMNetworkAdapter { param($VMNetworkAdapter, $StaticMacAddress) $script:assigned += $StaticMacAddress }
    Set-VMNetworkIdentity $vm '020000000001'
    Set-VMNetworkIdentity $vm '020000000001'
    Assert ($script:assigned.Count -eq 2 -and $script:assigned[0] -ceq $script:assigned[1]) 'MAC assignment is stable on repeat'
    $script:collision = $true
    $failed = $false
    try { Set-VMNetworkIdentity $vm '020000000001' } catch { $failed = $true }
    Assert ($failed -and $script:assigned.Count -eq 2) 'Another VM MAC collision refuses before changing an adapter'
    $script:collision = $false
    $allocationLock = [IO.File]::Open((Join-Path $fixture 'Locks\network.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $failed = $false
        try { Set-VMNetworkIdentity $vm '020000000003' } catch { $failed = $true }
        Assert ($failed -and $script:assigned.Count -eq 2) 'Concurrent network allocation refuses without changing an adapter'
    } finally { $allocationLock.Dispose() }
    . (Join-Path $repo 'host\windows\hyperv\commands\VM-Editor.ps1')
    $bin = Join-Path $fixture 'Code installation\bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Split-Path $bin) 'Code.exe'), 'Fixture only; never executed')
    $script:launch = $null
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
        $script:launch = @{Path=$FilePath;Arguments=$ArgumentList;Style=$WindowStyle}
        $process = [pscustomobject]@{Id=123}
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $process
    }
    $guiId = Start-VMEditor (Join-Path $bin 'code.cmd') @('--user-data-dir', 'C:\profile with spaces\data') 'ws-test-vm'
    Assert ($guiId -eq 123 -and $script:launch.Path -like '*Code.exe' -and $script:launch.Style -ceq 'Normal' -and $script:launch.Arguments.Contains('"C:\profile with spaces\data"')) 'Editor launches the GUI asynchronously with quoted profile arguments'
    $failed = $false
    try { $null = Start-VMEditor (Join-Path $bin 'code.cmd') @() 'ws-vm;command' } catch { $failed = $true }
    Assert $failed 'Editor refuses an invalid VM alias before launching'
    Write-Host "$passed local regression checks passed."
} finally {
    # Delete only the generated fixture after checking its absolute boundary/tree.
    Assert-VMTree $fixture $TemporaryRoot
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
