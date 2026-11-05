function Read-WorkstationConfiguration([switch]$Enable) {
    $enabled=[bool]$Enable
    if(-not $Enable){
        do { $answer=(Read-Host 'Install the Workstation development environment too? [Y/n]').Trim() } while($answer -notmatch '^(|y|yes|n|no)$')
        $enabled=$answer -match '^(|y|yes)$'
    }
    $name='';$email=''
    if($enabled){
        do { $name=(Read-Host 'Git author name').Trim() } while(-not $name -or $name -match '[\r\n]')
        do { $email=(Read-Host 'Git author email').Trim() } while($email -notmatch '^[^\s@]+@[^\s@]+$')
    }
    [pscustomobject]@{Enabled=$enabled;State='Pending';GitName=$name;GitEmail=$email;SourceHash=''}
}

function New-WorkstationBundle([string]$Path) {
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){throw 'Git is required to package this checkout.'}
    $files=@(& git.exe -C $repository -c core.quotepath=false ls-files -- ansible dotfiles ansible.cfg)
    if($LASTEXITCODE -ne 0){throw 'Could not list the checkout source files.'}
    if('ansible/site.yml' -notin $files -or 'ansible.cfg' -notin $files){throw 'Workstation playbook/configuration is missing.'}
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($name in @($files)+@('configure-workstation.py')){
            if($name -eq 'ansible/host_vars/localhost.yml'){continue}
            if($name -match '(^/|\\|(^|/)\.\.(/|$)|[\r\n])'){throw 'Invalid source archive path.'}
            $source=if($name -eq 'configure-workstation.py'){Join-Path $PSScriptRoot $name}else{Join-Path $repository $name}
            Assert-PackerPath $source
            if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Tracked source file is missing: $name"}
            # These source trees contain UTF-8 configuration/program text; Linux needs LF.
            $text=[IO.File]::ReadAllText($source).Replace([string][char]13+[char]10,[string][char]10)
            $bytes=[Text.Encoding]::UTF8.GetBytes($text)
            $entry=$archive.CreateEntry($name)
            $stream=$entry.Open()
            try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
        }
    }finally{$archive.Dispose()}
}

function Invoke-UbuntuWorkstation([object]$Record) {
    if(-not $Record.Workstation.Enabled -or $Record.Workstation.State -eq 'Complete'){return}
    $directory=Join-Path $Record.Root 'workstation'
    Assert-PackerPath $directory
    if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory|Out-Null}
    $bundle=Join-Path $directory 'source.zip'
    if(-not $Record.Workstation.SourceHash){
        if(Test-Path -LiteralPath $bundle){throw 'Unrecorded source bundle retained; inspect before retrying.'}
        $temporary=$bundle+'.partial'
        try{
            New-WorkstationBundle $temporary
            [IO.File]::Move($temporary,$bundle)
        }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
        $Record.Workstation.SourceHash=(Get-FileHash -LiteralPath $bundle).Hash.ToLowerInvariant()
        Save-WVMRecord $Record
    }
    if((Get-FileHash -LiteralPath $bundle).Hash -ine $Record.Workstation.SourceHash){throw 'Recorded Workstation source bundle changed.'}
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($bundle)
    $runner=Join-Path $directory 'configure-workstation.py'
    try{
        $entry=$archive.GetEntry('configure-workstation.py')
        if(-not $entry){throw 'Bundle runner is missing.'}
        $reader=New-Object IO.StreamReader($entry.Open())
        try{Save-PackerText $runner $reader.ReadToEnd()}finally{$reader.Dispose()}
    }finally{$archive.Dispose()}
    $ssh=Join-Path ([Environment]::SystemDirectory) 'OpenSSH\ssh.exe'
    $scp=Join-Path ([Environment]::SystemDirectory) 'OpenSSH\scp.exe'
    $known=Join-Path $Record.Root 'known_hosts'
    $options=@('-F','NUL','-i',(Join-Path $Record.Root 'ssh-ed25519'),'-o','BatchMode=yes','-o','IdentityAgent=none','-o','IdentitiesOnly=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','PermitLocalCommand=no','-o','StrictHostKeyChecking=yes','-o',('HostKeyAlias=workstation-ubuntu-'+$Record.Token),'-o',('UserKnownHostsFile="'+$known.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=NUL','-o','ConnectTimeout=15')
    $target=$Record.UserName+'@'+$Record.Address
    $remote='.local/state/workstation-bootstrap/'+$Record.Token+'/configure'
    $verify='test "$(cat /etc/workstation-bootstrap-id)" = ''{0}'' && umask 077 && mkdir -p ''{1}''' -f $Record.Token,$remote
    & $ssh @options $target $verify
    if($LASTEXITCODE){throw 'Guest identity could not be verified before Workstation configuration.'}
    & $scp @options $bundle ($target+':'+$remote+'/source.zip')
    if($LASTEXITCODE){throw 'Workstation source upload failed; VM retained.'}
    & $scp @options $runner ($target+':'+$remote+'/configure-workstation.py')
    if($LASTEXITCODE){throw 'Workstation runner upload failed; VM retained.'}
    $settings=@{git_user_name=$Record.Workstation.GitName;git_user_email=$Record.Workstation.GitEmail}|ConvertTo-Json -Compress
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings))
    $Record.Workstation.State='Running';Save-WVMRecord $Record
    Write-Host 'Configuring Workstation inside Ubuntu. Enter your sudo password in the guest prompt.'
    $command="python3 '$remote/configure-workstation.py' '$remote/source.zip' '$($Record.Workstation.SourceHash)' '$($Record.Token)' '$encoded'"
    & $ssh -t @options $target $command
    if($LASTEXITCODE){throw 'Workstation configuration stopped; the VM is ready. Retry with wvm configure VM_NAME.'}
    $Record.Workstation.State='Complete';Save-WVMRecord $Record
    Write-Host 'Workstation configuration completed. Open a new SSH session for shell/group changes.'
}
