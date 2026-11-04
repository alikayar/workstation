# Shared ISO creation without an external utility or Windows ADK installation.
function New-VMSeedISO([string]$Directory, [string]$Destination) {
    if (-not ('WorkstationImageStream' -as [type])) {
        Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class WorkstationImageStream {
    public static void Save(object image, string path) {
        IStream stream = (IStream)image;
        IntPtr count = Marshal.AllocCoTaskMem(4);
        try {
            using (FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.Write)) {
                byte[] buffer = new byte[65536];
                while (true) {
                    stream.Read(buffer, buffer.Length, count);
                    int read = Marshal.ReadInt32(count);
                    if (read == 0) break;
                    file.Write(buffer, 0, read);
                }
            }
        } finally { Marshal.FreeCoTaskMem(count); }
    }
}
'@
    }
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $result = $null
    $stream = $null
    try {
        $image.FileSystemsToCreate = 3
        $image.VolumeName = 'CIDATA'
        $image.Root.AddTree($Directory, $false)
        $result = $image.CreateResultImage()
        $stream = $result.ImageStream
        [WorkstationImageStream]::Save($stream, $temporary)
        Move-Item -LiteralPath $temporary -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        foreach ($item in @($stream, $result, $image)) { if ($null -ne $item) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) } }
    }
}
