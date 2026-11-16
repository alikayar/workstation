# Loaded by Run-Tests.ps1. Every destination belongs to the current test run.
function Set-Answers([string[]]$Values) {
    $script:Answers = New-Object 'Collections.Generic.Queue[string]'
    foreach ($value in $Values) { $Answers.Enqueue($value) }
}
function Read-Host([string]$Prompt, [switch]$AsSecureString) {
    if ($AsSecureString -or $null -eq $script:Answers -or -not $Answers.Count) { throw ('Unplanned interactive prompt: ' + $Prompt) }
    return $Answers.Dequeue()
}
function New-ConfigScenario([string]$Directory, $Config, $LayerConfig) {
    $configDirectory = Join-Path $Directory 'codex-config'
    $path = Join-Path $configDirectory 'config.toml'
    Write-Fixture $path '# Synthetic config; the test peer supplies parsed values.'
    return @{
        directory=$configDirectory; path=$path; capture=(Join-Path $Directory 'writes.jsonl'); exited=(Join-Path $Directory 'peer-exited.txt')
        read=@{ config=$Config; layers=@(@{ name=@{type='user';file=$path;profile=$null};config=$LayerConfig;version='fixture-version-1' }) }
    }
}
function Invoke-ConfigScenario($Scenario) {
    $fixture = Join-Path (Split-Path -Parent $Scenario.path) 'peer.json'
    Write-Fixture $fixture ($Scenario | ConvertTo-Json -Depth 30)
    $prior = [Environment]::GetEnvironmentVariable('WORKSTATION_CODEX_TEST_CASE', 'Process')
    try {
        $env:WORKSTATION_CODEX_TEST_CASE = $fixture
        Set-CodexConfig $ConfigPeer $Scenario.directory
    } finally {
        [Environment]::SetEnvironmentVariable('WORKSTATION_CODEX_TEST_CASE', $prior, 'Process')
        if (Test-Path -LiteralPath $Scenario.exited) { Write-Host ('Synthetic peer: ' + [IO.File]::ReadAllText($Scenario.exited)) }
    }
}
function Read-ConfigEdits($Scenario) {
    $requests = @([IO.File]::ReadAllLines($Scenario.capture) | ForEach-Object { ConvertFrom-CodexJSON $_ })
    Assert-Equal $requests.Count 1 'Expected one atomic config write'
    Assert-Equal $requests[0]['params']['expectedVersion'] 'fixture-version-1'
    Assert-Equal $requests[0]['params']['filePath'] $Scenario.path
    return $requests[0]['params']['edits']
}
function New-AppearanceFixture([string]$Directory) {
    $relative = (Split-Path -Leaf $Directory) + '\appearance-source'
    $library = Export-TestFunctions 'host/windows/vscode/Install-VSCode.ps1' $relative
    $source = Join-Path (Split-Path -Parent $library) 'appearance'
    Write-Fixture (Join-Path $source 'package.json') '{"publisher":"workstation-local","name":"appearance","version":"0.0.1"}'
    Write-Fixture (Join-Path $source 'theme.json') '{"colors":{"editor.background":"#123456"}}'
    return @{ Library=$library; Source=$source; Extensions=(Join-Path $Directory 'extensions'); Destination=(Join-Path $Directory 'extensions\workstation-local.appearance-0.0.1') }
}

