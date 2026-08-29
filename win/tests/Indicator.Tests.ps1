# Indicator.Tests.ps1 - unit tests for the pill's geometry, colours and the
# rules its state must obey.
#
# win\lib\indicator-geometry.ps1 exists so this file can check the drawing
# without opening a window: it holds the same constants sayit-indicator.ps1
# draws from, so a test cannot pass against a stale copy of them.
#
# The pill is one design with two implementations. bin/sayit-overlay is the
# specification and this side must match it, so the numbers here are written out
# rather than derived - a test that recomputes a value from the code it is
# testing would agree with any change, including a wrong one.
#
# NOT COVERED: that a window actually appears, takes no focus, or stays above
# another application. Those need a desktop session and a compositor to observe,
# and a unit test can only assert the flags that ask for them - which is what
# the last two blocks do, by reading the source.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\indicator-geometry.ps1')
    Add-Type -AssemblyName System.Drawing

    $script:IndicatorSource = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot '..\sayit-indicator.ps1') -Raw
}

Describe 'the pill' {
    It 'is 160 by 40 pixels' {
        $script:PillWidth  | Should -Be 160
        $script:PillHeight | Should -Be 40
    }

    It 'has a corner radius of 12 and a border 1.2 wide' {
        $script:PillRadius | Should -Be 12
        $script:PillBorder | Should -Be 1.2
    }

    It 'is black with a white border' {
        ($script:PillRgb -join ',') | Should -Be '0,0,0'
        ($script:InkRgb  -join ',') | Should -Be '1,1,1'
        $s = Get-SayitIndicatorState -MicOpen $false
        ($s.PillRgb     -join ',') | Should -Be '0,0,0'
        ($s.BorderRgb   -join ',') | Should -Be '1,1,1'
        ($s.WordmarkRgb -join ',') | Should -Be '1,1,1'
    }

    It 'centres its three items as one group' {
        # Lamp, meter and wordmark, with the two gaps between them.
        $vantat = $script:LampWidth + $script:LampGap + $script:WaveWidth +
                  $script:LayoutGap + $script:WordmarkWidth
        $script:ContentWidth | Should -Be $vantat
        $script:ContentX | Should -Be (($script:PillWidth - $vantat) / 2.0)
        # Equal margins is what "centred" means; this catches a one-sided fix.
        $hoger = $script:PillWidth - ($script:ContentX + $script:ContentWidth)
        [math]::Round($hoger, 9) | Should -Be ([math]::Round($script:ContentX, 9))
    }
}

Describe 'the meter' {
    It 'has ten bars' {
        $script:BarCount | Should -Be 10
        (Get-SayitBarHeights -Level 7).Count | Should -Be 10
        (Get-SayitBarRects -Level 7).Count | Should -Be 10
    }

    It 'draws every bar around one shared centre line' {
        # Growing about the centre rather than up from a baseline is what keeps
        # the row level with the lamp. Every bar's midpoint must be the same.
        foreach ($niva in 0.0, 3.5, 7.0) {
            $mitt = @(Get-SayitBarRects -Level $niva |
                        ForEach-Object { [math]::Round($_.Y + $_.Height / 2.0, 9) } |
                        Sort-Object -Unique)
            $mitt.Count | Should -Be 1
            $mitt[0] | Should -Be ($script:PillHeight / 2.0)
        }
    }

    It 'rests as a row of dots level with the lamp' {
        # At level 0 each bar is as tall as it is wide, and a corner radius of
        # half the width turns that square into a circle.
        $rects = @(Get-SayitBarRects -Level 0)
        foreach ($r in $rects) {
            [math]::Round($r.Height, 9) | Should -Be ([math]::Round($r.Width, 9))
            [math]::Round($r.Radius, 9) | Should -Be ([math]::Round($r.Width / 2.0, 9))
        }
        $lampa = Get-SayitLampRect
        $lampMitt = [math]::Round($lampa.Y + $lampa.Diameter / 2.0, 9)
        $barMitt  = [math]::Round($rects[0].Y + $rects[0].Height / 2.0, 9)
        $lampMitt | Should -Be $barMitt
    }

    It 'reaches 22.8 pixels at level 7, leaving 8.6 above and below' {
        $hogst = (@(Get-SayitBarRects -Level 7) |
                    Measure-Object -Property Height -Maximum).Maximum
        [math]::Round($hogst, 2) | Should -Be 22.8
        [math]::Round(($script:PillHeight - $hogst) / 2.0, 2) | Should -Be 8.6
    }

    It 'keeps the bar heights bin/sayit-overlay specifies' {
        # Compared as numbers, not as text: -join formats a double through the
        # current culture, so on a Swedish machine 32.32 joins as "32,32" and a
        # string comparison fails on the separator rather than on the value.
        $vantat = @(32.32, 38.08, 58.24, 45.76, 64.00,
                    42.40, 53.44, 36.16, 59.68, 40.00)
        $script:BarMaxU.Count | Should -Be $vantat.Count
        for ($i = 0; $i -lt $vantat.Count; $i++) {
            $script:BarMaxU[$i] | Should -Be $vantat[$i]
        }
        $script:BarU | Should -Be 11
        $script:GapU | Should -Be 3
        $script:MarkScale | Should -Be 0.3562
    }
}

