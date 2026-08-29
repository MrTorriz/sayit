# indicator-geometry.ps1 - the pill's geometry, colours and state rule.
#
# Dot-sourced by sayit-indicator.ps1 and by win\tests\Indicator.Tests.ps1.
# It draws nothing and opens no window: every value here is a plain number or
# a plain function, so the geometry can be checked without a display, exactly
# as bin/sayit-overlay's own introspection helpers allow on the Linux side.
#
# The numbers are not independent. They are the same constants bin/sayit-overlay
# draws from, and the two must not drift apart: the pill is one design with two
# implementations, not two drawings that resemble each other. The wordmark
# outlines below were extracted from that file rather than converted again from
# the font, because a second conversion is a second shape.
#
# docs/check-geometry.py compares every number below against the overlay's and
# CI runs it, so a change to one side without the other fails the build rather
# than shipping two different pills. Change bin/sayit-overlay, run that script,
# and it will name what to edit here.

Set-StrictMode -Version 2.0

# --- the pill ---------------------------------------------------------------
$script:PillWidth  = 160.0
$script:PillHeight = 40.0
$script:PillRadius = 12.0
$script:PillBorder = 1.2

# --- the mark ---------------------------------------------------------------
# A 96-unit coordinate system scaled into the pill, so nothing here is a
# pre-scaled pixel value.
$script:MarkScale = 0.3562
$script:BarCount  = 10
$script:BarU      = 11.0      # bar width, and its height at rest
$script:GapU      = 3.0

# Height at level 7, per bar. An uneven row reads as a voice rather than as a
# progress bar. The row opens low, peaks in the middle and settles again.
$script:BarMaxU = @(32.32, 38.08, 58.24, 45.76, 64, 42.4, 53.44, 36.16, 59.68, 40)

$script:DotD = 42.0     # the lamp, larger than the bars alone would ask for

# Gaps in pill pixels, not mark units.
$script:LampGap   = 8.0
$script:LayoutGap = 12.0

# --- colours ----------------------------------------------------------------
# The lamp is always drawn, always the same size and place: the colour is the
# whole signal. Unlit is a dark red that still reads as a lamp, because an
# indicator light does not vanish when it goes out.
$script:LampLit   = @(1, 0.3, 0.3)
$script:LampUnlit = @(0.42, 0.13, 0.15)
$script:InkRgb    = @(1, 1, 1)
$script:PillRgb   = @(0, 0, 0)

