# Generates the 1024x1024 app icon (GR-inspired, matte black / white / red).
# Run from Windows PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make-icon.ps1

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "LivePhotoMaker\Assets.xcassets\AppIcon.appiconset"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outPath = Join-Path $outDir "AppIcon-1024.png"

$size = 1024
$bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

try {
    # Matte black background with a subtle top-to-bottom gradient
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $topColor = [System.Drawing.Color]::FromArgb(255, 28, 28, 28)
    $bottomColor = [System.Drawing.Color]::FromArgb(255, 3, 3, 3)
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $topColor, $bottomColor, 90.0)
    $g.FillRectangle($bgBrush, $rect)
    $bgBrush.Dispose()

    # Faint concentric lens rings
    $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 48, 48, 48), 14)
    $g.DrawEllipse($ringPen, 168, 168, 688, 688)
    $ringPen.Dispose()

    $innerRingPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 27, 27, 27), 8)
    $g.DrawEllipse($innerRingPen, 216, 216, 592, 592)
    $innerRingPen.Dispose()

    # GR wordmark
    $fonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    $family = if ($fonts -contains "Arial Black") { "Arial Black" } else { "Segoe UI" }
    $grFont = New-Object System.Drawing.Font($family, 310, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 245, 245))
    $center = New-Object System.Drawing.StringFormat
    $center.Alignment = [System.Drawing.StringAlignment]::Center
    $center.LineAlignment = [System.Drawing.StringAlignment]::Center
    $grRect = New-Object System.Drawing.RectangleF(0, 300, 1024, 360)
    $g.DrawString("GR", $grFont, $whiteBrush, $grRect, $center)

    # Red accent bar under the wordmark
    $red = [System.Drawing.Color]::FromArgb(255, 230, 0, 18)
    $barWidth = 250
    $barHeight = 26
    $barX = (1024 - $barWidth) / 2
    $barY = 672
    $radius = 13
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($barX, $barY, $d, $d, 180, 90)
    $path.AddArc($barX + $barWidth - $d, $barY, $d, $d, 270, 90)
    $path.AddArc($barX + $barWidth - $d, $barY + $barHeight - $d, $d, $d, 0, 90)
    $path.AddArc($barX, $barY + $barHeight - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $redBrush = New-Object System.Drawing.SolidBrush($red)
    $g.FillPath($redBrush, $path)
    $redBrush.Dispose()
    $path.Dispose()

    $grFont.Dispose()
    $whiteBrush.Dispose()
    $center.Dispose()

    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "Icon written to $outPath"
}
finally {
    $g.Dispose()
    $bmp.Dispose()
}
