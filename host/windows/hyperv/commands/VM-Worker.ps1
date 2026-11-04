#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RequestId,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-[0-9-]+$')][string]$ExpectedSid,
    [Parameter(Mandatory)][ValidateSet('new', 'open', 'stop', 'destroy', 'list', 'template')][string]$Action,
    [ValidatePattern('^[a-z][a-z0-9-]{0,30}[a-z0-9]$')][string]$Name,
    [ValidateRange(0,64)][int]$CPUs = 0,
    [ValidateRange(0,131072)][int]$MemoryMB = 0,
    [switch]$Refresh
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Set trusted native/module search paths before the first autoloading cmdlet.
$system = [Environment]::SystemDirectory
$env:Path = "$system;$system\WindowsPowerShell\v1.0;$system\OpenSSH"
$env:PSModulePath = "$system\WindowsPowerShell\v1.0\Modules"
. (Join-Path $PSScriptRoot 'VM-State.ps1')
. (Join-Path $PSScriptRoot '..\VM-Resources.ps1')
. (Join-Path $PSScriptRoot 'VM-Image.ps1')
. (Join-Path $PSScriptRoot 'Seed-ISO.ps1')
. (Join-Path $PSScriptRoot 'VM-Policy.ps1')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.Owner.Value -ne 'S-1-5-32-544') { throw 'The elevated token must create administrator-owned objects. No VM operation was started.' }
if ($identity.User.Value -cne $ExpectedSid) { throw 'Approve elevation with the same Windows account.' }
$store = Get-VMStore
New-Item -ItemType Directory -Path $store.Requests -Force | Out-Null
$resultPath = Join-Path $store.Requests ($RequestId + '.result.json')
$logPath = Join-Path $store.Requests ($RequestId + '.log')
if ((Test-Path -LiteralPath $resultPath) -or (Test-Path -LiteralPath $logPath)) { throw 'Request identity already used.' }
$request = [pscustomobject]@{ Action = $Action; Name = $Name; CPUs = $CPUs; MemoryMB = $MemoryMB; Refresh = [bool]$Refresh }
$guard = $null
$transcript = $false
try {
    Start-Transcript -LiteralPath $logPath | Out-Null
    $transcript = $true
    if ($request.Action -notin @('new', 'open', 'stop', 'destroy', 'list', 'template')) { throw 'Unknown VM action.' }
    # Ignore caller PATH, PowerShell module paths and Packer environment overrides.
    $system = [Environment]::SystemDirectory
    $env:Path = "$system;$system\WindowsPowerShell\v1.0;$system\OpenSSH"
    $env:PSModulePath = "$system\WindowsPowerShell\v1.0\Modules"
    foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(PACKER_|PKR_VAR_)' })) { Remove-Item -LiteralPath ("Env:" + $entry.Name) }
    $env:PACKER_CONFIG_DIR = Join-Path $store.Root 'Packer'
    $env:PACKER_PLUGIN_PATH = Join-Path $store.Root 'Packer\plugins'
    $env:PACKER_CONFIG = Join-Path $store.Root 'Packer\config.json'
    $env:TEMP = Join-Path $store.Root 'Temp'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP, $env:PACKER_PLUGIN_PATH -Force | Out-Null
    if (-not (Test-Path -LiteralPath $env:PACKER_CONFIG)) { Write-VMJson $env:PACKER_CONFIG @{} }
    Set-Location -LiteralPath $store.Root
    $hyperV = Get-Module -ListAvailable -Name Hyper-V | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $hyperV) { throw 'Hyper-V PowerShell module is missing from the trusted Windows module directory.' }
    Import-Module -Name $hyperV.Path
    $settings = Read-VMJson (Join-Path $store.Commands 'settings.json')
    $setup = Read-VMJson (Join-Path $store.Commands 'setup.json')
    if ($request.Action -eq 'template') {
        $image = Get-OrCreateVMImage $settings $setup ([bool]$request.Refresh)
        Write-VMJson $resultPath @{ OK = $true; Data = @{ ImageId = $image.Record.Id; Revision = $image.Record.Revision } }
        exit 0
    }
    if ($request.Action -eq 'list') {
        $rows = @()
        if (Test-Path -LiteralPath $store.Instances) {
            foreach ($directory in Get-ChildItem -LiteralPath $store.Instances -Directory) {
                if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'instance.json'))) { continue }
                $instance = Get-ManagedInstance $directory.Name
                $vm = Get-ManagedHyperV $instance
                $state = if ($vm) { [string]$vm.State } else { 'Missing' }
                $rows += @{ Name = $instance.Record.Name; State = $state; CPUs = $instance.Record.Resources.CPUs; MemoryMB = $instance.Record.Resources.MemoryMB; DiskGB = $instance.Record.Resources.DiskGB }
            }
        }
        Write-VMJson $resultPath @{ OK = $true; Data = $rows }
        exit 0
    }
    Assert-VMName $request.Name
    $locks = Join-Path $store.Root 'Locks'
    New-Item -ItemType Directory -Path $locks -Force | Out-Null
    $guard = [IO.File]::Open((Join-Path $locks ($request.Name + '.lock')), 'OpenOrCreate', 'ReadWrite', 'None')
    $directory = Assert-VMPath (Join-Path $store.Instances $request.Name) $store.Instances
    $recordPath = Join-Path $directory 'instance.json'
    $deleteJournal = Join-Path $locks ($request.Name + '.delete.json')
    if (Test-Path -LiteralPath $deleteJournal) {
        if ($request.Action -ne 'destroy') { throw 'Removal was interrupted. Repeat wvm destroy with this name before reusing it.' }
        Restore-VMDeletionRecord $request.Name $deleteJournal $directory
    }
    if ($request.Action -eq 'destroy' -and -not (Test-Path -LiteralPath $directory)) {
        if (Get-VM -Name ('ws-' + $request.Name) -ErrorAction SilentlyContinue) { throw 'An unrecorded VM uses this name. It was preserved.' }
        Write-VMJson $resultPath @{ OK = $true; Data = @{ Name = $request.Name; Removed = $true; AlreadyAbsent = $true; InstallationId = '' } }
        exit 0
    }
    if ($request.Action -eq 'new' -and -not (Test-Path -LiteralPath $recordPath)) {
        if ((Test-Path -LiteralPath $directory) -or (Get-VM -Name ('ws-' + $request.Name) -ErrorAction SilentlyContinue)) { throw 'VM name or directory is already in use without a managed record. It was left unchanged.' }
        $cpuInput = if ($request.CPUs) { $request.CPUs } else { $setup.Resources.CPUs }
        $memoryInput = if ($request.MemoryMB) { $request.MemoryMB } else { $setup.Resources.MemoryMB }
        $cpus = ConvertTo-WorkstationResource CPUs $cpuInput 2 64
        $memory = ConvertTo-WorkstationResource MemoryMB $memoryInput 4096 131072
        $image = Get-OrCreateVMImage $settings $setup $false
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $record = @{ Schema = 1; Kind = 'Temporary'; Name = $request.Name; VMName = ('ws-' + $request.Name); Id = [Guid]::NewGuid().ToString('N'); VMId = ''; ImageId = $image.Record.Id; Phase = 'Constructing'; Resources = @{ CPUs = $cpus; MemoryMB = $memory; DiskGB = $image.Record.Resources.DiskGB } }
        $record.MacAddress = '02' + $record.Id.Substring(0, 10).ToUpperInvariant()
        Write-VMJson $recordPath $record
    }
    $instance = Get-ManagedInstance $request.Name
    $record = $instance.Record
    $vm = Get-ManagedHyperV $instance
    if ($request.Action -eq 'destroy') {
        Assert-VMTree $directory $store.Instances
        Assert-NoOtherDiskUsers $instance $vm
        $record.Phase = 'Deleting'
        Write-VMJson $recordPath $record
        Write-VMJson $deleteJournal $record
        if ($vm) {
            if ($vm.State -eq 'Saved') { Remove-VMSavedState -VM $vm }
            elseif ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
            Remove-VM -VM $vm -Force
        }
        # Parent image is outside this validated instance directory and is never removed here.
        Remove-Item -LiteralPath $directory -Recurse -Force
        Remove-Item -LiteralPath $deleteJournal
        Write-VMJson $resultPath @{ OK = $true; Data = @{ Name = $request.Name; Removed = $true; InstallationId = $record.Id } }
        exit 0
    }
    if ($record.Phase -eq 'Deleting') { throw 'Removal was interrupted. Repeat wvm destroy with this name to finish it.' }
    if ($request.Action -eq 'new' -and $record.Phase -eq 'Constructing') {
        if (-not $vm -and $record.VMId) { throw 'Registered VM is missing. Recover it manually; existing disks will not be rebuilt.' }
        $image = Get-VMImage $record.ImageId
        if ((Get-FileHash -LiteralPath $image.Base -Algorithm SHA256).Hash -ne $image.Record.SHA256) { throw 'Base image checksum changed; no new VM will be booted.' }
        $disk = Join-Path $directory 'os.vhdx'
        $seed = Join-Path $directory 'seed'
        $iso = Join-Path $directory 'seed.iso'
        foreach ($path in @($disk, $seed, $iso)) { $null = Assert-VMPath $path $directory }
        if (-not $vm) {
            if (-not (Test-Path -LiteralPath $disk)) { New-VHD -Path $disk -ParentPath $image.Base -Differencing | Out-Null }
            if ((Get-VHD -Path $disk).ParentPath -ine $image.Base) { throw 'Existing disk has an unexpected parent.' }
            New-Item -ItemType Directory -Path $seed -Force | Out-Null
            $publicKey = (Get-Content -LiteralPath $setup.PublicKeyPath -Raw).Trim()
            if ($publicKey -notmatch '^(ssh-ed25519|ssh-rsa) ([A-Za-z0-9+/]+={0,3})(?: [^\r\n]*)?$') { throw 'Unexpected SSH public key.' }
            $publicKey = "$($Matches[1]) $($Matches[2])"
            $hostIdentity = Initialize-VMHostIdentity $directory
            $cloud = @{
                hostname = $record.VMName; manage_etc_hosts = $true; disable_root = $true; ssh_pwauth = $false; ssh_deletekeys = $true; ssh_genkeytypes = @('ed25519'); ssh_keys = @{ ed25519_private = [IO.File]::ReadAllText($hostIdentity); ed25519_public = [IO.File]::ReadAllText($hostIdentity + '.pub').Trim() }
                users = @(@{ name = 'dev'; lock_passwd = $true; groups = @('sudo'); shell = '/usr/bin/zsh'; ssh_authorized_keys = @($publicKey) })
                write_files = @(
                    @{ path = '/etc/workstation-bootstrap-id'; owner = 'root:root'; permissions = '0644'; content = ($record.Id + "`n") },
                    @{ path = '/etc/sudoers.d/90-workstation'; owner = 'root:root'; permissions = '0440'; content = "dev ALL=(ALL) NOPASSWD:ALL`n" },
                    @{ path = '/home/dev/.ssh/authorized_keys'; owner = 'dev:dev'; permissions = '0600'; content = ($publicKey + "`n") }
                )
                runcmd = @(, @('/usr/bin/install', '-d', '-m', '0700', '-o', 'dev', '-g', 'dev', ('/home/dev/.local/state/workstation-bootstrap/' + $record.Id)))
            }
            foreach ($name in @('user-data', 'meta-data', 'network-config')) { $null = Assert-VMPath (Join-Path $seed $name) $directory }
            $encoding = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText((Join-Path $seed 'user-data'), ("#cloud-config`n" + ($cloud | ConvertTo-Json -Depth 12)), $encoding)
            [IO.File]::WriteAllText((Join-Path $seed 'meta-data'), (@{ 'instance-id' = $record.Id; 'local-hostname' = $record.VMName } | ConvertTo-Json), $encoding)
            [IO.File]::WriteAllText((Join-Path $seed 'network-config'), (@{ version = 2; ethernets = @{ primary = @{ match = @{ name = 'e*' }; dhcp4 = $true; 'dhcp-identifier' = 'mac' } } } | ConvertTo-Json -Depth 8), $encoding)
            if (-not (Test-Path -LiteralPath $iso)) { New-VMSeedISO $seed $iso }
            $null = Get-VMSwitch -Name 'Default Switch' -ErrorAction Stop
            $vm = New-VM -Name $record.VMName -Generation 2 -MemoryStartupBytes ([long]$record.Resources.MemoryMB * 1MB) -VHDPath $disk -SwitchName 'Default Switch' -Path (Join-Path $directory 'machine')
            $record.VMId = [string]$vm.Id
            Write-VMJson $recordPath $record
        }
        if ($vm.State -ne 'Off') { throw 'Unfinished VM hardware setup requires the temporary VM to be off.' }
        if ($record.PSObject.Properties.Name -contains 'MacAddress') { Set-VMNetworkIdentity $vm $record.MacAddress }
        Set-VMProcessor -VM $vm -Count $record.Resources.CPUs
        Set-TemporaryVMHardwarePolicy $vm
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ([long]$record.Resources.MemoryMB * 1MB)
        $dvd = @(Get-VMDvdDrive -VM $vm)
        if (-not $dvd.Count) { Add-VMDvdDrive -VMName $record.VMName -Path $iso | Out-Null }
        elseif ($dvd.Count -ne 1 -or $dvd[0].Path -ine $iso) { throw 'Unexpected DVD attachment.' }
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
        Set-VM -VM $vm -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false
        $record.Phase = 'Ready'
        Write-VMJson $recordPath $record
    }
    if (-not $vm) { throw 'VM is missing. Existing disks were preserved; recover the VM in Hyper-V Manager.' }
    if ($record.Phase -ne 'Ready') { throw 'VM creation is incomplete. Repeat wvm new with the same name.' }
    if (($request.CPUs -and $request.CPUs -ne $record.Resources.CPUs) -or ($request.MemoryMB -and $request.MemoryMB -ne $record.Resources.MemoryMB)) { throw 'Existing VM resources differ; commands do not resize VMs.' }
    if ($request.Action -eq 'stop') {
        if ($vm.State -eq 'Saved') { Set-TemporaryVMPolicy $vm; Assert-TemporaryVMCapacity $record; Start-VM -VM $vm | Out-Null }
        elseif ($vm.State -eq 'Paused') { Resume-VM -VM $vm | Out-Null }
        if ($vm.State -ne 'Off') { Stop-VM -VM $vm }
        Write-VMJson $resultPath @{ OK = $true; Data = @{ Name = $request.Name; State = 'Off' } }
        exit 0
    }
    if ($record.PSObject.Properties.Name -contains 'MacAddress') {
        $adapters = @(Get-VMNetworkAdapter -VM $vm)
        if ($adapters.Count -ne 1 -or $adapters[0].MacAddress -ine $record.MacAddress) { throw 'Managed adapter identity changed. Inspect the VM before opening it.' }
    }
    # Apply the host policy before every managed start/open. Replacement disconnects
    # the NIC first and never reconnects on failure. No guest firewall dependency.
    Set-TemporaryVMPolicy $vm
    if ($vm.State -in @('Off', 'Saved')) { Assert-TemporaryVMCapacity $record; Start-VM -VM $vm | Out-Null }
    elseif ($vm.State -eq 'Paused') { Resume-VM -VM $vm | Out-Null }
    elseif ($vm.State -ne 'Running') { throw 'VM needs attention in Hyper-V Manager.' }
    # The protected pin belongs to this generation, even when DHCP reuses an IP.
    $hostPublicKey = [IO.File]::ReadAllText((Join-Path $directory 'ssh_host_ed25519_key.pub')).Trim()
    $protectedKnown = Join-Path $directory 'connection-known_hosts'
    $ssh = Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
    $private = $setup.PublicKeyPath.Substring(0, $setup.PublicKeyPath.Length - 4)
    $verifyIdentity = {
        param($candidate)
        Save-VMHostPin $protectedKnown $candidate $hostPublicKey
        $options = @('-F', 'NUL', '-i', $private, '-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes', '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', ('UserKnownHostsFile="' + $protectedKnown.Replace('\', '/') + '"'), '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2', ('dev@' + $candidate), ("test `"`$(cat /etc/workstation-bootstrap-id)`" = '" + $record.Id + "'"))
        $probe = Invoke-VMNative $ssh $options
        return ($probe.ExitCode -eq 0)
    }
    $address = Wait-VMAddress $record.VMName $verifyIdentity $record.VMId
    $image = Get-VMImage $record.ImageId
    Write-VMJson $resultPath @{ OK = $true; Data = @{ Name = $record.Name; Alias = $record.VMName; Address = $address; HostPublicKey = [IO.File]::ReadAllText((Join-Path $directory 'ssh_host_ed25519_key.pub')).Trim(); User = 'dev'; InstallationId = $record.Id; Directory = (Join-Path $store.Connections $record.Name); KnownHostsFile = (Join-Path (Join-Path $store.Connections $record.Name) 'known_hosts'); IdentityFile = $setup.PublicKeyPath.Substring(0, $setup.PublicKeyPath.Length - 4); FinalizerPath = (Join-Path $image.Directory 'finalize-account.sh') } }
} catch {
    Write-VMJson $resultPath @{ OK = $false; Error = $_.Exception.Message; Context = $_.ScriptStackTrace }
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($guard) { $guard.Dispose() }
    if ($transcript) { Stop-Transcript | Out-Null }
}
