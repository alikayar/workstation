#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Address,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]{0,30}$')][string]$UserName,
    [Parameter(Mandatory)][string]$IdentityFile,
    [Parameter(Mandatory)][string]$FinalizerPath,
    [ValidatePattern('^[^"\r\n]+$')][string]$KnownHostsFile,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$InstallationId
)
$ErrorActionPreference = 'Stop'
if ($UserName -eq 'root') { throw 'Use the development account.' }
$ssh = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source
$options = @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=ask', '-o', 'ConnectTimeout=15')
if ($KnownHostsFile) { $options += @('-o', ('UserKnownHostsFile="' + [IO.Path]::GetFullPath($KnownHostsFile).Replace('\', '/') + '"')) }
$target = "$UserName@$Address"
# Verify guest ownership and SSH host identity before prompting or uploading.
& $ssh @options $target "test `"`$(cat /etc/workstation-bootstrap-id)`" = '$InstallationId' || exit 20; if test `"`$(cat /var/lib/workstation/account-ready 2>/dev/null)`" = '$InstallationId' && test ! -e /etc/sudoers.d/90-workstation; then if sudo -kn true 2>/dev/null; then exit 22; else exit 0; fi; else sudo -n true || exit 21; exit 10; fi"
if ($LASTEXITCODE -eq 0) { return }
if ($LASTEXITCODE -ne 10) { throw 'Guest ownership, SSH access or bootstrap sudo could not be confirmed. No account changes were attempted.' }
$remote = ".local/state/workstation-bootstrap/$InstallationId/finalize-account.sh"
$temporary = [IO.Path]::GetTempFileName()
try {
    # Public program code only. Passwords never enter PowerShell or local files.
    $script = [IO.File]::ReadAllText($FinalizerPath).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($temporary, $script, (New-Object Text.UTF8Encoding($false)))
    & scp.exe @options $temporary "${target}:$remote"
    if ($LASTEXITCODE -ne 0) { throw 'Could not upload account finalization code.' }
} finally { Remove-Item -LiteralPath $temporary -Force }
Write-Host "Ubuntu will now ask for the $UserName console/sudo password. SSH password login stays disabled."
& $ssh -t @options $target "sudo -n sh $remote $UserName $InstallationId"
if ($LASTEXITCODE -ne 0) { throw 'Account finalization did not finish. Rerun setup to resume; the VM was preserved.' }
& $ssh @options $target "test `"`$(cat /var/lib/workstation/account-ready)`" = '$InstallationId' && test ! -e /etc/sudoers.d/90-workstation || exit 20; if sudo -kn true 2>/dev/null; then exit 22; else exit 0; fi"
if ($LASTEXITCODE -ne 0) { throw 'Account finalization could not be verified.' }
Write-Host 'Ubuntu account ready. Use your password for sudo; root remains locked.'
