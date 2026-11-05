function New-WVMWindowsBaseAnswer([object]$Record) {
    [xml]$xml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Autounattend.xml')).Replace('__COMPUTER_SUFFIX__',$Record.Token.Substring(0,12)).Replace('__TOKEN__',$Record.Token)
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    $accounts = $xml.SelectSingleNode('//u:UserAccounts',$ns)
    $null = $accounts.ParentNode.RemoveChild($accounts)
    # Recovery precedes C: so independent clones can expand their final Windows partition.
    $xml.SelectSingleNode('//u:CreatePartition[u:Order="3"]/u:Size',$ns).InnerText = '1024'
    $xml.SelectSingleNode('//u:ModifyPartition[u:Label="Windows"]/u:PartitionID',$ns).InnerText = '4'
    $xml.SelectSingleNode('//u:ModifyPartition[u:Label="Recovery"]/u:PartitionID',$ns).InnerText = '3'
    $xml.SelectSingleNode('//u:InstallTo/u:PartitionID',$ns).InnerText = '4'
    $sync=$xml.SelectSingleNode('//u:settings[@pass="specialize"]//u:RunSynchronous',$ns)
    $store=$xml.CreateElement('RunSynchronousCommand',$ns.LookupNamespace('u'))
    $null=$store.SetAttribute('action','http://schemas.microsoft.com/WMIConfig/2002/State','add')
    $store.InnerXml='<Order xmlns="urn:schemas-microsoft-com:unattend">2</Order><Path xmlns="urn:schemas-microsoft-com:unattend">reg.exe add HKLM\SOFTWARE\Policies\Microsoft\WindowsStore /v AutoDownload /t REG_DWORD /d 2 /f</Path>'
    $null=$sync.AppendChild($store)
    $oobe = $xml.SelectSingleNode('//u:settings[@pass="oobeSystem"]',$ns)
    $component = $xml.CreateElement('component',$ns.LookupNamespace('u'))
    foreach ($pair in @{name='Microsoft-Windows-Deployment';processorArchitecture='amd64';publicKeyToken='31bf3856ad364e35';language='neutral';versionScope='nonSxS'}.GetEnumerator()) { $component.SetAttribute($pair.Key,$pair.Value) }
    $component.InnerXml = '<Reseal xmlns="urn:schemas-microsoft-com:unattend"><Mode>Audit</Mode></Reseal>'
    $null = $oobe.AppendChild($component)
    $program = @'
$ErrorActionPreference='Stop'
foreach($path in @('C:\Windows\Panther\unattend.xml','C:\Windows\Panther\Unattend\unattend.xml','C:\autounattend.xml')){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
New-Item -ItemType Directory -Path 'C:\ProgramData\Workstation\BaseImage' -Force | Out-Null
[IO.File]::WriteAllText('C:\ProgramData\Workstation\BaseImage\sealed.json','{"ImageID":"__IMAGE_ID__","Token":"__BUILD_TOKEN__"}')
[IO.File]::WriteAllText('C:\Windows\Panther\wvm-reseal.xml','<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem"><component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><Reseal><Mode>OOBE</Mode></Reseal></component></settings></unattend>')
$process=Start-Process 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /mode:vm /quiet /unattend:C:\Windows\Panther\wvm-reseal.xml' -Wait -PassThru
if($process.ExitCode -ne 0){throw 'Sysprep failed; image must not be published.'}
'@
    $program = $program.Replace('__IMAGE_ID__',$Record.ImageID).Replace('__BUILD_TOKEN__',$Record.Token)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $audit = $xml.CreateElement('settings',$ns.LookupNamespace('u')); $audit.SetAttribute('pass','auditUser')
    $deployment = $component.CloneNode($false)
    $deployment.InnerXml = '<RunSynchronous xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -EncodedCommand ' + $encoded + '</Path></RunSynchronousCommand></RunSynchronous>'
    $null = $audit.AppendChild($deployment); $null = $xml.DocumentElement.AppendChild($audit)
    return $xml.OuterXml
}

function New-WVMWindowsCloneAnswer([Management.Automation.PSCredential]$Credential, [string]$Token, [int]$DiskGB) {
    [xml]$xml = New-WindowsAnswerXml $Credential $Token $DiskGB
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    $pe = $xml.SelectSingleNode('//u:settings[@pass="windowsPE"]',$ns)
    $null = $pe.ParentNode.RemoveChild($pe)
    $sync = $xml.SelectSingleNode('//u:settings[@pass="specialize"]//u:RunSynchronous',$ns)
    $command = $xml.CreateElement('RunSynchronousCommand',$ns.LookupNamespace('u'))
    $null = $command.SetAttribute('action','http://schemas.microsoft.com/WMIConfig/2002/State','add')
    $program = '$ErrorActionPreference="Stop"; Remove-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore -Name AutoDownload -ErrorAction SilentlyContinue; $p=Get-Partition -DriveLetter C; $s=Get-PartitionSupportedSize -DriveLetter C; if($s.SizeMax -gt $p.Size){Resize-Partition -DriveLetter C -Size $s.SizeMax}'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $command.InnerXml = '<Order xmlns="urn:schemas-microsoft-com:unattend">2</Order><Path xmlns="urn:schemas-microsoft-com:unattend">powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '</Path>'
    $null = $sync.AppendChild($command)
    return $xml.OuterXml
}

function Set-WVMWindowsCloneSeed([object]$Record, [Management.Automation.PSCredential]$Credential) {
    Invoke-WVMWindowsDisk $Record.DiskPath (Join-Path $Record.Root 'seed-mount') -Action {
        param($mount)
        $answer = Join-Path $mount 'Windows\Panther\unattend.xml'
        [IO.File]::WriteAllText($answer, (New-WVMWindowsCloneAnswer $Credential $Record.Token $Record.DiskGB), (New-Object Text.UTF8Encoding($false)))
        # Explicitly replace Sysprep's cached answer-file pointer on this never-booted copy only.
        $key = 'WVMClone-' + $Record.Token
        $hive = Join-Path $mount 'Windows\System32\config\SYSTEM'
        $loaded = $false
        try {
            & "$env:WINDIR\System32\reg.exe" load ('HKLM\'+$key) $hive | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Could not load the virgin clone SYSTEM hive.'}
            $loaded = $true
            Set-ItemProperty ('Registry::HKEY_LOCAL_MACHINE\'+$key+'\Setup') -Name UnattendFile -Value 'C:\Windows\Panther\unattend.xml' -Type String
        } finally {
            if($loaded){
                [GC]::Collect();[GC]::WaitForPendingFinalizers()
                & "$env:WINDIR\System32\reg.exe" unload ('HKLM\'+$key) | Out-Null
                if($LASTEXITCODE -ne 0){throw 'Clone SYSTEM hive remains loaded; VM was not started.'}
            }
        }
    }
}
