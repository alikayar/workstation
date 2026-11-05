#Requires -Version 5.1
<#
.SYNOPSIS
Applies Windows Codex defaults and managed instructions for the current user.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Confirm-CodexChange([string]$Question) {
    while ($true) {
        $answer = (Read-Host "$Question [y/N]").Trim()
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -eq '' -or $answer -match '^(?i:n|no)$') { return $false }
        Write-Host 'Enter y or n; Enter keeps the existing value.'
    }
}

function Assert-CodexPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not modified: $cursor" }
        }
        $cursor = Split-Path -Parent $cursor
    }
}

function Get-CodexFileHash([string]$Path) {
    Assert-CodexPath $Path
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Expected a file: $Path" }
    if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return ''
}

function Backup-CodexFile([string]$Path, [string]$ExpectedHash) {
    if ((Get-CodexFileHash $Path) -cne $ExpectedHash) { throw "File changed during review; rerun setup: $Path" }
    if ($ExpectedHash) {
        $directory = Join-Path (Split-Path -Parent $Path) 'workstation-backups'
        Assert-CodexPath $directory
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $backup = Join-Path $directory ((Split-Path -Leaf $Path) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
        [IO.File]::Copy($Path, $backup, $false)
        Write-Host "Backup: $backup"
    }
}

function ConvertFrom-CodexJSON([string]$Json) {
    # TOML keys are case-sensitive. PSCustomObject JSON conversion is not.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return ConvertFrom-Json -InputObject $Json -AsHashtable
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216
    return $serializer.DeserializeObject($Json)
}

function Invoke-CodexRPC([Diagnostics.Process]$Process, [int]$Id, [string]$Method, $Parameters) {
    $request = @{ id=$Id; method=$Method; params=$Parameters } | ConvertTo-Json -Depth 40 -Compress
    # ASCII JSON also works with the inbox PowerShell/.NET stdin encoding.
    $request = [regex]::Replace($request, '[^\x00-\x7F]', [Text.RegularExpressions.MatchEvaluator]{ param($character) '\u{0:x4}' -f [int][char]$character.Value })
    $Process.StandardInput.WriteLine($request)
    $Process.StandardInput.Flush()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $line = $Process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $line.Wait($remaining)) { throw "Codex config API timed out: $Method" }
        if ($null -eq $line.Result) { throw 'Codex config API closed unexpectedly. Update Codex and retry.' }
        $message = ConvertFrom-CodexJSON $line.Result
        if ($message.ContainsKey('id') -and $message['id'] -eq $Id) {
            if ($message.ContainsKey('error')) {
                # Protocol errors can include configuration contents; do not echo them.
                throw "Codex rejected $Method (code $($message['error']['code'])). Settings may be managed, invalid or changed during review; inspect Codex settings and retry."
            }
            return $message['result']
        }
        if ($message.ContainsKey('id') -and $message.ContainsKey('method')) {
            throw 'Unexpected server request; setup does not authorize authentication or agent actions.'
        }
    }
    throw "Codex config API timed out: $Method"
}

function Set-CodexConfig([string]$Executable, [string]$CodexHome) {
    $configPath = Join-Path $CodexHome 'config.toml'
    $originalHash = Get-CodexFileHash $configPath
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = 'app-server'
    $start.WorkingDirectory = $env:USERPROFILE
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Cannot start Codex config API.' }
        $started = $true
        # Drain stderr without logging it: third-party config may contain private values.
        $stderr = $process.StandardError.ReadToEndAsync()
        $null = Invoke-CodexRPC $process 1 'initialize' @{ clientInfo=@{ name='workstation_setup'; version='1.0.0' } }
        $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $read = Invoke-CodexRPC $process 2 'config/read' @{ includeLayers=$true }
        $layers = @($read['layers'] | Where-Object {
            $source = $_['name']
            return $source['type'] -eq 'user' -and [IO.Path]::GetFullPath($source['file']) -ieq $configPath -and -not $source['profile']
        })
        if ($layers.Count -ne 1) { throw 'Codex did not return one base user configuration layer; no settings were changed.' }
        $layer = $layers[0]
        $defaults = [ordered]@{
            'sandbox_mode'='workspace-write'
            'approval_policy'='on-request'
            'features.prefer_mxc'=$true
            'windows.sandbox'='elevated'
        }
        $edits = @()
        foreach ($key in $defaults.Keys) {
            $current = $layer['config']
            foreach ($segment in $key.Split('.')) {
                $current = if ($current -is [Collections.IDictionary] -and $current.ContainsKey($segment)) { $current[$segment] } else { $null }
            }
            $desired = $defaults[$key]
            if (($current | ConvertTo-Json -Depth 20 -Compress) -ceq ($desired | ConvertTo-Json -Compress)) {
                Write-Host "Unchanged: $key"
                continue
            }
            if ($null -ne $current) {
                Write-Host ("Conflict: {0}; current={1}; proposed={2}" -f $key, ($current | ConvertTo-Json -Depth 20 -Compress), ($desired | ConvertTo-Json -Compress))
                if (-not (Confirm-CodexChange "Override ${key}?")) { continue }
            }
            $edits += @{ keyPath=$key; value=$desired; mergeStrategy='replace' }
        }
        if ($edits.Count) {
            Backup-CodexFile $configPath $originalHash
            $null = Invoke-CodexRPC $process 3 'config/batchWrite' @{ edits=$edits; filePath=$configPath; expectedVersion=$layer['version'] }
            Write-Host 'Updated Windows Codex defaults.'
        } else { Write-Host 'Codex configuration preserved.' }
    } finally {
        if ($started) {
            if (-not $process.HasExited) {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(3000)) { $process.Kill(); $process.WaitForExit() }
            }
        }
        $process.Dispose()
    }
}

