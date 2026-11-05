function ConvertTo-UbuntuIPv4Prefix([string]$Value) {
    if ($Value -ieq 'ANY' -or -not $Value) { return 'ANY' }
    $parts = $Value.Split('/')
    $ip = [Net.IPAddress]::Parse($parts[0])
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Expected an IPv4 network.' }
    $length = 32
    if ($parts.Count -eq 2) { $length = [int]$parts[1] }
    if ($parts.Count -gt 2 -or $length -lt 0 -or $length -gt 32) { throw 'Invalid IPv4 prefix.' }
    $bytes = $ip.GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, $length - 8 * $i))
        $bytes[$i] = $bytes[$i] -band (256 - [Math]::Pow(2, 8 - $bits))
    }
    return ($bytes -join '.') + '/' + $length
}

function Get-UbuntuNetworkTopology([string]$SwitchName) {
    # Custom DHCP/NAT deployments need their own infrastructure policy; never guess its server addresses.
    if ($SwitchName -cne 'Default Switch') { throw 'Ubuntu network isolation currently requires the Windows Default Switch.' }
    $switch = Get-VMSwitch -Name $SwitchName
    if ($switch.SwitchType -ne 'Internal') { throw 'Expected an Internal Default Switch.' }
    $interfaces = @(Get-NetAdapter -IncludeHidden | Where-Object Name -ceq ('vEthernet (' + $SwitchName + ')'))
    if ($interfaces.Count -ne 1) { throw 'Cannot uniquely identify the Default Switch host interface; no policy was changed.' }
    $interface = $interfaces[0]
    $mac = ([string]$interface.MacAddress -replace '[:-]', '').ToUpperInvariant()
    if ($mac -cnotmatch '^[A-F0-9]{12}$' -or $mac -eq '000000000000') { throw 'Invalid Default Switch host MAC address.' }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -in @('Preferred', 'Deprecated') })
    $gateway = @($addresses | Where-Object { $_.InterfaceIndex -eq $interface.ifIndex -and $_.IPAddress -notlike '169.254.*' })
    if ($gateway.Count -ne 1) { throw 'Expected one IPv4 DHCP/DNS gateway on the Default Switch; no policy was changed.' }
    $blocked = @(
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
        '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16',
        '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
    )
    # Also protect public-address LANs and host interfaces, not only RFC1918 networks.
    $blocked += @($addresses | ForEach-Object { ConvertTo-UbuntuIPv4Prefix $_.IPAddress })
    $blocked += @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.NextHop -eq '0.0.0.0' -and $_.DestinationPrefix -ne '0.0.0.0/0' } | ForEach-Object { ConvertTo-UbuntuIPv4Prefix $_.DestinationPrefix })
    [pscustomobject]@{
        SwitchId = [string]$switch.Id
        Gateway = $gateway[0].IPAddress
        GatewayMac = $mac
        Blocked = @($blocked | Sort-Object -Unique)
    }
}

function Get-UbuntuNetworkRules([object]$Topology) {
    $rules = New-Object Collections.Generic.List[object]
    foreach ($direction in @('Inbound', 'Outbound')) {
        $rules.Add(@{ Direction = $direction; Action = 'Deny'; RemoteIPAddress = 'ANY'; Weight = 1 })
    }
    # Higher weights win. Only host-initiated SSH may create a return flow to the host.
    $rules.Add(@{ Direction = 'Inbound'; Action = 'Allow'; RemoteIPAddress = $Topology.Gateway; Protocol = 'TCP'; LocalPort = '22'; Weight = 60000; Stateful = $true; IdleSessionTimeout = 3600 })
    foreach ($protocol in @('TCP', 'UDP')) {
        $rules.Add(@{ Direction = 'Outbound'; Action = 'Allow'; RemoteIPAddress = $Topology.Gateway; Protocol = $protocol; RemotePort = '53'; Weight = 59000 - [int]($protocol -eq 'UDP'); Stateful = $true; IdleSessionTimeout = 300 })
    }
    $rules.Add(@{ Direction = 'Outbound'; Action = 'Allow'; RemoteIPAddress = '255.255.255.255'; Protocol = 'UDP'; LocalPort = '68'; RemotePort = '67'; Weight = 58000 })
    $rules.Add(@{ Direction = 'Outbound'; Action = 'Allow'; RemoteIPAddress = $Topology.Gateway; Protocol = 'UDP'; LocalPort = '68'; RemotePort = '67'; Weight = 57999 })
    $rules.Add(@{ Direction = 'Inbound'; Action = 'Allow'; RemoteIPAddress = $Topology.Gateway; Protocol = 'UDP'; LocalPort = '68'; RemotePort = '67'; Weight = 57998 })
    $weight = 50000
    foreach ($prefix in $Topology.Blocked) {
        if ($weight -le 20000) { throw 'Too many local networks for the isolation rule range.' }
        $rules.Add(@{ Direction = 'Outbound'; Action = 'Deny'; RemoteIPAddress = $prefix; Weight = $weight-- })
    }
    foreach ($protocol in @('TCP', 'UDP')) {
        $rules.Add(@{ Direction = 'Outbound'; Action = 'Allow'; RemoteIPAddress = '0.0.0.0/0'; Protocol = $protocol; Weight = 10000 - [int]($protocol -eq 'UDP'); Stateful = $true; IdleSessionTimeout = 3600 })
    }
    # No IPv6 or non-TCP/UDP allow: tunnels and link-local IPv6 must not bypass IPv4 restrictions.
    return $rules.ToArray()
}

