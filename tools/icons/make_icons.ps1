<#
Draws the destination icon layers: a white disc that data.lua tints per destination, and number
badges 1..20. 0.10.1 (Steve): the number sits TOP LEFT, because Factorio prints the item count
bottom right (0.10.0 tried bottom left, and "17" still met a count like "260"). Replaces make_icons.py (Pillow isn't installed here).

  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\icons\make_icons.ps1 [-Preview <png>]

-Preview also writes a sheet of composited icons (disc tint + picture + number + a sample
"260" count, at 2x) so the layout can be checked without starting the game.
#>
param([string]$Preview)
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out = Join-Path $root "freight-dispatch\graphics\dest"
New-Item -ItemType Directory -Force $out | Out-Null
$S = 64; $B = $S * 4

function New-Canvas { $bmp = New-Object System.Drawing.Bitmap $B, $B, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = "AntiAlias"; $g.Clear([System.Drawing.Color]::Transparent); return $bmp, $g }
function Save-Down($bmp, $path) {
  $small = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($small); $g.InterpolationMode = "HighQualityBicubic"; $g.PixelOffsetMode = "HighQuality"
  $g.Clear([System.Drawing.Color]::Transparent); $g.DrawImage($bmp, 0, 0, $S, $S); $g.Dispose()
  $small.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $small.Dispose() }

# disc: grey rim, white face (tinted in data.lua)
$bmp, $g = New-Canvas
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 150, 150))), 4, 4, $B - 9, $B - 9)
$g.FillEllipse([System.Drawing.Brushes]::White, 20, 20, $B - 41, $B - 41)
$g.Dispose(); Save-Down $bmp (Join-Path $out "disc.png"); $bmp.Dispose()

# numbers: white with a thick black outline, bottom left
$family = New-Object System.Drawing.FontFamily "Arial"
for ($n = 1; $n -le 20; $n++) {
  $t = "$n"
  $size = 136 # 0.10.2: two-digit numbers no longer shrink (they were 98 while the number sat bottom left)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddString($t, $family, [int][System.Drawing.FontStyle]::Bold, $size, (New-Object System.Drawing.PointF 0, 0), [System.Drawing.StringFormat]::GenericTypographic)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 38
  $pen.LineJoin = "Round"
  $wide = $path.Clone(); $wide.Widen($pen); $bb = $wide.GetBounds()
  $m = New-Object System.Drawing.Drawing2D.Matrix
  $m.Translate(2 - $bb.X, 2 - $bb.Y)
  $path.Transform($m)
  $bmp, $g = New-Canvas
  $g.DrawPath($pen, $path)
  $g.FillPath([System.Drawing.Brushes]::White, $path)
  $g.Dispose(); Save-Down $bmp (Join-Path $out "num-$n.png"); $bmp.Dispose()
}
"ok $out"

if ($Preview) {
  # composite like data.lua: disc (tinted), picture at layer scale/shift, number; a "260" count
  $cols = @(@(255,80,80),@(255,160,60),@(240,220,60),@(120,210,80),@(60,190,170),@(70,150,255),@(150,110,255),@(230,100,200),@(170,120,80),@(200,200,200))
  $pics = @(@("D:\SteamLibrary\steamapps\common\Factorio\data\core\graphics\icons\entity\character.png", 0.34, 3, 2),
            @((Join-Path $root "freight-dispatch\graphics\mail.png"), 0.3, 3, 3))
  $Z = 128; $sheet = New-Object System.Drawing.Bitmap ($Z * 10 + 20), ($Z * 2 * 2 + 30)
  $sg = [System.Drawing.Graphics]::FromImage($sheet); $sg.Clear([System.Drawing.Color]::FromArgb(255, 49, 48, 49)); $sg.InterpolationMode = "HighQualityBicubic"
  $disc = [System.Drawing.Image]::FromFile((Join-Path $out "disc.png"))
  $font = New-Object System.Drawing.Font "Arial", 22, ([System.Drawing.FontStyle]::Bold)
  $row = 0
  foreach ($pic in $pics) {
    $pimg = [System.Drawing.Image]::FromFile($pic[0])
    foreach ($set in @(@(1..10), @(11..20))) {
      $i = 0
      foreach ($n in $set) {
        $x0 = 10 + $i * $Z; $y0 = 10 + $row * ($Z + 6)
        $c = $cols[($n - 1) % 10]
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = $c[0] / 255; $cm.Matrix11 = $c[1] / 255; $cm.Matrix22 = $c[2] / 255; $cm.Matrix33 = 1; $cm.Matrix44 = 1
        $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
        $sg.DrawImage($disc, (New-Object System.Drawing.Rectangle $x0, $y0, $Z, $Z), 0, 0, 64, 64, "Pixel", $ia)
        # Factorio layer units: the 64 px base layer has scale 0.5, so scale k draws at k/0.5 of the
        # icon and a shift of 1 is 2 px at 64
        $f = $Z / 64; $ps = $Z * $pic[1] / 0.5
        $px = $x0 + ($Z - $ps) / 2 + $pic[2] * 2 * $f; $py = $y0 + ($Z - $ps) / 2 + $pic[3] * 2 * $f
        $sg.DrawImage($pimg, (New-Object System.Drawing.Rectangle ([int]$px), ([int]$py), ([int]$ps), ([int]$ps)), 0, 0, 64, 64, "Pixel")
        $num = [System.Drawing.Image]::FromFile((Join-Path $out "num-$n.png"))
        $sg.DrawImage($num, $x0, $y0, $Z, $Z); $num.Dispose()
        $sz = $sg.MeasureString("260", $font)
        $sg.DrawString("260", $font, [System.Drawing.Brushes]::Black, ($x0 + $Z - $sz.Width + 2), ($y0 + $Z - $sz.Height + 2))
        $sg.DrawString("260", $font, [System.Drawing.Brushes]::White, ($x0 + $Z - $sz.Width), ($y0 + $Z - $sz.Height))
        $i++
      }
      $row++
    }
    $pimg.Dispose()
  }
  $sg.Dispose(); $disc.Dispose(); $sheet.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png); "preview $Preview"
}