# --- the wordmark -----------------------------------------------------------
# "sayit" as outlines rather than as text, so the pill draws identically on a
# machine that has never heard of the font. Nothing at runtime asks for a font
# and no font file lives in this repository.
#
# Normalised to height 1.0 with the origin at the wordmark's own top left, so
# WordmarkHeight is the only number that sets its size.
$script:WordmarkHeight = 21.875
$script:WordmarkAspect = 2.396638
$script:Wordmark = @(
    @('m', 0.253707, 0.846809),
    @('c', 0.380086, 0.846809, 0.510389, 0.787583, 0.510389, 0.652443),
    @('c', 0.510389, 0.583428, 0.468933, 0.524269, 0.364279, 0.501596),
    @('l', 0.262600, 0.479904),
    @('c', 0.235937, 0.473986, 0.231001, 0.468068, 0.231001, 0.453291),
    @('c', 0.231001, 0.428640, 0.267537, 0.418783, 0.306034, 0.418783),
    @('c', 0.350465, 0.418783, 0.380086, 0.437517, 0.395878, 0.455253),
    @('c', 0.412650, 0.473986, 0.417586, 0.475964, 0.430419, 0.470047),
    @('l', 0.513348, 0.433577),
    @('c', 0.526180, 0.427660, 0.524219, 0.415824, 0.519282, 0.407929),
    @('c', 0.486702, 0.355602, 0.420562, 0.304255, 0.308993, 0.304255),
    @('c', 0.173753, 0.304255, 0.053308, 0.370412, 0.053308, 0.499618),
    @('c', 0.053308, 0.576529, 0.103657, 0.614977, 0.192503, 0.635672),
    @('l', 0.290243, 0.658344),
    @('c', 0.323803, 0.666240, 0.334674, 0.674119, 0.334674, 0.686935),
    @('c', 0.334674, 0.726380, 0.270495, 0.727360, 0.246809, 0.727360),
    @('c', 0.175715, 0.727360, 0.152028, 0.699751, 0.135239, 0.674119),
    @('c', 0.124385, 0.657364, 0.113531, 0.657364, 0.096742, 0.665259),
    @('l', 0.015791, 0.703707),
    @('c', 0.001978, 0.710605, 0.000000, 0.717503, 0.006915, 0.731316),
    @('c', 0.037517, 0.792520, 0.112533, 0.846809, 0.253707, 0.846809),
    @('z'),
    @('m', 0.826355, 0.797872),
    @('c', 0.842163, 0.781084, 0.851039, 0.781084, 0.852036, 0.793916),
    @('l', 0.853017, 0.805768),
    @('c', 0.854995, 0.824518, 0.855976, 0.837367, 0.873745, 0.837367),
    @('l', 1.009001, 0.837367),
    @('c', 1.027751, 0.837367, 1.027751, 0.836370, 1.030710, 0.816622),
    @('l', 1.079097, 0.473072),
    @('c', 1.080078, 0.463198, 1.081059, 0.453324, 1.081059, 0.444448),
    @('c', 1.081059, 0.362500, 1.025790, 0.304255, 0.857954, 0.304255),
    @('c', 0.732571, 0.304255, 0.641747, 0.332879, 0.599294, 0.410871),
    @('c', 0.587458, 0.441489, 0.596335, 0.450366, 0.607189, 0.452344),
    @('l', 0.732571, 0.478009),
    @('c', 0.749360, 0.480967, 0.754297, 0.478009, 0.758236, 0.470113),
    @('c', 0.778981, 0.427660, 0.816481, 0.421742, 0.848080, 0.421742),
    @('c', 0.878682, 0.421742, 0.892512, 0.432596, 0.892512, 0.459259),
    @('c', 0.892512, 0.463198, 0.892512, 0.468135, 0.891514, 0.473072),
    @('l', 0.888556, 0.489860),
    @('c', 0.886577, 0.502693, 0.878682, 0.509608, 0.866830, 0.509608),
    @('l', 0.859932, 0.509608),
    @('c', 0.721717, 0.509608, 0.533153, 0.560937, 0.533153, 0.715924),
    @('c', 0.533153, 0.790957, 0.586461, 0.847224, 0.679264, 0.847224),
    @('c', 0.736528, 0.847224, 0.792794, 0.833411, 0.826355, 0.797872),
    @('z'),
    @('m', 0.864869, 0.662616),
    @('c', 0.862891, 0.677427, 0.850058, 0.692237, 0.837226, 0.703092),
    @('c', 0.824393, 0.713963, 0.800690, 0.722839, 0.771069, 0.722839),
    @('c', 0.742445, 0.722839, 0.727635, 0.705070, 0.727635, 0.684342),
    @('c', 0.727635, 0.624119, 0.808585, 0.602394, 0.849061, 0.599435),
    @('l', 0.862891, 0.598454),
    @('c', 0.874742, 0.597457, 0.873745, 0.598454, 0.871767, 0.610289),
    @('z'),
    @('m', 1.116223, 1.000000),
    @('c', 1.266273, 1.000000, 1.329455, 0.965459, 1.421277, 0.801579),
    @('l', 1.679920, 0.337533),
    @('c', 1.687832, 0.323720, 1.687832, 0.313830, 1.672025, 0.313830),
    @('l', 1.561453, 0.313830),
    @('c', 1.549618, 0.313830, 1.539744, 0.319764, 1.530851, 0.338531),
    @('l', 1.418318, 0.563630),
    @('c', 1.409425, 0.581400, 1.400549, 0.582380, 1.396592, 0.565608),
    @('l', 1.345263, 0.328657),
    @('c', 1.343285, 0.317786, 1.336370, 0.313830, 1.324518, 0.313830),
    @('l', 1.143866, 0.313830),
    @('c', 1.128075, 0.313830, 1.121160, 0.324701, 1.127078, 0.347407),
    @('l', 1.254438, 0.811436),
    @('c', 1.261336, 0.835140, 1.235672, 0.858843, 1.190259, 0.858843),
    @('l', 1.120163, 0.858843),
    @('c', 1.098454, 0.858843, 1.085622, 0.866739, 1.084624, 0.874634),
    @('l', 1.070811, 0.975332),
    @('c', 1.067852, 0.994082, 1.078707, 1.000000, 1.116223, 1.000000),
    @('z'),
    @('m', 1.957883, 0.130918),
    @('c', 1.959845, 0.118085, 1.958864, 0.104255, 1.948009, 0.104255),
    @('l', 1.782152, 0.104255),
    @('c', 1.770300, 0.104255, 1.764382, 0.112168, 1.762404, 0.126978),
    @('l', 1.745616, 0.238531),
    @('c', 1.742657, 0.255303, 1.745616, 0.270113, 1.760426, 0.270113),
    @('l', 1.909496, 0.270113),
    @('c', 1.932202, 0.270113, 1.939117, 0.267154, 1.942075, 0.247407),
    @('z'),
    @('m', 1.929243, 0.339511),
    @('c', 1.930240, 0.327660, 1.928262, 0.313830, 1.917391, 0.313830),
    @('l', 1.750553, 0.313830),
    @('c', 1.738718, 0.313830, 1.734761, 0.315808, 1.732783, 0.330635),
    @('l', 1.665662, 0.806632),
    @('c', 1.663684, 0.823421, 1.671580, 0.837234, 1.691327, 0.837234),
    @('l', 1.830523, 0.837234),
    @('c', 1.853229, 0.837234, 1.859146, 0.835273, 1.862122, 0.814528),
    @('z'),
    @('m', 2.168580, 0.837234),
    @('c', 2.209055, 0.837234, 2.260401, 0.836253, 2.301858, 0.832314),
    @('c', 2.316668, 0.831316, 2.324564, 0.822440, 2.326542, 0.806632),
    @('l', 2.338393, 0.727660),
    @('c', 2.340355, 0.716805, 2.331479, 0.701995, 2.320624, 0.701995),
    @('l', 2.278171, 0.701995),
    @('c', 2.235717, 0.701995, 2.218929, 0.693102, 2.218929, 0.667404),
    @('c', 2.218929, 0.663447, 2.218929, 0.659491, 2.219926, 0.655552),
    @('l', 2.246572, 0.465808),
    @('c', 2.248550, 0.452959, 2.254467, 0.447041, 2.265338, 0.447041),
    @('l', 2.357143, 0.447041),
    @('c', 2.373932, 0.447041, 2.378869, 0.444082, 2.380830, 0.431233),
    @('l', 2.394660, 0.329555),
    @('c', 2.396638, 0.316722, 2.385767, 0.312766, 2.372935, 0.312766),
    @('l', 2.286066, 0.312766),
    @('c', 2.279151, 0.312766, 2.273234, 0.306848, 2.274215, 0.299934),
    @('l', 2.294943, 0.163697),
    @('c', 2.297918, 0.141988, 2.292981, 0.136054, 2.282110, 0.136054),
    @('l', 2.136997, 0.136054),
    @('c', 2.125145, 0.136054, 2.118231, 0.139029, 2.115272, 0.149884),
    @('l', 2.077755, 0.296061),
    @('c', 2.075777, 0.304953, 2.067881, 0.313830, 2.059986, 0.313830),
    @('l', 2.001741, 0.313830),
    @('c', 1.987928, 0.313830, 1.983972, 0.313830, 1.981994, 0.326679),
    @('l', 1.969161, 0.419398),
    @('c', 1.966203, 0.439146, 1.970159, 0.447041, 1.981013, 0.447041),
    @('l', 2.030365, 0.447041),
    @('c', 2.042217, 0.447041, 2.051110, 0.450997, 2.050112, 0.460871),
    @('l', 2.015571, 0.700017),
    @('c', 2.014574, 0.706932, 2.014574, 0.712849, 2.014574, 0.718783),
    @('c', 2.014574, 0.791822, 2.077755, 0.837234, 2.168580, 0.837234),
    @('z'),
    @('m', 0.006915, 0.000000)
)