function Get-UbuntuNetworkRuleKey([object]$Rule, [switch]$Mac) {
    if ($Mac) {
        $remote = [string]$Rule.RemoteMacAddress
        return (([string]$Rule.Direction).ToLowerInvariant(), ([string]$Rule.Action).ToLowerInvariant(), ($remote -replace '[:-]', '').ToUpperInvariant()) -join '|'
    }
    $isStateful = $false
    if ($Rule -is [Collections.IDictionary]) { if ($Rule.Contains('Stateful')) { $isStateful = [bool]$Rule['Stateful'] } }
    elseif ($Rule.PSObject.Properties['Stateful']) { $isStateful = [bool]$Rule.Stateful }
    $values = foreach ($name in @('Direction', 'Action', 'RemoteIPAddress', 'LocalIPAddress', 'Protocol', 'LocalPort', 'RemotePort', 'Weight', 'Stateful', 'IdleSessionTimeout', 'IsolationID')) {
        $value = $null
        if ($Rule -is [Collections.IDictionary]) { if ($Rule.Contains($name)) { $value = $Rule[$name] } }
        elseif ($Rule.PSObject.Properties[$name]) { $value = $Rule.$name }
        if ($name -in @('RemoteIPAddress', 'LocalIPAddress')) { $value = ConvertTo-UbuntuIPv4Prefix ([string]$value) }
        elseif ($name -in @('Protocol', 'LocalPort', 'RemotePort') -and (-not $value -or $value -eq 'ANY')) { $value = 'ANY' }
        elseif ($name -eq 'Stateful') { $value = [bool]$value }
        elseif ($name -eq 'IdleSessionTimeout' -and -not $isStateful) { $value = 0 }
        elseif ($name -eq 'IdleSessionTimeout' -and $null -eq $value) { $value = 255 }
        elseif ($name -eq 'IsolationID' -and $null -eq $value) { $value = 0 }
        if ($name -eq 'Protocol' -and $value -eq '6') { $value = 'TCP' }
        if ($name -eq 'Protocol' -and $value -eq '17') { $value = 'UDP' }
        ([string]$value).ToLowerInvariant()
    }
    return $values -join '|'
}

function Get-UbuntuAdapterRules([object]$Adapter) {
    $extended = @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $Adapter)
    $mac = @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $Adapter | ForEach-Object {
        if ([string]$_.RemoteAddressType -notin @('Mac', 'WildcardMac') -or ([string]$_.LocalAddress -notin @('', 'ANY'))) { throw 'Unmanaged basic ACL found; existing rules retained.' }
        @{ Direction = [string]$_.Direction; Action = [string]$_.Action; RemoteMacAddress = $_.RemoteAddress }
    })
    [pscustomobject]@{ Extended = $extended; Mac = $mac }
}

function Assert-UbuntuNetworkRules([object]$Actual, [object[]]$Extended, [object[]]$Mac, [switch]$Exact) {
    foreach ($kind in @('Extended', 'Mac')) {
        $expected = $Extended
        if ($kind -eq 'Mac') { $expected = $Mac }
        $keys = @($expected | ForEach-Object { Get-UbuntuNetworkRuleKey $_ -Mac:($kind -eq 'Mac') })
        $found = @($Actual.$kind | ForEach-Object { Get-UbuntuNetworkRuleKey $_ -Mac:($kind -eq 'Mac') })
        if (@($found | Select-Object -Unique).Count -ne $found.Count -or @($found | Where-Object { $_ -cnotin $keys }).Count -or ($Exact -and @($keys | Where-Object { $_ -cnotin $found }).Count)) { throw 'Network ACLs differ from their ownership journal; no unrelated rules were removed.' }
    }
}

function Test-UbuntuAdapterGuards([object]$Adapter) {
    return ($Adapter.MacAddressSpoofing -eq 'Off' -and $Adapter.DhcpGuard -eq 'On' -and $Adapter.RouterGuard -eq 'On' -and $Adapter.AllowTeaming -eq 'Off' -and $Adapter.PortMirroringMode -eq 'None' -and -not $Adapter.VFDataPathActive)
}

