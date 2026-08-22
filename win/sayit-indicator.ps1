# sayit-indicator.ps1 - the on-screen recording indicator.
#
# Usage:
#   .\sayit-indicator.ps1 show    show the pill and animate it (blocks)
#   .\sayit-indicator.ps1 hide    tell a running indicator to close
#   .\sayit-indicator.ps1 place   drag it where you want it, Enter or Escape saves
#
# The sayit mark IS the meter: the bars follow your voice level and the dot burns
# red while the microphone is open. The level comes from the recorder, which has
# already computed it, so no second capture stream is opened.
#
# The window never takes focus. WS_EX_NOACTIVATE keeps the system from making it
# foreground, WS_EX_TRANSPARENT lets clicks pass through to whatever is beneath,
# WS_EX_TOOLWINDOW keeps it out of Alt-Tab, and it is shown with
# SW_SHOWNOACTIVATE. Without all four a topmost form steals focus on first show,
# which would defeat the point of dictating into the window you were using.
#
# Known limits: it cannot appear over a true exclusive-fullscreen application, or
# on the UAC secure desktop. Both are architectural, not bugs.
#
# Exit codes: 0 normal, 1 the indicator could not be created.

[CmdletBinding()]
param([Parameter(Position = 0)][ValidateSet('show', 'hide', 'place')][string]$Action = 'show')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$stateFile    = Join-Path $script:RunDir 'indicator.on'
$levelFile    = Join-Path $script:RunDir 'level'
$positionFile = Join-Path $script:ConfigDir 'overlay-position'