# --- derived ----------------------------------------------------------------
$script:WaveWidthU  = $script:BarCount * $script:BarU + ($script:BarCount - 1) * $script:GapU
$script:LampWidth   = $script:DotD * $script:MarkScale
$script:WaveWidth   = $script:WaveWidthU * $script:MarkScale
$script:WordmarkWidth = $script:WordmarkHeight * $script:WordmarkAspect

# The three items are centred as one group, so the pill reads as a unit.
$script:ContentWidth = $script:LampWidth + $script:LampGap + $script:WaveWidth +
                       $script:LayoutGap + $script:WordmarkWidth
$script:ContentX = ($script:PillWidth - $script:ContentWidth) / 2.0

function Get-SayitBarHeights {
    <#
      .SYNOPSIS
        Bar heights in mark units at a level from 0 to 7.
      .DESCRIPTION
        At level 0 every bar is BarU high - as tall as it is wide, which a
        corner radius of half the width turns into a dot. Speaking interpolates
        each bar towards its own maximum.
    #>
    param([Parameter(Mandatory)][double]$Level)

    if ($Level -lt 0) { $Level = 0 } elseif ($Level -gt 7) { $Level = 7 }
    $ut = New-Object double[] $script:BarCount
    for ($i = 0; $i -lt $script:BarCount; $i++) {
        $ut[$i] = $script:BarU + ($script:BarMaxU[$i] - $script:BarU) * $Level / 7.0
    }
    return $ut
}

