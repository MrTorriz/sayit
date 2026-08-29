# sayit-indicator.ps1 - the on-screen recording indicator.
#
# Usage:
#   .\sayit-indicator.ps1 show    show the pill and keep it up (blocks)
#   .\sayit-indicator.ps1 hide    turn the lamp off; a resident pill stays up
#   .\sayit-indicator.ps1 stop    close a resident pill
#   .\sayit-indicator.ps1 place   move and resize it; Enter or Escape saves
#
# In 'place' mode:
#   drag the middle      move the pill
#   drag either end      resize it, keeping the opposite end anchored
#   arrow keys           nudge one pixel
#   + and -              resize in steps, 0 returns to the standard size
#   Enter or Escape      save position and size, and close
#
# The size is one scale factor, not a width and a height: the pill has a fixed
# proportion and is never stretched out of it. Position and scale are saved
# together in the overlay-position file.
#
# Arguments:
#   -Managed   with 'show': the caller owns the state file's lifetime and the
#              pill closes with it, instead of staying up for the session.
#              sayit.ps1 passes it because this process is far slower to start
#              than a short dictation is to finish: a hide issued while it was
#              still starting would be undone the moment it got around to
#              writing the file, and the pill would then stay on screen.
#
# The pill is resident and always on top
# -------------------------------------
# A pill stands from logon for the whole session, not only while a recording
# runs. The scheduled logon task starts it, the same way it starts the daemon.
#
# It also stays on one layer. The Linux side tried the other way first: a
# resting pill was put on a lower layer so it would not cover a fullscreen
# video, and raised while recording. A desktop panel shares that layer and
# stacking within one layer follows map order, so the pill was visible at rest
# or hidden behind the panel depending on which surface was mapped last. It
# read as a broken pill rather than as a layer policy. The price - a resting
# pill sits over fullscreen video too - is real and accepted: a fixture that is
# only sometimes a fixture is worse than one that is always there.
#
# So TopMost is set once, at creation, and nothing in the state path touches it
# again. Only the lamp's colour and the meter's geometry change with the state.
#
# The mark IS the meter: the bars follow your voice level and the lamp burns red
# while the microphone is open. The level comes from the recorder, which has
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
param(
    [Parameter(Position = 0)][ValidateSet('show', 'hide', 'stop', 'place')][string]$Action = 'show',
    [switch]$Managed
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\indicator-geometry.ps1"
Initialize-SayitDirs

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# The lamp follows this file: it exists exactly while the microphone is open.
$stateFile    = Join-Path $script:RunDir 'indicator.on'
# A resident pill closes when this appears, and deletes it on the way out.
$quitFile     = Join-Path $script:RunDir 'indicator.quit'
$levelFile    = Join-Path $script:RunDir 'level'
$positionFile = Join-Path $script:ConfigDir 'overlay-position'

if ($Action -eq 'hide') {
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    exit 0
}

if ($Action -eq 'stop') {
    Write-Utf8Text -Path $quitFile -Text '1'
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

        // Keeps the pill out of screen captures, screen shares and recordings.
        // Windows 10 2004 is the first build that honours EXCLUDEFROMCAPTURE;
        // on anything older the call fails and the window is simply captured.
        private const uint WDA_NONE              = 0x00000000;
        private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")]
        private static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

        public bool ClickThrough = true;

        public Overlay()
        {
            // The mark is repainted about twelve times a second while the
            // microphone is open. Without double buffering WinForms clears the
            // background and then draws on screen, so the bars are visibly
            // missing for part of every frame - which reads as flicker.
            // OptimizedDoubleBuffer draws into an off-screen bitmap and copies
            // the finished frame in one go; UserPaint and AllPaintingInWmPaint
            // are what stop the separate background erase that causes it.
            this.SetStyle(ControlStyles.OptimizedDoubleBuffer |
                          ControlStyles.UserPaint |
                          ControlStyles.AllPaintingInWmPaint, true);
            this.UpdateStyles();
        }

        /// Returns false when the OS refused, so the caller can say so rather
        /// than promise a privacy property the window does not have.
        public bool ExcludeFromCapture(bool exclude)
        {
            try
            {
                return SetWindowDisplayAffinity(this.Handle,
                    exclude ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
            }
            catch { return false; }
        }

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
        /// within it, so this is re-issued while visible. It does not depend on
        /// the recording state and must never be called from the state path:
        /// the layer is the same whether the microphone is open or shut.
        public void KeepOnTop()
        {
            SetWindowPos(this.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

# --- one pill at a time -----------------------------------------------------
# A resident pill is already up when sayit.ps1 spawns one for a dictation. The
# second process must not draw a second pill on top of the first, so it takes a
# named mutex and leaves quietly if it loses. The resident pill then shows the
# recording through its lamp, which is what the state file is for.
#
# A named mutex rather than a pid file, so the OS releases it if the process
# dies. The same pattern sayit-autostart.ps1 uses for the supervisor.
function Get-IndicatorMutex {
    param([string]$Name = 'Local\sayit-indicator')

    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $owned = $false
    try {
        $owned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # The previous holder died without releasing it. It is ours now.
        $owned = $true
    }
    if (-not $owned) { $mutex.Dispose(); return $null }
    return $mutex
}

$placing = ($Action -eq 'place')

# Placement opens a window on purpose, even beside a resident pill, so it is the
# one case that does not compete for the mutex.
$mutex = $null
if (-not $placing) {
    $mutex = Get-IndicatorMutex
    if ($null -eq $mutex) { exit 0 }
}

# --- size -------------------------------------------------------------------
# The scale multiplies the whole pill, so it keeps its proportions and the mark
# keeps its position inside it at any size. The geometry itself is defined in
# lib\indicator-geometry.ps1 in unscaled pill pixels.
#
# Three sources, most specific first: the size dragged out in 'place' mode,
# INDICATOR_SCALE in .env, then 1.0. What the user set by hand on screen wins
# over a setting they may have written months ago.
# MinScale and MaxScale come from lib\indicator-geometry.ps1.
$cfg = Import-DotEnv
$script:scale = 1.0
$raw = Get-Setting -Env $cfg -Name 'INDICATOR_SCALE' -Default '1.0'
$parsed = 0.0
if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float,
                       [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and
    $parsed -ge $script:MinScale -and $parsed -le $script:MaxScale) {
    $script:scale = $parsed
}

# Reading and writing the file itself. The parsing and formatting live in
# lib\indicator-geometry.ps1 so the tests can exercise them without a window.
function Get-SavedLayout {
    if (-not (Test-Path -LiteralPath $positionFile)) { return $null }
    try {
        return ConvertFrom-SayitLayout -Text (Read-Utf8Text -Path $positionFile)
    } catch { return $null }
}

function Save-Layout {
    param([int]$X, [int]$Y, [double]$Scale)
    Write-Utf8Text -Path $positionFile -Text (
        ConvertTo-SayitLayout -X $X -Y $Y -Scale $Scale)
}

$sparat = Get-SavedLayout
if ($null -ne $sparat -and $null -ne $sparat.Scale) { $script:scale = $sparat.Scale }

$width  = [int][math]::Round($script:PillWidth  * $script:scale)
$height = [int][math]::Round($script:PillHeight * $script:scale)

function Get-Position {
    if ($null -ne $sparat) {
        return New-Object System.Drawing.Point($sparat.X, $sparat.Y)
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return New-Object System.Drawing.Point(
        ($wa.Left + [int](($wa.Width - $width) / 2)),
        ($wa.Bottom - $height - 48))
}

$form = New-Object Sayit.Overlay
$form.ClickThrough = -not $placing
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = Get-Position
$form.BackColor = [System.Drawing.Color]::Black

# Opacity is load-bearing, and it must stay below 1.0. CreateParams forces
# WS_EX_LAYERED, and a layered window draws nothing until something calls
# SetLayeredWindowAttributes for it. WinForms makes that call from the Opacity
# setter - but only when the value is less than 1.0; at exactly 1.0 it decides
# no layer is needed and skips it, while the forced style stays on. The result
# is a window that is created, reports itself visible, sits at the right
# coordinates with the right size, paints without error into its own bitmap -
# and never appears on screen. Verified by showing three pills side by side at
# 1.0, 0.99 and 0.92: only the lower two were visible.
#
# 0.99 is the practical maximum, and is indistinguishable from solid.
$form.Opacity = 0.99

# TopMost is set here, once, and never again. Nothing in the state path may
# assign it: the pill sits on one layer whatever the microphone is doing.
$form.TopMost = $true

# The pill shape, so the corners are transparent rather than black.
$shape = New-SayitPillPath -Width $width -Height $height -Radius ($script:PillRadius * $scale)
$form.Region = New-Object System.Drawing.Region($shape)
$shape.Dispose()

# Recording state. $micOpen drives the lamp alone; $level drives the bars alone.
# Placement records nothing, so it starts unlit whatever the state file says.
if ($placing) {
    $script:micOpen = $false
} else {
    $script:micOpen = Test-Path -LiteralPath $stateFile
}
$script:level = 0.0

function New-RgbColor {
    param([double[]]$Rgb)
    return [System.Drawing.Color]::FromArgb(255,
        [int][math]::Round($Rgb[0] * 255),
        [int][math]::Round($Rgb[1] * 255),
        [int][math]::Round($Rgb[2] * 255))
}

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'

    $g.ScaleTransform([float]$scale, [float]$scale)

    $ink = New-RgbColor -Rgb $script:InkRgb

    # The pill: black fill, white border. The border is drawn inset by half its
    # width, because the form Region clips anything outside the rounded shape.
    $inset = $script:PillBorder / 2.0
    $pill = New-SayitPillPath -Width $script:PillWidth -Height $script:PillHeight `
                              -Radius $script:PillRadius -Inset $inset
    $fill = New-Object System.Drawing.SolidBrush((New-RgbColor -Rgb $script:PillRgb))
    $g.FillPath($fill, $pill)
    $fill.Dispose()
    $pen = New-Object System.Drawing.Pen($ink, [float]$script:PillBorder)
    $g.DrawPath($pen, $pill)
    $pen.Dispose()
    $pill.Dispose()

    # The lamp. Always drawn, always the same size and place: only the colour
    # carries the state, so an unlit pill still reads as a lamp that is off
    # rather than as a pill with a hole in it.
    $lampRgb = if ($script:micOpen) { $script:LampLit } else { $script:LampUnlit }
    $lamp = Get-SayitLampRect
    $lampBrush = New-Object System.Drawing.SolidBrush((New-RgbColor -Rgb $lampRgb))
    $g.FillEllipse($lampBrush, [float]$lamp.X, [float]$lamp.Y,
                   [float]$lamp.Diameter, [float]$lamp.Diameter)
    $lampBrush.Dispose()

    # The meter. Rounded capsules grown symmetrically about the pill's centre
    # line, not up from a baseline: at rest the row is a line of dots level with
    # the lamp, and speaking opens it out in both directions.
    $barBrush = New-Object System.Drawing.SolidBrush($ink)
    foreach ($b in (Get-SayitBarRects -Level $script:level)) {
        $bar = New-SayitPillPath -Width $b.Width -Height $b.Height -Radius $b.Radius
        $state = $g.Save()
        $g.TranslateTransform([float]$b.X, [float]$b.Y)
        $g.FillPath($barBrush, $bar)
        $g.Restore($state)
        $bar.Dispose()
    }
    $barBrush.Dispose()

    # The wordmark, from stored outlines. No font is loaded at runtime.
    $wm = Get-SayitWordmarkOrigin
    $wmPath = New-SayitWordmarkPath -X $wm.X -Y $wm.Y -Height $wm.Height
    $wmBrush = New-Object System.Drawing.SolidBrush($ink)
    $g.FillPath($wmBrush, $wmPath)
    $wmBrush.Dispose()
    $wmPath.Dispose()
})

if ($placing) {
    # Placement mode is the one time the window accepts input. It records
    # nothing, so the lamp stays unlit: a window that is not recording must
    # never show a lit lamp.
    #
    # Drag the middle to move it, drag either end to resize it. The pill has one
    # fixed proportion, so a resize is a scale and not a stretch: the width the
    # user drags out sets the scale, and the height follows. Resizing from the
    # left edge also moves the window, so the end under the pointer is the one
    # that stays put - otherwise the pill appears to run away from the mouse.
    $form.ClickThrough = $false

    # How far in from each end counts as a resize grip. Scaled, so the grip
    # stays proportionally the same target on a pill dragged out to 4x.
    $script:GripWidth = [int][math]::Max(10, [math]::Round(14 * $script:scale))

    $script:mode = 'none'          # none | move | left | right
    $script:origin = New-Object System.Drawing.Point(0, 0)
    $script:startBounds = $form.Bounds

    function Get-Zone {
        param([int]$X)
        if ($X -le $script:GripWidth) { return 'left' }
        if ($X -ge ($form.Width - $script:GripWidth)) { return 'right' }
        return 'move'
    }

    # Applies a new scale and keeps the chosen edge anchored.
    function Set-PillScale {
        param([double]$NewScale, [string]$Anchor)

        $NewScale = Get-SayitClampedScale -Scale $NewScale

        $w = [int][math]::Round($script:PillWidth  * $NewScale)
        $h = [int][math]::Round($script:PillHeight * $NewScale)

        $x = $form.Location.X
        $y = $form.Location.Y
        if ($Anchor -eq 'left') {
            # Dragging the left edge: the right edge is what must not move.
            $x = $script:startBounds.Right - $w
        }
        # The vertical centre stays where it was, so the pill grows about its
        # own middle rather than downwards from its top.
        $y = $script:startBounds.Top + [int](($script:startBounds.Height - $h) / 2)

        $script:scale = $NewScale
        $form.Size = New-Object System.Drawing.Size($w, $h)
        $form.Location = New-Object System.Drawing.Point($x, $y)

        $shape = New-SayitPillPath -Width $w -Height $h -Radius ($script:PillRadius * $NewScale)
        $gammal = $form.Region
        $form.Region = New-Object System.Drawing.Region($shape)
        $shape.Dispose()
        if ($null -ne $gammal) { $gammal.Dispose() }
        $form.Invalidate()
    }

    $form.Add_MouseDown({
        param($s, $e)
        $script:mode = Get-Zone -X $e.X
        $script:origin = $form.PointToScreen($e.Location)
        $script:startBounds = $form.Bounds
    })

    $form.Add_MouseMove({
        param($s, $e)
        if ($script:mode -eq 'none') {
            # Not dragging: the cursor says what this end of the pill would do.
            switch (Get-Zone -X $e.X) {
                'left'  { $form.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
                'right' { $form.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
                default { $form.Cursor = [System.Windows.Forms.Cursors]::SizeAll }
            }
            return
        }

        $nu = $form.PointToScreen($e.Location)
        $dx = $nu.X - $script:origin.X
        $dy = $nu.Y - $script:origin.Y

        if ($script:mode -eq 'move') {
            $form.Location = New-Object System.Drawing.Point(
                ($script:startBounds.Left + $dx), ($script:startBounds.Top + $dy))
            return
        }

        # Resize. Dragging the right edge outwards widens; dragging the left
        # edge outwards means a negative dx, hence the sign flip.
        $bredd = $script:startBounds.Width
        if ($script:mode -eq 'right') { $bredd += $dx } else { $bredd -= $dx }
        Set-PillScale -NewScale ($bredd / $script:PillWidth) -Anchor $script:mode
    })

    $form.Add_MouseUp({ $script:mode = 'none' })

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        # Arrow keys nudge by one pixel, so the pill can be lined up exactly.
        switch ($e.KeyCode) {
            'Left'  { $form.Location = New-Object System.Drawing.Point(($form.Location.X - 1), $form.Location.Y); return }
            'Right' { $form.Location = New-Object System.Drawing.Point(($form.Location.X + 1), $form.Location.Y); return }
            'Up'    { $form.Location = New-Object System.Drawing.Point($form.Location.X, ($form.Location.Y - 1)); return }
            'Down'  { $form.Location = New-Object System.Drawing.Point($form.Location.X, ($form.Location.Y + 1)); return }
            'Oemplus'      { $script:startBounds = $form.Bounds; Set-PillScale -NewScale ($script:scale + 0.1) -Anchor 'right'; return }
            'Add'          { $script:startBounds = $form.Bounds; Set-PillScale -NewScale ($script:scale + 0.1) -Anchor 'right'; return }
            'OemMinus'     { $script:startBounds = $form.Bounds; Set-PillScale -NewScale ($script:scale - 0.1) -Anchor 'right'; return }
            'Subtract'     { $script:startBounds = $form.Bounds; Set-PillScale -NewScale ($script:scale - 0.1) -Anchor 'right'; return }
            'D0'           { $script:startBounds = $form.Bounds; Set-PillScale -NewScale 1.0 -Anchor 'right'; return }
        }
        if ($e.KeyCode -eq 'Return' -or $e.KeyCode -eq 'Escape') {
            Save-Layout -X $form.Location.X -Y $form.Location.Y -Scale $script:scale
            $form.Close()
        }
    })
    # A level that shows the meter open, so the pill can be placed by its real
    # size rather than by its resting one.
    $script:level = 5.0
    $form.Show()
    $form.Activate()
} else {
    if ($Managed -and -not (Test-Path -LiteralPath $stateFile)) {
        Write-Utf8Text -Path $stateFile -Text '1'
        $script:micOpen = $true
    }
    Remove-Item -LiteralPath $quitFile -Force -ErrorAction SilentlyContinue
    $form.ShowNoActivate()
}

# Keep the pill out of screen shares and recordings. Applied after the handle
# exists, because the affinity is a property of the window, not of its style.
# The return value is ignored on purpose: an older Windows build refuses, and a
# visible indicator is a far better outcome than no indicator at all.
if ((Get-Setting -Env $cfg -Name 'INDICATOR_EXCLUDE_FROM_CAPTURE' -Default '1') -ne '0') {
    $form.ExcludeFromCapture($true) | Out-Null
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    if (-not $placing) {
        if (Test-Path -LiteralPath $quitFile) { $form.Close(); return }

        $open = Test-Path -LiteralPath $stateFile
        # A managed pill belongs to one dictation and goes when it does. A
        # resident one stays up and just puts its lamp out.
        if ($Managed -and -not $open) { $form.Close(); return }
        $script:micOpen = $open

        if ($open) {
            try {
                $script:level = [double][int]([System.IO.File]::ReadAllText($levelFile))
            } catch {
                # A missing or half-written level file means "no update yet".
            }
        } else {
            $script:level = 0.0
        }

        # Re-asserted every tick, never in response to a state change: the pill
        # holds one layer whatever the microphone is doing.
        $form.KeepOnTop()
    }
    $form.Invalidate()
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    $timer.Dispose()
    Remove-Item -LiteralPath $quitFile -Force -ErrorAction SilentlyContinue
    if ($Managed) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
    if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
exit 0