function Set-UbuntuNetworkPolicy([object]$Record) {
    $vm = Get-UbuntuOwnedVM $Record
    if ($vm.State -ne 'Off') { throw 'Shut down this Ubuntu VM normally before installing or refreshing network isolation. No forced power-off was attempted.' }
    $topology = Get-UbuntuNetworkTopology $Record.SwitchName
    $adapter = @(Get-VMNetworkAdapter -VM $vm)[0]
    $path = Join-Path $Record.Root 'network-policy.json'
    Assert-UbuntuPath $path
    $actual = Get-UbuntuAdapterRules $adapter
    $prior = $null
    if (Test-Path -LiteralPath $path) {
        $prior = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($prior.Schema -ne 1 -or $prior.Phase -cnotin @('Applying', 'Applied') -or $prior.VMId -cne $Record.VMId -or $prior.Token -cne $Record.Token -or $prior.AdapterId -cne $adapter.Id) { throw 'Network policy ownership differs; VM retained.' }
        Assert-UbuntuNetworkRules $actual @($prior.Extended) @($prior.Mac)
    } elseif ($actual.Extended.Count -or $actual.Mac.Count) { throw 'Unmanaged network ACLs found; existing rules retained.' }
    $extended = @(Get-UbuntuNetworkRules $topology)
    # Default Switch boot networking fails with wildcard MAC ACLs in live tests.
    # IP/state rules enforce connection isolation; retain old MAC entries only for owned-rule migration.
    $mac = @()
    if ($prior -and $prior.Phase -ceq 'Applied' -and ($prior.Topology | ConvertTo-Json -Depth 6 -Compress) -ceq ($topology | ConvertTo-Json -Depth 6 -Compress)) {
        $matches = $true
        try { Assert-UbuntuNetworkRules $actual $extended $mac -Exact } catch { $matches = $false }
        if ($matches -and (Test-UbuntuAdapterGuards $adapter)) { return }
    }
    $state = [ordered]@{ Schema = 1; VMId = $Record.VMId; Token = $Record.Token; AdapterId = $adapter.Id; Phase = 'Applying'; Topology = $topology; Extended = $extended; Mac = $mac }
    if ($prior) {
        $state.Extended = @(@(@($prior.Extended) + $extended) | Group-Object { Get-UbuntuNetworkRuleKey $_ } | ForEach-Object { $_.Group[0] })
        $state.Mac = @(@(@($prior.Mac) + $mac) | Group-Object { Get-UbuntuNetworkRuleKey $_ -Mac } | ForEach-Object { $_.Group[0] })
    }
    # Journal before the first mutation. An interrupted operation owns only these exact rules.
    Save-UbuntuText $path ($state | ConvertTo-Json -Depth 10)
    Set-VMNetworkAdapter -VMNetworkAdapter $adapter -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On -AllowTeaming Off -PortMirroring None -IovWeight 0
    foreach ($rule in $actual.Extended) { Remove-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -Direction $rule.Direction -Weight $rule.Weight -Confirm:$false }
    foreach ($rule in $actual.Mac) { Remove-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -Direction $rule.Direction -Action $rule.Action -RemoteMacAddress $rule.RemoteMacAddress -Confirm:$false }
    foreach ($rule in $mac) { Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter @rule }
    foreach ($rule in $extended) {
        try { Add-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter @rule }
        catch { throw ('Hyper-V rejected network rule ' + (Get-UbuntuNetworkRuleKey $rule) + ': ' + $_.Exception.Message) }
    }
    Assert-UbuntuNetworkRules (Get-UbuntuAdapterRules $adapter) $extended $mac -Exact
    $vm = Get-UbuntuOwnedVM $Record
    if ($vm.State -ne 'Off' -or -not (Test-UbuntuAdapterGuards (@(Get-VMNetworkAdapter -VM $vm)[0]))) { throw 'VM state or network guards changed during policy installation; no successful policy was recorded.' }
    if (($topology | ConvertTo-Json -Depth 6 -Compress) -cne ((Get-UbuntuNetworkTopology $Record.SwitchName) | ConvertTo-Json -Depth 6 -Compress)) { throw 'Host topology changed during policy installation; VM left Off. Rerun setup.' }
    $state.Phase = 'Applied'; $state.Extended = $extended; $state.Mac = $mac
    Save-UbuntuText $path ($state | ConvertTo-Json -Depth 10)
}

function Assert-UbuntuNetworkPolicy([object]$Record) {
    $vm = Get-UbuntuOwnedVM $Record
    $adapter = @(Get-VMNetworkAdapter -VM $vm)[0]
    $path = Join-Path $Record.Root 'network-policy.json'
    Assert-UbuntuPath $path
    if (-not (Test-Path -LiteralPath $path)) { throw 'This Ubuntu VM has no network policy yet. Shut it down normally and rerun setup to install isolation.' }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($state.Schema -ne 1 -or $state.Phase -cne 'Applied' -or $state.VMId -cne $Record.VMId -or $state.Token -cne $Record.Token -or $state.AdapterId -cne $adapter.Id) { throw 'Network isolation is incomplete or belongs to another adapter. Shut down the VM and rerun setup.' }
    $topology = Get-UbuntuNetworkTopology $Record.SwitchName
    if (($state.Topology | ConvertTo-Json -Depth 6 -Compress) -cne ($topology | ConvertTo-Json -Depth 6 -Compress)) { throw 'Host network topology changed. Shut down this VM and rerun setup to refresh isolation before using it.' }
    Assert-UbuntuNetworkRules (Get-UbuntuAdapterRules $adapter) @($state.Extended) @($state.Mac) -Exact
    if (-not (Test-UbuntuAdapterGuards $adapter)) { throw 'VM network guard settings changed; isolation could not be verified.' }
}