Describe 'the lamp' {
    It 'is always drawn, in the same place and size, whatever the state' {
        $stangd = Get-SayitLampRect
        $script:micOpen = $true
        $oppen = Get-SayitLampRect
        $oppen.X        | Should -Be $stangd.X
        $oppen.Y        | Should -Be $stangd.Y
        $oppen.Diameter | Should -Be $stangd.Diameter
        $stangd.Diameter | Should -Be ($script:DotD * $script:MarkScale)
    }

    It 'is dull dark red when the microphone is shut, never lit' {
        $s = Get-SayitIndicatorState -MicOpen $false
        $s.Lamp | Should -BeTrue          # still on the pill
        $s.LampLit | Should -BeFalse
        ($s.LampRgb -join ',') | Should -Be ($script:LampUnlit -join ',')
        # 0.42, 0.13, 0.15 is #6b2126.
        $hex = '#{0:x2}{1:x2}{2:x2}' -f
            [int][math]::Round($s.LampRgb[0] * 255),
            [int][math]::Round($s.LampRgb[1] * 255),
            [int][math]::Round($s.LampRgb[2] * 255)
        $hex | Should -Be '#6b2126'
    }

    It 'is full red when the microphone is open' {
        $s = Get-SayitIndicatorState -MicOpen $true
        $s.LampLit | Should -BeTrue
        $hex = '#{0:x2}{1:x2}{2:x2}' -f
            [int][math]::Round($s.LampRgb[0] * 255),
            [int][math]::Round($s.LampRgb[1] * 255),
            [int][math]::Round($s.LampRgb[2] * 255)
        $hex | Should -Be '#ff4c4c'
    }

    It 'looks identical whether the open microphone is silent or loud' {
        $tyst = Get-SayitIndicatorState -MicOpen $true -Level 0
        $tal  = Get-SayitIndicatorState -MicOpen $true -Level 7
        ($tal.LampRgb -join ',')     | Should -Be ($tyst.LampRgb -join ',')
        $tal.LampLit                 | Should -Be $tyst.LampLit
        ($tal.BorderRgb -join ',')   | Should -Be ($tyst.BorderRgb -join ',')
        ($tal.WordmarkRgb -join ',') | Should -Be ($tyst.WordmarkRgb -join ',')
        ($tal.PillRgb -join ',')     | Should -Be ($tyst.PillRgb -join ',')
    }

    It 'changes only the meter geometry when speech arrives' {
        $tyst = Get-SayitIndicatorState -MicOpen $true -Level 0
        $tal  = Get-SayitIndicatorState -MicOpen $true -Level 7
        ($tal.Bars -join ',') | Should -Not -Be ($tyst.Bars -join ',')
    }

    It 'never lights for a window that is not recording' {
        # A placement window records nothing and must show a dull lamp.
        $script:IndicatorSource | Should -Match '\$placing\)\s*\{\s*\r?\n\s*\$script:micOpen = \$false'
    }
}

