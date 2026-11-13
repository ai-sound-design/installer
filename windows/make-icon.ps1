# Draws the installer's icon: a waveform on a rounded square, as the Mac's make-icon.swift,
# as a multi-size .ico (16 to 256 px, PNG-compressed entries).
#   powershell -File make-icon.ps1 <out.ico>
param([Parameter(Mandatory = $true)][string]$Out)

Add-Type -AssemblyName System.Drawing

function Draw-Png([int]$size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # The shape inset a little, corners of about 22 %
    $inset = [math]::Round($size * 0.04)
    $side = $size - 2 * $inset
    $radius = [math]::Max(2, [math]::Round($side * 0.22))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($inset, $inset, $d, $d, 180, 90)
    $path.AddArc($inset + $side - $d, $inset, $d, $d, 270, 90)
    $path.AddArc($inset + $side - $d, $inset + $side - $d, $d, $d, 0, 90)
    $path.AddArc($inset, $inset + $side - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, $size), (New-Object System.Drawing.Point $size, 0), ([System.Drawing.Color]::FromArgb(41, 51, 133)), ([System.Drawing.Color]::FromArgb(122, 61, 199))
    $g.FillPath($brush, $path)
    # The waveform: bars of different heights, round ends
    $heights = @(0.22, 0.52, 0.22, 0.76, 0.38, 0.62, 0.16)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([math]::Max(1.5, $size * 0.075))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $gap = $side * 0.12
    $x0 = $inset + ($side - $gap * ($heights.Count - 1)) / 2
    for ($i = 0; $i -lt $heights.Count; $i++) {
        $h = $side * $heights[$i]
        $x = $x0 + $i * $gap
        $g.DrawLine($pen, [float]$x, [float]($size / 2 - $h / 2), [float]$x, [float]($size / 2 + $h / 2))
    }
    $g.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    # The comma keeps the byte array in one piece on the pipeline
    return ,$stream.ToArray()
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($s in $sizes) { $images.Add([byte[]](Draw-Png $s)) }
$file = [System.IO.File]::Create($Out)
$writer = New-Object System.IO.BinaryWriter $file
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $side = [byte]$(if ($s -ge 256) { 0 } else { $s })
    $writer.Write($side); $writer.Write($side)
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($png in $images) { $writer.Write([byte[]]$png) }
$writer.Flush(); $file.Close()
Write-Output $Out