function Get-SayitBarMidpoints {
    <#
      .SYNOPSIS
        Each bar's vertical centre in pill pixels at this level.
      .DESCRIPTION
        They are all the pill's own centre line: the bars grow symmetrically
        about it rather than up from a baseline, which is what keeps the row
        level with the lamp at rest.
    #>
    param([Parameter(Mandatory)][double]$Level)

    $cy = $script:PillHeight / 2.0
    return @($script:BarMaxU | ForEach-Object { $cy })
}

function Get-SayitBarRects {
    <#
      .SYNOPSIS
        The bars as x, y, width, height in pill pixels, centred on the pill.
    #>
    param([Parameter(Mandatory)][double]$Level, [double]$X = $script:ContentX)

    $cy = $script:PillHeight / 2.0
    $waveX = $X + $script:LampWidth + $script:LampGap
    $bw = $script:BarU * $script:MarkScale
    $i = 0
    return @(Get-SayitBarHeights -Level $Level | ForEach-Object {
        $bh = $_ * $script:MarkScale
        $rect = [pscustomobject]@{
            X      = $waveX + $i * ($script:BarU + $script:GapU) * $script:MarkScale
            Y      = $cy - $bh / 2.0
            Width  = $bw
            Height = $bh
            Radius = $bw / 2.0
        }
        $i++
        $rect
    })
}

function Get-SayitLampRect {
    <#
      .SYNOPSIS
        The lamp as x, y, diameter in pill pixels. Never depends on the state.
    #>
    param([double]$X = $script:ContentX)

    $d = $script:LampWidth
    return [pscustomobject]@{
        X        = $X
        Y        = $script:PillHeight / 2.0 - $d / 2.0
        Diameter = $d
    }
}

function Get-SayitWordmarkOrigin {
    <#
      .SYNOPSIS
        Top-left corner of the wordmark in pill pixels, and the height that
        scales it.
    #>
    param([double]$X = $script:ContentX)

    return [pscustomobject]@{
        X      = $X + $script:LampWidth + $script:LampGap + $script:WaveWidth + $script:LayoutGap
        Y      = $script:PillHeight / 2.0 - $script:WordmarkHeight / 2.0
        Height = $script:WordmarkHeight
    }
}

function Get-SayitIndicatorState {
    <#
      .SYNOPSIS
        What the pill draws, as data. MicOpen is the microphone being open.
      .DESCRIPTION
        Reports exactly what the drawing code uses, so a test cannot pass
        against a stale copy. Speaking changes the bars and nothing else:
        the lamp, the border and the wordmark are identical whether the
        microphone is open and silent or open and loud.
    #>
    param([bool]$MicOpen, [double]$Level = 0.0)

    if (-not $MicOpen) { $Level = 0.0 }
    return [pscustomobject]@{
        Lamp         = $true          # always on the pill, never moves
        LampLit      = $MicOpen
        LampRgb      = $(if ($MicOpen) { $script:LampLit } else { $script:LampUnlit })
        BorderRgb    = $script:InkRgb
        PillRgb      = $script:PillRgb
        WordmarkRgb  = $script:InkRgb
        Bars         = @(Get-SayitBarHeights -Level $Level | ForEach-Object { [math]::Round($_, 6) })
    }
}