Describe 'the wordmark' {
    It 'is drawn from stored outlines, with no font asked for at runtime' {
        $script:Wordmark.Count | Should -Be 123
        # Nothing may construct a Font or name a family: the repository is
        # public and the pill must not change with the machine's fonts.
        $script:IndicatorSource | Should -Not -Match 'System\.Drawing\.Font'
        $script:IndicatorSource | Should -Not -Match 'FontFamily'
        $script:IndicatorSource | Should -Not -Match 'DrawString'
        $script:IndicatorSource | Should -Not -Match 'Libre Franklin'
    }

    It 'keeps the proportions bin/sayit-overlay stores' {
        $script:WordmarkHeight | Should -Be 21.875
        $script:WordmarkAspect | Should -Be 2.396638
        $script:WordmarkWidth  | Should -Be (21.875 * 2.396638)
    }

    It 'builds a path whose width matches the stored aspect ratio' {
        $p = New-SayitWordmarkPath -X 0 -Y 0 -Height $script:WordmarkHeight
        try {
            $b = $p.GetBounds()
            [math]::Round($b.Width, 3) | Should -Be ([math]::Round($script:WordmarkWidth, 3))
            $p.PointCount | Should -BeGreaterThan 0
        } finally { $p.Dispose() }
    }
}

Describe 'the layer policy' {
    # Regression, from the Linux side: a resting pill used to drop to a lower
    # layer so it would not cover fullscreen video, and was raised while
    # recording. A desktop panel shares that layer and stacking within one layer
    # follows map order, so the pill was visible at rest or hidden behind the
    # panel depending on which surface was mapped last.

    It 'sets TopMost exactly once' {
        $traffar = [regex]::Matches($script:IndicatorSource, '\$form\.TopMost\s*=')
        $traffar.Count | Should -Be 1
    }

    It 'does not touch TopMost from the state path' {
        # Everything from the recording-state block to the end of the timer.
        $start = $script:IndicatorSource.IndexOf('$timer.Add_Tick(')
        $start | Should -BeGreaterThan 0
        $tick = $script:IndicatorSource.Substring($start)
        $tick | Should -Not -Match '\$form\.TopMost\s*='
        $tick | Should -Not -Match 'TopMost'
    }

    It 'never lowers the window from the topmost band' {
        # HWND_NOTOPMOST or HWND_BOTTOM would be the way to drop a layer.
        $script:IndicatorSource | Should -Not -Match 'HWND_NOTOPMOST'
        $script:IndicatorSource | Should -Not -Match 'HWND_BOTTOM'
        $script:IndicatorSource | Should -Match 'HWND_TOPMOST'
    }

    It 'shows the window without activating it' {
        $script:IndicatorSource | Should -Match 'SW_SHOWNOACTIVATE'
        $script:IndicatorSource | Should -Match 'SWP_NOACTIVATE'
        $script:IndicatorSource | Should -Match 'WS_EX_NOACTIVATE'
        $script:IndicatorSource | Should -Match 'ShowWithoutActivation'
    }
}

Describe 'the layered window is actually painted' {
    # Regression, and an expensive one to find: the pill was created, reported
    # itself visible, sat at the right coordinates with the right size and
    # painted without error into its own bitmap - while nothing appeared on
    # screen. CreateParams forces WS_EX_LAYERED, and a layered window is not
    # drawn until SetLayeredWindowAttributes has been called for it. WinForms
    # makes that call from the Opacity setter, but skips it at exactly 1.0.

    It 'assigns Opacity' {
        $script:IndicatorSource | Should -Match '\$form\.Opacity\s*='
    }

    It 'keeps Opacity below 1.0, so the layer is initialised' {
        $m = [regex]::Match($script:IndicatorSource, '\$form\.Opacity\s*=\s*([\d.]+)')
        $m.Success | Should -BeTrue
        $varde = [double]::Parse($m.Groups[1].Value,
            [System.Globalization.CultureInfo]::InvariantCulture)
        $varde | Should -BeLessThan 1.0
        # Still opaque enough to read as the solid black pill it is meant to be.
        $varde | Should -BeGreaterThan 0.9
    }

    It 'still forces the layered style it depends on' {
        $script:IndicatorSource | Should -Match 'WS_EX_LAYERED'
    }
}

