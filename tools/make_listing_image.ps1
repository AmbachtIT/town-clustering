<#
.SYNOPSIS
Renders the mod.io listing image (1920x1080) for Town Clustering.

.DESCRIPTION
This is a stylised illustration of the map view, not a capture of the game.
Nothing here is a screenshot: it is drawn with GDI+ so it can be regenerated
and tweaked. Replace it with a real annotated screenshot once there is one.

Two variants:

  arrows  towns pulled together into clusters - reads as "clustering" at a
          glance, but implies the mod moves towns, which it does not.
  pruned  towns between the clusters struck out and faded - what the mod
          actually does: it removes towns, it never moves them.

.PARAMETER Variant
arrows (default) or pruned.

.PARAMETER OutFile
Where to write the PNG.
#>
[CmdletBinding()]
param(
	[ValidateSet("arrows", "pruned")]
	[string]$Variant = "arrows",
	[string]$OutFile = "$PSScriptRoot\..\mod\town_clustering_1\_metadata\0.png"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$W = 1920
$H = 1080

# The two variants want different map densities. "arrows" needs few enough
# towns that an arrow per town stays readable; "pruned" needs enough of them
# that the survivors around a centre actually look like a town cluster, since
# in that variant nothing moves - towns only disappear.
if ($Variant -eq "pruned") {
	$cols = 12
	$rows = 7
	$KeepRadius = 212.0
	$DotSize = 11.0
	$GhostSize = 9.0
} else {
	$cols = 7
	$rows = 4
	$KeepRadius = 372.0
	$DotSize = 15.0
	$GhostSize = 13.0
}

function New-Colour([string]$Hex, [int]$Alpha = 255) {
	$r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
	$g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
	$b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
	return [System.Drawing.Color]::FromArgb($Alpha, $r, $g, $b)
}

# Map-view palette: muted terrain greens, water teal, warm amber for towns.
$LandTop   = New-Colour "4A6B52"
$LandBot   = New-Colour "26382C"
$Water     = New-Colour "2B5A73"
$WaterEdge = New-Colour "3C7795"
$Town      = New-Colour "F5B95C"
$TownCore  = New-Colour "FFF0D2"
$Ghost     = New-Colour "9FB0A3" 150
$Road      = New-Colour "E4D8BE" 190
$Accent    = New-Colour "E8734A"
$Ink       = New-Colour "F6F3EC"
$InkSoft   = New-Colour "C9D2C6"

$bmp = New-Object System.Drawing.Bitmap $W, $H
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# ---------------------------------------------------------------- land
$rect = New-Object System.Drawing.Rectangle 0, 0, $W, $H
$landBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $LandTop, $LandBot, 70.0
$gfx.FillRectangle($landBrush, $rect)

# Deterministic jitter so the image is reproducible.
$script:seed = 20261001
function Next-Rand {
	$script:seed = ($script:seed * 1103515245 + 12345) % 2147483648
	return $script:seed / 2147483648.0
}

# Soft terrain blotches, to stop the gradient reading as flat paper.
for ($i = 0; $i -lt 90; $i++) {
	$cx = (Next-Rand) * $W
	$cy = 180 + (Next-Rand) * ($H - 180)
	$rr = 70 + (Next-Rand) * 230
	$aa = 8 + [int]((Next-Rand) * 12)
	if ((Next-Rand) -gt 0.45) {
		$col = New-Colour "6E8F72" $aa
	} else {
		$col = New-Colour "1C2A20" $aa
	}
	$br = New-Object System.Drawing.SolidBrush $col
	$gfx.FillEllipse($br, [float]($cx - $rr), [float]($cy - $rr / 1.7), [float]($rr * 2), [float]($rr * 1.18))
	$br.Dispose()
}

# ---------------------------------------------------------------- water
# One river across the frame plus two lakes, so the map reads as a map.
$riverPts = @(
	(New-Object System.Drawing.PointF -40, 430),
	(New-Object System.Drawing.PointF 300, 520),
	(New-Object System.Drawing.PointF 640, 470),
	(New-Object System.Drawing.PointF 980, 650),
	(New-Object System.Drawing.PointF 1320, 600),
	(New-Object System.Drawing.PointF 1660, 760),
	(New-Object System.Drawing.PointF 1960, 700)
)
$riverPen = New-Object System.Drawing.Pen $Water, 34
$riverPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$riverPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$riverPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$gfx.DrawCurve($riverPen, $riverPts, 0.6)
$riverGlow = New-Object System.Drawing.Pen $WaterEdge, 8
$gfx.DrawCurve($riverGlow, $riverPts, 0.6)

# Both lakes sit clear of the town grid, so no town lands in open water.
$lakeBrush = New-Object System.Drawing.SolidBrush $Water
$lakePen = New-Object System.Drawing.Pen $WaterEdge, 4
$gfx.FillEllipse($lakeBrush, 1120, 248, 230, 108)
$gfx.FillEllipse($lakeBrush, 118, 912, 172, 86)
$gfx.DrawEllipse($lakePen, 1120, 248, 230, 108)
$gfx.DrawEllipse($lakePen, 118, 912, 172, 86)

# ---------------------------------------------------------------- towns
# A uniform grid is what the stock generator gives you; the clusters are what
# the mod leaves behind.
$x0 = 215.0
$x1 = 1755.0
$y0 = 398.0
$y1 = 1002.0
$stepX = ($x1 - $x0) / ($cols - 1)
$stepY = ($y1 - $y0) / ($rows - 1)

# Jitter stays a fraction of the spacing: the "before" state has to read as an
# even scattering, not as a lattice and not as noise.
$uniform = @()
for ($r = 0; $r -lt $rows; $r++) {
	for ($c = 0; $c -lt $cols; $c++) {
		$ux = $x0 + $stepX * $c + ((Next-Rand) - 0.5) * $stepX * 0.42
		$uy = $y0 + $stepY * $r + ((Next-Rand) - 0.5) * $stepY * 0.42
		$uniform += , @($ux, $uy)
	}
}

$centres = @(
	@(495.0, 800.0),
	@(960.0, 470.0),
	@(1455.0, 845.0),
	@(1590.0, 455.0)
)

# Only a centre's own neighbourhood joins it. Towns further out than this are
# the ones that end up as empty countryside - and letting every town on the map
# join a cluster produced arrows sweeping clean across the frame, which read as
# noise rather than as clustering. $KeepRadius is set per variant above.

$towns = @()
foreach ($u in $uniform) {
	$best = 0
	$bestD = [double]::MaxValue
	for ($k = 0; $k -lt $centres.Count; $k++) {
		$dx = $u[0] - $centres[$k][0]
		$dy = $u[1] - $centres[$k][1]
		$d = $dx * $dx + $dy * $dy
		if ($d -lt $bestD) { $bestD = $d; $best = $k }
	}
	$towns += , @{ ux = $u[0]; uy = $u[1]; tx = $u[0]; ty = $u[1]
		cluster = $best; dist = [Math]::Sqrt($bestD); kept = ([Math]::Sqrt($bestD) -le $KeepRadius) }
}

# Seat the survivors on rings around their centre, tight but not overlapping.
$assigned = @{}
foreach ($t in $towns) {
	if (-not $t.kept) { continue }
	$k = $t.cluster
	if (-not $assigned.ContainsKey($k)) { $assigned[$k] = 0 }
	$n = $assigned[$k]
	$assigned[$k] = $n + 1

	# ring 0 = centre, then rings of 6 at increasing radius
	if ($n -eq 0) {
		$t.tx = $centres[$k][0]
		$t.ty = $centres[$k][1]
	} else {
		$ring = [Math]::Floor(($n - 1) / 6) + 1
		$slot = ($n - 1) % 6
		$ang = $slot * [Math]::PI / 3 + $ring * 0.6
		$rad = 56 + $ring * 48
		$t.tx = $centres[$k][0] + [Math]::Cos($ang) * $rad
		$t.ty = $centres[$k][1] + [Math]::Sin($ang) * $rad * 0.8
	}
}

# Where each town is actually drawn. Only the arrows variant relocates anything;
# in the pruned variant every survivor stays on the spot it was generated.
foreach ($t in $towns) {
	if ($Variant -eq "arrows" -and $t.kept) {
		$t.px = $t.tx
		$t.py = $t.ty
	} else {
		$t.px = $t.ux
		$t.py = $t.uy
	}
}

function Draw-Town($cx, $cy, $size, $solid) {
	if ($solid) {
		$glow = New-Object System.Drawing.SolidBrush (New-Colour "F5B95C" 48)
		$gfx.FillEllipse($glow, [float]($cx - $size * 2.1), [float]($cy - $size * 2.1), [float]($size * 4.2), [float]($size * 4.2))
		$glow.Dispose()
		$br = New-Object System.Drawing.SolidBrush $Town
		$gfx.FillEllipse($br, [float]($cx - $size), [float]($cy - $size), [float]($size * 2), [float]($size * 2))
		$br.Dispose()
		$core = New-Object System.Drawing.SolidBrush $TownCore
		$gfx.FillEllipse($core, [float]($cx - $size * 0.38), [float]($cy - $size * 0.38), [float]($size * 0.76), [float]($size * 0.76))
		$core.Dispose()
	} else {
		$pn = New-Object System.Drawing.Pen $Ghost, 3
		$pn.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
		$gfx.DrawEllipse($pn, [float]($cx - $size), [float]($cy - $size), [float]($size * 2), [float]($size * 2))
		$pn.Dispose()
	}
}

# Roads between the towns of a cluster, drawn under the dots. Each town joins
# its two nearest neighbours: spokes from the cluster centre read as a compass
# rose rather than as a road network.
$roadPen = New-Object System.Drawing.Pen $Road, 2.4
for ($k = 0; $k -lt $centres.Count; $k++) {
	$members = @($towns | Where-Object { $_.cluster -eq $k -and $_.kept })
	foreach ($m in $members) {
		$others = @($members | Where-Object { $_.px -ne $m.px -or $_.py -ne $m.py })
		if ($others.Count -eq 0) { continue }
		$ranked = @($others | Sort-Object -Property @{ Expression = {
			($_.px - $m.px) * ($_.px - $m.px) + ($_.py - $m.py) * ($_.py - $m.py) } })
		$take = [Math]::Min(2, $ranked.Count)
		for ($j = 0; $j -lt $take; $j++) {
			$gfx.DrawLine($roadPen, [float]$m.px, [float]$m.py, [float]$ranked[$j].px, [float]$ranked[$j].py)
		}
	}
}

if ($Variant -eq "arrows") {
	# Towns too far from any centre stay where they were generated.
	foreach ($t in $towns) {
		if (-not $t.kept) { Draw-Town $t.ux $t.uy $GhostSize $false }
	}
	# Ghost at the generated position, arrow to where the cluster forms.
	foreach ($t in $towns) {
		if (-not $t.kept) { continue }
		if ($t.dist -lt 70) { continue }
		Draw-Town $t.ux $t.uy $GhostSize $false

		$pn = New-Object System.Drawing.Pen (New-Colour "E8734A" 235), 4.5
		$cap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap 4.0, 4.4, $true
		$pn.CustomEndCap = $cap
		$pn.StartCap = [System.Drawing.Drawing2D.LineCap]::Round

		# Stop short of both dots, and bow the line slightly so it does not read
		# as a ruler. A Bezier, not DrawCurve: a cardinal spline overshoots its
		# end points badly here, which left arrowheads floating in open country.
		$dx = $t.tx - $t.ux
		$dy = $t.ty - $t.uy
		$len = [Math]::Sqrt($dx * $dx + $dy * $dy)
		if ($len -lt 1) { continue }
		$sx = $t.ux + $dx / $len * 22
		$sy = $t.uy + $dy / $len * 22
		$ex = $t.tx - $dx / $len * 48
		$ey = $t.ty - $dy / $len * 48
		$bow = [Math]::Min(30.0, $len * 0.10)
		$c1x = $sx + ($ex - $sx) / 3 - $dy / $len * $bow
		$c1y = $sy + ($ey - $sy) / 3 + $dx / $len * $bow
		$c2x = $sx + ($ex - $sx) * 2 / 3 - $dy / $len * $bow
		$c2y = $sy + ($ey - $sy) * 2 / 3 + $dx / $len * $bow
		$gfx.DrawBezier($pn, [float]$sx, [float]$sy, [float]$c1x, [float]$c1y, [float]$c2x, [float]$c2y, [float]$ex, [float]$ey)
		$pn.Dispose()
	}
	foreach ($t in $towns) {
		if ($t.kept) { Draw-Town $t.px $t.py $DotSize $true }
	}
} else {
	# What the mod really does: survivors stay exactly where they were
	# generated, everything else is struck out and gone.
	foreach ($t in $towns) {
		if ($t.kept) { continue }
		Draw-Town $t.ux $t.uy $GhostSize $false
		$pn = New-Object System.Drawing.Pen (New-Colour "E8734A" 200), 3.2
		$s = $GhostSize * 0.8
		$gfx.DrawLine($pn, [float]($t.ux - $s), [float]($t.uy - $s), [float]($t.ux + $s), [float]($t.uy + $s))
		$gfx.DrawLine($pn, [float]($t.ux + $s), [float]($t.uy - $s), [float]($t.ux - $s), [float]($t.uy + $s))
		$pn.Dispose()
	}
	foreach ($t in $towns) {
		if ($t.kept) { Draw-Town $t.px $t.py $DotSize $true }
	}
}

# ---------------------------------------------------------------- title
# Scrim first, so the type stays legible over whatever the map does.
# Drawn one pixel taller than it is filled, and tile-flipped: a plain gradient
# brush leaves a visible seam at its own edge.
$scrimRect = New-Object System.Drawing.Rectangle 0, -1, $W, 432
$scrim = New-Object System.Drawing.Drawing2D.LinearGradientBrush $scrimRect, (New-Colour "0E1712" 232), (New-Colour "0E1712" 0), 90.0
$scrim.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY
$gfx.FillRectangle($scrim, 0, 0, $W, 430)

$titleFont = New-Object System.Drawing.Font "Segoe UI", 76, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$subFont = New-Object System.Drawing.Font "Segoe UI", 30, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$tagFont = New-Object System.Drawing.Font "Segoe UI", 22, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)

$inkBrush = New-Object System.Drawing.SolidBrush $Ink
$softBrush = New-Object System.Drawing.SolidBrush $InkSoft
$accentBrush = New-Object System.Drawing.SolidBrush $Accent

$gfx.DrawString("TRANSPORT FEVER 3", $tagFont, $accentBrush, 112, 46)
$gfx.DrawString("TOWN CLUSTERING", $titleFont, $inkBrush, 104, 86)

# Accent rule between title and subtitle, tied to the arrow colour.
$rulePen = New-Object System.Drawing.Pen $Accent, 6
$gfx.DrawLine($rulePen, 112, 182, 300, 182)

$gfx.DrawString("Dense groups of towns, empty countryside between them", $subFont, $softBrush, 110, 200)

# ---------------------------------------------------------------- save
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$resolved = Join-Path (Resolve-Path $dir).Path (Split-Path -Leaf $OutFile)
$bmp.Save($resolved, [System.Drawing.Imaging.ImageFormat]::Png)

$gfx.Dispose()
$bmp.Dispose()
Write-Host "Wrote $resolved ($Variant, ${W}x${H})"