function New-SayitWordmarkPath {
    <#
      .SYNOPSIS
        The stored outlines as a GraphicsPath, scaled to Height and placed at X, Y.
      .DESCRIPTION
        The caller disposes the path. Cubic segments become AddBezier, straight
        segments AddLine, and each closed contour CloseFigure - so the counters
        and the dots on the i and the j stay holes rather than filled blobs.
    #>
    param([double]$X, [double]$Y, [double]$Height)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
    $cur = New-Object System.Drawing.PointF(0, 0)
    $start = $cur
    $open = $false

    foreach ($seg in $script:Wordmark) {
        switch ($seg[0]) {
            'm' {
                if ($open) { $path.StartFigure() }
                $cur = New-Object System.Drawing.PointF(
                    [float]($X + $seg[1] * $Height), [float]($Y + $seg[2] * $Height))
                $start = $cur
                $open = $true
            }
            'l' {
                $next = New-Object System.Drawing.PointF(
                    [float]($X + $seg[1] * $Height), [float]($Y + $seg[2] * $Height))
                $path.AddLine($cur, $next)
                $cur = $next
            }
            'c' {
                $c1 = New-Object System.Drawing.PointF(
                    [float]($X + $seg[1] * $Height), [float]($Y + $seg[2] * $Height))
                $c2 = New-Object System.Drawing.PointF(
                    [float]($X + $seg[3] * $Height), [float]($Y + $seg[4] * $Height))
                $next = New-Object System.Drawing.PointF(
                    [float]($X + $seg[5] * $Height), [float]($Y + $seg[6] * $Height))
                $path.AddBezier($cur, $c1, $c2, $next)
                $cur = $next
            }
            'z' {
                $path.CloseFigure()
                $cur = $start
                $open = $false
            }
        }
    }
    return $path
}

$script:MinScale = 0.5
$script:MaxScale = 4.0

function ConvertFrom-SayitLayout {
    <#
      .SYNOPSIS
        Parses the saved overlay-position file. Returns $null if it cannot.
      .DESCRIPTION
        "x,y" is the format from before the pill could be resized and still
        parses; it simply says nothing about the size. "x,y,scale" carries both.
        A scale outside the allowed range is dropped rather than clamped: a file
        that says something impossible is a file to ignore, not to guess at.

        Parsed with InvariantCulture. A Swedish machine writes 1,25 with a
        comma, and a comma is the field separator here - which is exactly why
        ConvertTo-SayitLayout formats with a point.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $delar = $Text.Trim() -split ','
    if ($delar.Count -lt 2) { return $null }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $x = 0; $y = 0
    if (-not [int]::TryParse($delar[0].Trim(), [ref]$x)) { return $null }
    if (-not [int]::TryParse($delar[1].Trim(), [ref]$y)) { return $null }

    $skala = $null
    if ($delar.Count -ge 3) {
        $s = 0.0
        if ([double]::TryParse($delar[2].Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$s) -and
            $s -ge $script:MinScale -and $s -le $script:MaxScale) {
            $skala = $s
        }
    }
    return [pscustomobject]@{ X = $x; Y = $y; Scale = $skala }
}

function ConvertTo-SayitLayout {
    <#
      .SYNOPSIS
        Formats position and scale for the overlay-position file.
      .DESCRIPTION
        The scale is written with InvariantCulture, so it uses a point. With the
        machine's own culture a Swedish decimal comma would add a fourth field
        and the file would not survive being read back.
    #>
    param([int]$X, [int]$Y, [double]$Scale)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return '{0},{1},{2}' -f $X, $Y, $Scale.ToString('0.####', $inv)
}

function Get-SayitClampedScale {
    <#
      .SYNOPSIS
        A scale held inside the range the pill is allowed to take.
    #>
    param([double]$Scale)

    if ($Scale -lt $script:MinScale) { return $script:MinScale }
    if ($Scale -gt $script:MaxScale) { return $script:MaxScale }
    return $Scale
}

function New-SayitPillPath {
    <#
      .SYNOPSIS
        The pill outline as a rounded rectangle, inset by Inset on every side.
    #>
    param([double]$Width, [double]$Height, [double]$Radius, [double]$Inset = 0.0)

    $x = $Inset
    $y = $Inset
    $w = $Width - 2 * $Inset
    $h = $Height - 2 * $Inset
    $r = [math]::Min($Radius, [math]::Min($w / 2.0, $h / 2.0))
    $d = 2.0 * $r

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc([float]$x, [float]$y, [float]$d, [float]$d, 180, 90)
    $path.AddArc([float]($x + $w - $d), [float]$y, [float]$d, [float]$d, 270, 90)
    $path.AddArc([float]($x + $w - $d), [float]($y + $h - $d), [float]$d, [float]$d, 0, 90)
    $path.AddArc([float]$x, [float]($y + $h - $d), [float]$d, [float]$d, 90, 90)
    $path.CloseFigure()
    return $path
}