Add-Case 'Resource limits reject malformed and overflowing values' {
    param($directory)
    Assert-Equal (ConvertTo-WorkstationResource 'RAM' '2' 2 64) 2
    Assert-Equal (ConvertTo-WorkstationResource 'RAM' '64' 2 64) 64
    foreach ($value in @('1','65','-2','2.5','two','','2147483648')) {
        $null = Assert-Throws { ConvertTo-WorkstationResource 'RAM' $value 2 64 } 'integer between'
    }
}
Add-Case 'Selection supports names, numbers, deduplication and invalid-input retry' {
    param($directory)
    Set-Answers @('invalid', '1,browser,2')
    Assert-Equal @(Read-WorkstationSelection 'Fixture' @('codex','browser') @('Codex','Chrome')) @('codex','browser')
    Assert-Equal $Answers.Count 0
    Set-Answers @('hepsi')
    Assert-Equal @(Read-WorkstationSelection 'Fixture' @('node','python') @('Node','Python')) @('node','python')
    Set-Answers @('')
    Assert-Equal @(Read-WorkstationSelection 'Fixture' @('node') @('Node')) @()
}
Add-Case 'Declined provisioning asks no identity questions' {
    param($directory)
    Set-Answers @('n')
    $result = Read-WorkstationConfiguration
    Assert-True (-not $result.Enabled)
    Assert-Equal $result.GitName ''
    Assert-Equal $Answers.Count 0
}
Add-Case 'All shortcut still requires final consent' {
    param($directory)
    Set-Answers @('hepsi','n')
    $result = Read-WorkstationConfiguration
    Assert-True (-not $result.Enabled)
    Assert-True ('browser' -in $result.Components)
    Assert-Equal @($result.Components | Sort-Object) @('browser','codex','docker','graphify','vscode')
    Assert-Equal $result.GitEmail ''
    Assert-Equal $Answers.Count 0
}
Add-Case 'Selected Codex and browser disclose required runtimes before consent' {
    param($directory)
    Set-Answers @('', 'codex', 'browser', 'y', 'Fixture User', 'fixture@example.invalid')
    $result = Read-WorkstationConfiguration -Enable
    Assert-True $result.Enabled
    Assert-Equal @($result.Languages | Sort-Object) @('node','python')
    Assert-Equal @($result.Components | Sort-Object) @('browser','codex')
    Assert-Equal $result.GitName 'Fixture User'
    Assert-Equal $Answers.Count 0
}
Add-Case 'Host JSONC parser preserves URLs, dates, arrays and quoted comment tokens' {
    param($directory)
    $value = Read-Settings '{/* comment */"url":"https://example.invalid/a//b","date":"2026-11-16","quoted":"/*literal*/,}","items":[true,2,],}'
    Assert-Equal $value['url'] 'https://example.invalid/a//b'
    Assert-Equal $value['date'] '2026-11-16'
    Assert-Equal $value['quoted'] '/*literal*/,}'
    Assert-Equal @($value['items']) @($true,2)
    foreach ($bad in @('[]','null','{"unfinished":')) { $null = Assert-Throws { Read-Settings $bad } '' }
}
Add-Case 'Host settings merge preserves declined conflicts and accepts explicit overrides' {
    param($directory)
    $current = Read-Settings '{"editor":{"fontSize":17,"wordWrap":"off"},"privateSetting":"keep"}'
    $defaults = Read-Settings '{"editor":{"fontSize":14,"wordWrap":"on","tabSize":4}}'
    Set-Answers @('','y')
    Merge-VSCodeSettings $current $defaults
    Assert-Equal $current['editor']['fontSize'] 17
    Assert-Equal $current['editor']['wordWrap'] 'on'
    Assert-Equal $current['editor']['tabSize'] 4
    Assert-Equal $current['privateSetting'] 'keep'
    Set-Answers @('')
    Merge-VSCodeSettings $current $defaults
    Assert-Equal $current['editor']['fontSize'] 17
    Assert-Equal $Answers.Count 0
}
Add-Case 'Static appearance install is idempotent and rejects modified installed content' {
    param($directory)
    $fixture = New-AppearanceFixture $directory
    . $fixture.Library
    Install-WorkstationAppearance -ExtensionsRoot $fixture.Extensions
    $installed = Join-Path $fixture.Destination 'theme.json'
    $expected = (Get-FileHash -LiteralPath $installed).Hash
    Install-WorkstationAppearance -ExtensionsRoot $fixture.Extensions
    Assert-Equal (Get-FileHash -LiteralPath $installed).Hash $expected
    Write-Fixture $installed 'user-owned modification'
    $null = Assert-Throws { Install-WorkstationAppearance -ExtensionsRoot $fixture.Extensions } 'contents differ'
    Assert-Equal ([IO.File]::ReadAllText($installed)) 'user-owned modification'
}
Add-Case 'Static appearance rejects executable manifest and asset code' {
    param($directory)
    $fixture = New-AppearanceFixture $directory
    . $fixture.Library
    Write-Fixture (Join-Path $fixture.Source 'package.json') '{"publisher":"workstation-local","name":"appearance","version":"0.0.1","main":"index.js"}'
    $null = Assert-Throws { Install-WorkstationAppearance -ExtensionsRoot $fixture.Extensions } 'must not declare main'
    Assert-True (-not (Test-Path -LiteralPath $fixture.Extensions))
    Write-Fixture (Join-Path $fixture.Source 'package.json') '{"publisher":"workstation-local","name":"appearance","version":"0.0.1"}'
    Write-Fixture (Join-Path $fixture.Source 'index.js') 'throw new Error("fixture")'
    $null = Assert-Throws { Install-WorkstationAppearance -ExtensionsRoot $fixture.Extensions } 'Unexpected appearance asset'
    Assert-True (-not (Test-Path -LiteralPath $fixture.Extensions))
}
Add-Case 'Linked settings and appearance destinations are rejected without touching targets' {
    param($directory)
    $target = Join-Path $directory 'target'
    Write-Fixture (Join-Path $target 'sentinel.txt') 'retained'
    $link = Join-Path $directory 'junction'
    $null = New-Item -ItemType Junction -Path $link -Target $target
    $null = Assert-Throws { Assert-CodexPath (Join-Path $link 'config.toml') } 'Linked paths'
    $null = Assert-Throws { Assert-PackerPath (Join-Path $link 'base.vhdx') } 'Linked Packer path'
    $fixture = New-AppearanceFixture $directory
    . $fixture.Library
    $null = Assert-Throws { Install-WorkstationAppearance -ExtensionsRoot (Join-Path $link 'extensions') } 'Linked appearance path'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $target 'sentinel.txt'))) 'retained'
    Assert-Equal @(Get-ChildItem -LiteralPath $target).Count 1
}
Add-Case 'Codex JSON conversion preserves case-sensitive keys on both shells' {
    param($directory)
    $value = ConvertFrom-CodexJSON '{"A":1,"a":2}'
    Assert-Equal $value.Count 2
    Assert-Equal $value['A'] 1
    Assert-Equal $value['a'] 2
}
Add-Case 'Codex writes reviewed defaults atomically through the versioned config API' {
    param($directory)
    Set-Answers @()
    $fixture = New-ConfigScenario $directory @{} @{}
    Invoke-ConfigScenario $fixture
    $edits = @(Read-ConfigEdits $fixture)
    Assert-Equal @($edits | ForEach-Object { $_['keyPath'] } | Sort-Object) @('approval_policy','features.prefer_mxc','sandbox_mode','windows.sandbox')
    Assert-Equal ($edits | Where-Object { $_['keyPath'] -eq 'sandbox_mode' } | ForEach-Object { $_['value'] }) 'workspace-write'
    $expected = @{sandbox_mode='workspace-write';approval_policy='on-request';'features.prefer_mxc'=$true;'windows.sandbox'='elevated'}
    foreach ($edit in $edits) { Assert-Equal $edit['value'] $expected[$edit['keyPath']] }
    Assert-True (Test-Path -LiteralPath $fixture.exited)
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture.directory 'workstation-backups')).Count 1
}
Add-Case 'Permission profiles in global, named and additional layers suppress sandbox_mode' {
    param($directory)
    $variants = @(@{default_permissions='fixture'}, @{permissions=@{fixture=@{}}}, @{profiles=@{named=@{default_permissions='fixture'}}})
    $index = 0
    foreach ($variant in $variants) {
        $fixture = New-ConfigScenario (Join-Path $directory ([string]$index++)) $variant @{}
        Invoke-ConfigScenario $fixture
        Assert-True ('sandbox_mode' -notin @((Read-ConfigEdits $fixture) | ForEach-Object { $_['keyPath'] }))
    }
    $fixture = New-ConfigScenario (Join-Path $directory 'layer') @{} @{}
    $fixture.read.layers += @{name=@{type='project';file='fixture-project';profile=$null};config=@{permissions=@{fixture=@{}}};version='other'}
    Invoke-ConfigScenario $fixture
    Assert-True ('sandbox_mode' -notin @((Read-ConfigEdits $fixture) | ForEach-Object { $_['keyPath'] }))
}
Add-Case 'Already-correct Codex defaults produce no writes, prompts or backups' {
    param($directory)
    $layer = @{sandbox_mode='workspace-write';approval_policy='on-request';features=@{prefer_mxc=$true};windows=@{sandbox='elevated'}}
    $fixture = New-ConfigScenario $directory @{} $layer
    Set-Answers @()
    Invoke-ConfigScenario $fixture
    Assert-True (-not (Test-Path -LiteralPath $fixture.capture))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.directory 'workstation-backups')))
    Assert-True (Test-Path -LiteralPath $fixture.exited)
}
Add-Case 'Declined Codex conflicts do not create writes or backups' {
    param($directory)
    $layer = @{sandbox_mode='read-only';approval_policy='never';features=@{prefer_mxc=$false};windows=@{sandbox='unelevated'}}
    $fixture = New-ConfigScenario $directory @{} $layer
    $hash = (Get-FileHash -LiteralPath $fixture.path).Hash
    Set-Answers @('','','','')
    Invoke-ConfigScenario $fixture
    Assert-True (-not (Test-Path -LiteralPath $fixture.capture))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.directory 'workstation-backups')))
    Assert-Equal (Get-FileHash -LiteralPath $fixture.path).Hash $hash
    Assert-Equal $Answers.Count 0
}
Add-Case 'Config API rejects stale writes without leaking its error payload' {
    param($directory)
    $fixture = New-ConfigScenario $directory @{} @{}
    $fixture.rejectWrite = $true
    $errorText = Assert-Throws { Invoke-ConfigScenario $fixture } 'code 409'
    Assert-True ($errorText -notmatch 'synthetic-private-marker')
    Assert-True (Test-Path -LiteralPath $fixture.exited)
}
Add-Case 'Unexpected authentication requests abort host setup' {
    param($directory)
    $fixture = New-ConfigScenario $directory @{} @{}
    $fixture.serverRequest = $true
    $null = Assert-Throws { Invoke-ConfigScenario $fixture } 'Unexpected server request'
    Assert-True (-not (Test-Path -LiteralPath $fixture.capture))
    Assert-True (Test-Path -LiteralPath $fixture.exited)
}
Add-Case 'Codex backup refuses a file changed after review' {
    param($directory)
    $path = Join-Path $directory 'config.toml'
    Write-Fixture $path 'before'
    $hash = Get-CodexFileHash $path
    Write-Fixture $path 'after'
    $null = Assert-Throws { Backup-CodexFile $path $hash } 'changed during review'
    Assert-Equal ([IO.File]::ReadAllText($path)) 'after'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $directory 'workstation-backups')))
}
Add-Case 'Managed instructions preserve foreign content, decline and reject broken markers' {
    param($directory)
    Write-Fixture (Join-Path $directory 'AGENTS.md') 'Foreign instructions.'
    Set-Answers @('n')
    Set-CodexInstructions $directory
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $directory 'AGENTS.md'))) 'Foreign instructions.'
    Set-Answers @('y')
    Set-CodexInstructions $directory
    $text = [IO.File]::ReadAllText((Join-Path $directory 'AGENTS.md'))
    Assert-True ($text.StartsWith('Foreign instructions.'))
    Assert-True ($text.Contains('Synthetic Workstation instructions.'))
    Set-Answers @()
    Set-CodexInstructions $directory
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $directory 'AGENTS.md'))) $text
    Write-Fixture (Join-Path $directory 'AGENTS.md') '<!-- workstation:windows:begin -->broken'
    $null = Assert-Throws { Set-CodexInstructions $directory } 'incomplete/duplicate'
}
Add-Case 'Windows answer XML escapes synthetic values and retains token-shaped password text' {
    param($directory)
    $password = 'Fixture<&__TOKEN__"'
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        $credential = New-Object Management.Automation.PSCredential('fixture<&', $secure)
        [xml]$xml = New-WindowsAnswerXml $credential ('a' * 32) 64
        $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        $values = @($xml.SelectNodes('//u:Password/u:Value', $ns) | ForEach-Object { $_.InnerText })
        Assert-True ($password -in $values)
        $null = Assert-Throws { New-WindowsAnswerXml $credential 'bad-token' 64 } 'Invalid Windows setup'
        $null = Assert-Throws { New-WindowsAnswerXml $credential ('a' * 32) 63 } 'Invalid Windows setup'
    } finally { $secure.Dispose() }
}