function Set-CodexInstructions([string]$CodexHome) {
    $path = Join-Path $CodexHome 'AGENTS.md'
    $hash = Get-CodexFileHash $path
    $existing = if ($hash) { [IO.File]::ReadAllText($path) } else { '' }
    $instructions = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Instructions.md')).Trim()
    $begin = '<!-- workstation:windows:begin -->'
    $end = '<!-- workstation:windows:end -->'
    $block = "$begin`r`n$instructions`r`n$end"
    $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $matches = [regex]::Matches($existing, $pattern)
    if ($matches.Count -gt 1 -or ([regex]::Matches($existing, [regex]::Escape($begin)).Count -ne $matches.Count) -or ([regex]::Matches($existing, [regex]::Escape($end)).Count -ne $matches.Count)) {
        throw 'AGENTS.md contains incomplete/duplicate Workstation markers; retained for manual review.'
    }
    if ($matches.Count -eq 1) {
        if ($matches[0].Value.Replace("`r`n", "`n") -ceq $block.Replace("`r`n", "`n")) { Write-Host 'Unchanged: Codex instructions'; return }
        $proposed = $existing.Substring(0, $matches[0].Index) + $block + $existing.Substring($matches[0].Index + $matches[0].Length)
    } else { $proposed = $existing + $(if ($existing) { "`r`n`r`n" } else { '' }) + $block + "`r`n" }
    if ($existing.Trim()) {
        Write-Host "Proposed Workstation instruction block:`n$instructions"
        if (-not (Confirm-CodexChange 'Update the Workstation block in AGENTS.md, preserving other instructions?')) { return }
    }
    Backup-CodexFile $path $hash
    $temporary = Join-Path $CodexHome ('instructions-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $proposed, (New-Object Text.UTF8Encoding($false)))
    if ((Get-CodexFileHash $path) -cne $hash) { throw "AGENTS.md changed during review; proposed file retained at $temporary" }
    if ($hash) { [IO.File]::Replace($temporary, $path, [NullString]::Value) } else { [IO.File]::Move($temporary, $path) }
    Write-Host 'Updated Codex instructions.'
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Run Codex setup in 64-bit PowerShell on Windows 11 x64.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run wvm setup codex in a normal PowerShell window.' }
$codex = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $codex) { throw 'Codex CLI was not found. Install/open the Codex desktop app, enable its CLI on PATH, then rerun wvm setup codex.' }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if ($codexHome -notmatch '^(?:[A-Za-z]:[\\/]|[\\]{2}[^\\/]+[\\/][^\\/]+)') { throw 'CODEX_HOME must be a fully qualified path, not a drive-relative or root-relative path.' }
$codexHome = [IO.Path]::GetFullPath($codexHome)
Assert-CodexPath $codexHome
[IO.Directory]::CreateDirectory($codexHome) | Out-Null
$lockPath = Join-Path $codexHome 'workstation-setup.lock'
Assert-CodexPath $lockPath
$lock = $null
try {
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Write-Host "Codex found: $($codex.Source)"
    Set-CodexConfig $codex.Source $codexHome
    Set-CodexInstructions $codexHome
    Write-Host 'Codex setup completed. Open a new chat to load the updated configuration and instructions.'
    Write-Host 'For VM work: in Codex Settings > Connections, enable the existing SSH alias and select the remote repository folder.'
} finally {
    if ($lock) { $lock.Dispose() }
}