if ($Action -eq 'hide') {
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Sayit
{
    /// A borderless, click-through, never-activating topmost window.
    public class Overlay : Form
    {
        private const int WS_EX_TOPMOST     = 0x00000008;
        private const int WS_EX_TRANSPARENT = 0x00000020;
        private const int WS_EX_TOOLWINDOW  = 0x00000080;
        private const int WS_EX_LAYERED     = 0x00080000;
        private const int WS_EX_NOACTIVATE  = 0x08000000;

        private const int WM_MOUSEACTIVATE = 0x0021;
        private const int MA_NOACTIVATE    = 3;

        private const int SW_SHOWNOACTIVATE = 4;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_NOSIZE     = 0x0001;
        private const uint SWP_NOMOVE     = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        public bool ClickThrough = true;

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
                if (ClickThrough) { cp.ExStyle |= WS_EX_TRANSPARENT; }
                return cp;
            }
        }

        // WinForms sets TopMost without SWP_NOACTIVATE and focuses the active
        // control on first show; both are overridden here.
        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_MOUSEACTIVATE) { m.Result = new IntPtr(MA_NOACTIVATE); return; }
            base.WndProc(ref m);
        }

        public void ShowNoActivate()
        {
            ShowWindow(this.Handle, SW_SHOWNOACTIVATE);
            KeepOnTop();
        }

        /// HWND_TOPMOST grants membership of the topmost band, not a position
        /// within it, so this is re-issued while visible.
        public void KeepOnTop()
        {
            SetWindowPos(this.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

# --- geometry ---------------------------------------------------------------
# The mark is drawn in the same coordinate system as docs/logo.svg (a 96x96 view
# box) so it stays identical to the project mark: three baseline-aligned rounded
# bars ending in a full stop. Bar heights interpolate between the level-0 and
# level-7 icon frames; the dot burns red while the microphone is open.
$markScale = 0.58
$width  = 100
$height = 52

# x, width, height at level 0, height at level 7 - straight from icons/*.svg
$bars = @(
    @{ X = 14.0; W = 12.0; H0 = 12.0; H7 = 44.0 },
    @{ X = 34.0; W = 12.0; H0 = 18.0; H7 = 64.0 },
    @{ X = 54.0; W = 12.0; H0 = 10.0; H7 = 36.0 }
)
$baseline = 74.0
$offsetX  = ($width  - (86.0 - 14.0) * $markScale) / 2.0 - 14.0 * $markScale
$offsetY  = ($height - (74.0 - 10.0) * $markScale) / 2.0 - 10.0 * $markScale

function Get-Position {
    if (Test-Path -LiteralPath $positionFile) {
        try {
            $p = (Read-Utf8Text -Path $positionFile).Trim() -split ','
            if ($p.Count -eq 2) { return New-Object System.Drawing.Point([int]$p[0], [int]$p[1]) }
        } catch { }
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return New-Object System.Drawing.Point(
        ($wa.Left + [int](($wa.Width - $width) / 2)),
        ($wa.Bottom - $height - 48))
}

$placing = ($Action -eq 'place')

$form = New-Object Sayit.Overlay
$form.ClickThrough = -not $placing
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = Get-Position
$form.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 20)
$form.Opacity = 0.92
$form.TopMost = $true

# Rounded pill shape.
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = $height
$path.AddArc(0, 0, $r, $r, 90, 180)
$path.AddArc(($width - $r), 0, $r, $r, 270, 180)
$path.CloseFigure()
$form.Region = New-Object System.Drawing.Region($path)

$script:level = 0
$script:phase = 0

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'

    # White outline around the pill. Drawn inset by half the pen width, because
    # the form Region clips anything that falls outside the rounded shape.
    $inset = 2.0
    $rr = [float]($height - 2 * $inset)
    $border = New-Object System.Drawing.Drawing2D.GraphicsPath
    $border.AddArc([float]$inset, [float]$inset, $rr, $rr, 90, 180)
    $border.AddArc([float]($width - $inset - $rr), [float]$inset, $rr, $rr, 270, 180)
    $border.CloseFigure()
    $borderPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(255, 230, 237, 243), 2.5)
    $g.DrawPath($borderPen, $border)
    $borderPen.Dispose()
    $border.Dispose()

    $g.TranslateTransform([float]$offsetX, [float]$offsetY)
    $g.ScaleTransform([float]$markScale, [float]$markScale)

    $lvl = [double]$script:level / 7.0

    # A rx=6 corner on a 12-wide bar is a stadium, which a round-capped pen of
    # width 12 draws exactly.
    $pen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(255, 230, 237, 243), 12.0)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    for ($i = 0; $i -lt $bars.Count; $i++) {
        $b = $bars[$i]
        # Per-bar wobble so the mark breathes instead of moving as one block.
        $wobble = 0.88 + 0.12 * [math]::Sin(($script:phase / 2.5) + $i * 1.9)
        $h = $b.H0 + ($b.H7 - $b.H0) * $lvl * $wobble
        if ($h -lt $b.H0) { $h = $b.H0 }

        $cx = $b.X + $b.W / 2.0
        $yTop = $baseline - $h + $b.W / 2.0
        $yBot = $baseline - $b.W / 2.0
        if ($yTop -gt $yBot) { $yTop = $yBot }
        $g.DrawLine($pen, [float]$cx, [float]$yTop, [float]$cx, [float]$yBot)
    }
    $pen.Dispose()

    # The full stop that ends the mark: red while the microphone is open.
    $dot = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(255, 218, 68, 83))
    $g.FillEllipse($dot, 74.0, 62.0, 12.0, 12.0)
    $dot.Dispose()
})

if ($placing) {
    # Placement mode is the one time the window accepts input.
    $form.ClickThrough = $false
    $script:drag = $false
    $script:origin = New-Object System.Drawing.Point(0, 0)
    $form.Add_MouseDown({ param($s, $e) $script:drag = $true; $script:origin = $e.Location })
    $form.Add_MouseMove({
        param($s, $e)
        if ($script:drag) {
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $e.X - $script:origin.X),
                ($form.Location.Y + $e.Y - $script:origin.Y))
        }
    })
    $form.Add_MouseUp({ $script:drag = $false })
    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Return' -or $e.KeyCode -eq 'Escape') {
            Write-Utf8Text -Path $positionFile -Text ("{0},{1}" -f $form.Location.X, $form.Location.Y)
            $form.Close()
        }
    })
    $script:level = 5
    $form.Show()
    $form.Activate()
} else {
    Write-Utf8Text -Path $stateFile -Text '1'
    $form.ShowNoActivate()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    $script:phase++
    if (-not $placing) {
        if (-not (Test-Path -LiteralPath $stateFile)) { $form.Close(); return }
        try {
            $raw = [System.IO.File]::ReadAllText($levelFile)
            $script:level = [int]$raw
        } catch {
            # A missing or half-written level file just means "no update yet".
        }
        $form.KeepOnTop()
    }
    $form.Invalidate()
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    if (-not $placing) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
}
exit 0
