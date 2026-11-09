# Makes windows\ClaudeMultiAccounts\Resources\AppIcon.ico from assets\icon\AppIcon-1024.png:
# one PNG-compressed image per size, which Windows reads for every size it shows.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'assets\icon\AppIcon-1024.png'
$target = Join-Path $root 'windows\ClaudeMultiAccounts\Resources\AppIcon.ico'
New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$original = [System.Drawing.Image]::FromFile($source)
$images = foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($original, 0, 0, $size, $size)
    $g.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    , $stream.ToArray()
}
$original.Dispose()

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $data = $images[$i]
    $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$data.Length); $w.Write([UInt32]$offset)
    $offset += $data.Length
}
foreach ($data in $images) { $w.Write($data) }
$w.Flush()
[System.IO.File]::WriteAllBytes($target, $out.ToArray())
"Wrote $target ($($out.Length) bytes)"