Add-Case 'Terminal default profile preserves comments, nested settings and idempotency' {
    param($directory)
    $original = '{/*keep*/"nested":{"defaultProfile":"nested"},"defaultProfile":"old","url":"https://example.invalid/a//b",}'
    $expected = $original.Replace('"defaultProfile":"old"', '"defaultProfile":"{b3de38ac-e576-41d4-a1a4-375df22409f4}"')
    Assert-Equal (Set-DefaultTerminalProfile $original) $expected
    Assert-Equal (Set-DefaultTerminalProfile $expected) $expected
    $added = Read-Settings (Set-DefaultTerminalProfile '{/*keep*/"other":17}')
    Assert-Equal $added['other'] 17
    Assert-Equal $added['defaultProfile'] '{b3de38ac-e576-41d4-a1a4-375df22409f4}'
    foreach ($bad in @('[]','{"defaultProfile":false}','{"defaultProfile":"a","defaultProfile":"b"}','{"nested":{]')) {
        $null = Assert-Throws { Set-DefaultTerminalProfile $bad } ''
    }
}
Add-Case 'Terminal file updates preserve identical bytes and leave no temporary files' {
    param($directory)
    $settingsDirectory = Join-Path $directory 'settings'
    $null = [IO.Directory]::CreateDirectory($settingsDirectory)
    $path = Join-Path $settingsDirectory 'settings.json'
    Write-ChangedText $path '{"fixture":1}'
    $stamp = [datetime]::SpecifyKind([datetime]'2020-01-01', [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($path, $stamp)
    Write-ChangedText $path '{"fixture":1}'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($path).Ticks) $stamp.Ticks
    Write-ChangedText $path '{"fixture":2}'
    Assert-Equal ([IO.File]::ReadAllText($path)) '{"fixture":2}'
    Assert-Equal @(Get-ChildItem -LiteralPath $settingsDirectory -Force).Count 1
}
Add-Case 'Dispatcher help and invalid arguments terminate before external operations' {
    param($directory)
    $dispatcher = Join-Path $Repository 'host/windows/wvm/wvm.ps1'
    $help = (& $dispatcher help | Out-String)
    Assert-True ($help.Contains('wvm doctor') -and $help.Contains('wvm stop NAME'))
    $null = Assert-Throws { & $dispatcher doctor -Force } 'not supported for doctor'
    $null = Assert-Throws { & $dispatcher start } 'exact VM name'
    $null = Assert-Throws { & $dispatcher stop fixture -Force } 'Force applies only to delete'
    $null = Assert-Throws { & $dispatcher create -WhatIf } 'not supported for create'
    $null = Assert-Throws { & $dispatcher setup terminal -CPUs 4 } 'not supported for wvm setup'
}
Add-Case 'Doctor refuses unrelated metadata and distinguishes unavailable from mismatched probes' {
    param($directory)
    $path = Join-Path $directory 'ubuntu-vm.json'
    Write-Fixture $path '{"Schema":1,"Name":"fixture"}'
    Assert-Equal (Read-DoctorRecord $path).Name 'fixture'
    $unrelated = Join-Path $directory 'unrelated.json'
    Write-Fixture $unrelated '{"fixture":true}'
    $null = Assert-Throws { Read-DoctorRecord $unrelated } 'Not a diagnostic metadata file'
    Write-Fixture $path '{broken'
    $null = Assert-Throws { Read-DoctorRecord $path } 'invalid JSON'
    $report = @{Findings=(New-Object 'Collections.Generic.List[object]')}
    Invoke-DoctorProbe $report Fixture { throw 'provider unavailable' }
    Invoke-DoctorProbe $report Fixture { throw (New-Object IO.InvalidDataException('known mismatch')) }
    Assert-Equal @($report.Findings | ForEach-Object { $_.Status }) @('UNKNOWN','WARN')
    Assert-Equal (Get-DoctorCounterDelta 4294967290 4) 10.0
}
