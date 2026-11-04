# Host-enforced policy for recorded temporary VMs only. Never apply to image builders
# or existing development VMs. Public IPv4 TCP/UDP is available, including DNS/QUIC.
function Set-TemporaryVMPolicy([object]$VM) {
    $adapters = @(Get-VMNetworkAdapter -VM $VM)
    if ($adapters.Count -ne 1) { throw 'Temporary VMs require exactly one network adapter.' }
    $nic = $adapters[0]
    if ($nic.SwitchName -and $nic.SwitchName -ne 'Default Switch') { throw 'Unexpected VM switch; inspect it before reconnecting.' }
    # Disconnect before policy discovery or replacement: failure leaves the NIC isolated.
    Disconnect-VMNetworkAdapter -VMNetworkAdapter $nic -Confirm:$false
    $switch = Get-VMSwitch -Name 'Default Switch' -ErrorAction Stop
    if ($switch.SwitchType -ne 'Internal') { throw 'Default Switch must be Internal.' }
    $hostNic = @(Get-VMNetworkAdapter -ManagementOS | Where-Object SwitchId -eq $switch.Id)
    if ($hostNic.Count -ne 1) { throw 'Expected one host adapter on Default Switch.' }
    $hostMAC = $hostNic[0].MacAddress
    $interfaces = @(Get-NetAdapter -IncludeHidden | Where-Object { ($_.MacAddress -replace '[:-]', '') -eq $hostMAC })
    if ($interfaces.Count -ne 1) { throw 'Could not identify the Default Switch host interface.' }
    $gateway = @(Get-NetIPAddress -InterfaceIndex $interfaces[0].ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
    if ($gateway.Count -ne 1) { throw 'Expected one Default Switch IPv4 gateway/DNS address.' }
    $hostIP = $gateway[0].IPAddress
    $blocked = @('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4')
    # Include public-address LANs and VPN routes, not just RFC1918 ranges. A split
    # default VPN route can intentionally deny all egress; never silently bypass it.
    $blocked += @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $_.IPAddress + '/32' })
    $blocked += @(Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -ne '0.0.0.0/0' | Select-Object -ExpandProperty DestinationPrefix)
    $blocked = @($blocked | Sort-Object -Unique)
    Set-VMNetworkAdapter -VMNetworkAdapter $nic -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On -PortMirroring None -MaximumBandwidth 250000000
    Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $nic | Remove-VMNetworkAdapterExtendedAcl -Confirm:$false
    # Higher weights run first. Stateful allows create return-flow exceptions.
    $rules = @(
        @{ Action = 'Deny'; Direction = 'Inbound'; Weight = 1 },
        @{ Action = 'Deny'; Direction = 'Outbound'; Weight = 1 },
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = '0.0.0.0/0'; Protocol = '1'; Weight = 120 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = '0.0.0.0/0'; Protocol = 'TCP'; Stateful = $true; IdleSessionTimeout = 3600; Weight = 100 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = '0.0.0.0/0'; Protocol = 'UDP'; Stateful = $true; IdleSessionTimeout = 120; Weight = 110 },
        @{ Action = 'Deny'; Direction = 'Outbound'; RemoteIPAddress = '::/0'; Weight = 30000 },
        @{ Action = 'Deny'; Direction = 'Inbound'; RemoteIPAddress = '::/0'; Weight = 30000 },
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = "$hostIP/32"; LocalPort = '22'; Protocol = 'TCP'; Stateful = $true; IdleSessionTimeout = 3600; Weight = 31000 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = "$hostIP/32"; RemotePort = '53'; Protocol = 'TCP'; Stateful = $true; IdleSessionTimeout = 120; Weight = 31010 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = "$hostIP/32"; RemotePort = '53'; Protocol = 'UDP'; Stateful = $true; IdleSessionTimeout = 120; Weight = 31020 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = '255.255.255.255/32'; LocalPort = '68'; RemotePort = '67'; Protocol = 'UDP'; Weight = 31030 },
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = "$hostIP/32"; LocalPort = '68'; RemotePort = '67'; Protocol = 'UDP'; Weight = 31040 },
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = "$hostIP/32"; LocalPort = '68'; RemotePort = '67'; Protocol = 'UDP'; Weight = 31050 }
    )
    $weight = 1000
    foreach ($prefix in $blocked) {
        $rules += @{ Action = 'Deny'; Direction = 'Outbound'; RemoteIPAddress = $prefix; Weight = $weight }
        $weight++
    }
    if ($weight -ge 30000) { throw 'Too many host routes for the isolation policy.' }
    foreach ($rule in $rules) { Add-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $nic @rule }
    if (@(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $nic).Count -ne $rules.Count) { throw 'VM network policy installation was incomplete.' }
    Connect-VMNetworkAdapter -VMNetworkAdapter $nic -SwitchName $switch.Name
}

function Assert-TemporaryVMCapacity([object]$Record) {
    $store = Get-VMStore
    $volume = Get-Volume -FilePath $store.Root -ErrorAction Stop
    # Conservative admission reservation, not a filesystem quota. No cleanup of user work.
    $required = 20GB
    foreach ($directory in Get-ChildItem -LiteralPath $store.Instances -Directory) {
        $instance = Get-ManagedInstance $directory.Name
        $required += [long]$instance.Record.Resources.DiskGB * 1GB
    }
    if ($volume.SizeRemaining -lt $required) { throw 'Insufficient disk headroom: reserve full capacity for managed temporary disks plus 20 GiB. Existing VMs were preserved.' }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([long]$os.FreePhysicalMemory * 1KB -lt ([long]$Record.Resources.MemoryMB * 1MB + 2GB)) { throw 'Insufficient available RAM: leave at least 2 GiB for Windows.' }
}

function Set-TemporaryVMHardwarePolicy([object]$VM) {
    Set-VMProcessor -VM $VM -Maximum 80 -ExposeVirtualizationExtensions $false
    Get-VMHardDiskDrive -VM $VM | Set-VMHardDiskDrive -MaximumIOPS 3000
    # Guest Service Interface enables host-to-guest file copy. Component ID is
    # locale independent; heartbeat/shutdown/KVP remain available for lifecycle.
    Get-VMIntegrationService -VM $VM | Where-Object { [string]$_.Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480*' } | Disable-VMIntegrationService
}