Describe 'the saved position and size' {
    It 'reads the two-field format written before the pill could be resized' {
        $l = ConvertFrom-SayitLayout -Text '100,200'
        $l.X | Should -Be 100
        $l.Y | Should -Be 200
        $l.Scale | Should -BeNullOrEmpty   # says nothing about the size
    }

    It 'reads position and scale together' {
        $l = ConvertFrom-SayitLayout -Text '640,764,1.75'
        $l.X | Should -Be 640
        $l.Y | Should -Be 764
        $l.Scale | Should -Be 1.75
    }

    It 'writes the scale with a point, whatever the machine culture is' {
        # The comma is the field separator. A Swedish decimal comma would add a
        # fourth field and the file would not survive being read back.
        $text = ConvertTo-SayitLayout -X 640 -Y 764 -Scale 1.25
        $text | Should -Be '640,764,1.25'
        ($text -split ',').Count | Should -Be 3
    }

    It 'survives a round trip' {
        $text = ConvertTo-SayitLayout -X -12 -Y 900 -Scale 2.5
        $l = ConvertFrom-SayitLayout -Text $text
        $l.X | Should -Be -12
        $l.Y | Should -Be 900
        $l.Scale | Should -Be 2.5
    }

    It 'ignores a scale outside the allowed range rather than guessing' {
        (ConvertFrom-SayitLayout -Text '0,0,99').Scale  | Should -BeNullOrEmpty
        (ConvertFrom-SayitLayout -Text '0,0,0.01').Scale | Should -BeNullOrEmpty
    }

    It 'returns nothing for a file it cannot make sense of' {
        ConvertFrom-SayitLayout -Text ''        | Should -BeNullOrEmpty
        ConvertFrom-SayitLayout -Text '640'     | Should -BeNullOrEmpty
        ConvertFrom-SayitLayout -Text 'x,y'     | Should -BeNullOrEmpty
    }

    It 'holds the scale inside the range the pill may take' {
        Get-SayitClampedScale -Scale 0.1  | Should -Be 0.5
        Get-SayitClampedScale -Scale 99   | Should -Be 4.0
        Get-SayitClampedScale -Scale 1.75 | Should -Be 1.75
    }
}

Describe 'placing and resizing' {
    It 'resizes by scale, never by stretching one axis' {
        # One scale factor for the whole pill, so the proportion is fixed.
        $script:IndicatorSource | Should -Match 'Set-PillScale'
        $script:IndicatorSource | Should -Match 'PillWidth\s*\*\s*\$NewScale'
        $script:IndicatorSource | Should -Match 'PillHeight\s*\*\s*\$NewScale'
    }

    It 'anchors the end opposite the one being dragged' {
        $script:IndicatorSource | Should -Match "Anchor -eq 'left'"
        $script:IndicatorSource | Should -Match 'startBounds\.Right - \$w'
    }

    It 'only accepts input while placing' {
        # The resident pill is click-through; placement is the one exception.
        $script:IndicatorSource | Should -Match '\$form\.ClickThrough = -not \$placing'
    }

    It 'saves position and size together' {
        $script:IndicatorSource | Should -Match 'Save-Layout -X \$form\.Location\.X'
    }
}

Describe 'residency' {
    It 'keeps a resident pill up when the microphone closes' {
        # Only a managed pill - one that belongs to a single dictation - closes
        # with the state file. A resident one just puts its lamp out.
        $script:IndicatorSource | Should -Match '\$Managed -and -not \$open'
    }

    It 'refuses to draw a second pill over the resident one' {
        $script:IndicatorSource | Should -Match 'Local\\sayit-indicator'
        $script:IndicatorSource | Should -Match 'Get-IndicatorMutex'
    }
}
