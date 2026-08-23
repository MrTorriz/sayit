# sayit-autostart.ps1 - keeps the push-to-talk trigger running for the session.
#
# Usage:
#   .\sayit-autostart.ps1               supervise until the session ends
#   .\sayit-autostart.ps1 -NoDaemon     do not start the warm model server
#   .\sayit-autostart.ps1 -Seconds 60   supervise for 60 s, then stop and exit
#
# Arguments:
#   -NoDaemon   skip the sayit-daemon.ps1 start that normally runs once at
#               startup; the trigger is supervised either way
#   -Seconds    stop supervising after this many seconds, stop the trigger this
#               run started, and exit. For testing; 0 (the default) never stops
#
# This is the single action of the scheduled task that win\install.ps1
# registers, and it does three things the task cannot do on its own:
#
#   1. It refuses to run twice. A named mutex, not a pid file, so it is released
#      by the kernel when the process dies however it dies.
#   2. It starts the warm daemon without waiting for it. Scheduled task actions
#      run strictly in sequence - action two starts when action one's process
#      exits - and sayit-daemon.ps1 start blocks for up to 15 s while the model
#      loads. As a first action that delay sits in front of the trigger and the
#      push-to-talk button is dead for it. Here the two start together.
#   3. It restarts sayit-trigger.ps1 whenever it exits, and also when it stops
#      answering: the trigger writes a heartbeat from the same loop that pumps
#      the messages its hook rides on, so a process that is alive but no longer
#      pumping is caught too. The scheduled task can only notice that its whole
#      instance ended, and only when its repetition next comes round; this
#      notices an exit in under a second and a wedge within two minutes.
#
# It never starts a second trigger: when one already holds the hook - this
# supervisor's own, or one started by hand - it waits for that one instead. Two
# hooks on the same button fire twice per press, which is worse than none.
#
# What it deliberately does not do: it starts the warm daemon once and never
# again. Restarting it on a schedule would fight anyone who ran
# sayit-daemon.ps1 stop on purpose.
#
# It hides its own console window on startup, because the scheduled task's
# -WindowStyle Hidden only takes effect once the host is already on screen. Set
# SAYIT_KEEP_CONSOLE=1 to watch it run in a terminal instead.
#
# Exit codes:
#   0  Supervised until asked to stop
#   1  The trigger script is missing
#   3  Another supervisor is already running in this session

[CmdletBinding()]
param(
    [int]$Seconds = 0,
    [switch]$NoDaemon
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Hide our own console before anything else runs. The scheduled task launches
# powershell.exe with -WindowStyle Hidden, but the host applies that only after
# it is already on screen, so a console window sits on the desktop from logon
# until something hides it - and nothing did. Note that such a window is not the
# process's MainWindow, so Get-Process reports MainWindowHandle 0 for it while it
# is plainly visible; asking the window manager is the only reliable check.
# SAYIT_KEEP_CONSOLE=1 leaves it alone, for watching this run in a terminal.
if ($env:SAYIT_KEEP_CONSOLE -ne '1') {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Sayit.ConsoleWindow').Type) {
            Add-Type -Namespace Sayit -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $console = [Sayit.ConsoleWindow]::GetConsoleWindow()
        if ($console -ne [IntPtr]::Zero) {
            [void][Sayit.ConsoleWindow]::ShowWindow($console, 0)   # SW_HIDE
        }
    } catch {
        # A host with no console is the outcome this wanted anyway.
    }
}

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

# Session-local, not Global\: both names belong to the logon session, which is
# the scope one desktop's input hook lives in. A second logged-on user gets
# their own supervisor and their own trigger, and neither blocks the other.
$script:SupervisorMutexName = 'Local\sayit-autostart'
$script:TriggerMutexName    = 'Local\sayit-trigger'

$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:TriggerScript = Join-Path $PSScriptRoot 'sayit-trigger.ps1'
$script:DaemonScript  = Join-Path $PSScriptRoot 'sayit-daemon.ps1'
$script:SayitScript   = Join-Path $PSScriptRoot 'sayit.ps1'
$script:LogFile       = Join-Path $script:RunDir 'autostart.log'
$script:BeatFile      = Join-Path $script:RunDir 'trigger.beat'

# How long the trigger may go without writing its heartbeat before this counts
# as dead. It writes one every 5 s from the same loop that pumps the messages
# the hook rides on, so 90 s is not a slow machine - it is a wedged one.
$script:BeatTimeout   = 90

function Write-AutostartLog {
    param([Parameter(Mandatory)][string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 's'), $Text
    Write-Host $line
    # Logging must never take the supervisor down.
    try { Add-Utf8Line -Path $script:LogFile -Line $line } catch { }
}

# The log is appended to for as long as the machine is in use, so cap it on the
# way in rather than letting it grow without end.
function Limit-AutostartLog {
    try {
        if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
        if ((Get-Item -LiteralPath $script:LogFile).Length -le 65536) { return }
        $lines = [System.IO.File]::ReadAllLines($script:LogFile, [System.Text.UTF8Encoding]::new($false))
        $keep  = @($lines | Select-Object -Last 200)
        Write-Utf8Text -Path $script:LogFile -Text (($keep -join "`n") + "`n")
    } catch { }
}

# Take a named mutex without blocking. Returns the mutex when this process now
# owns it, or $null when someone else does. An abandoned mutex - the previous
# owner died without releasing it - counts as ours, which is the whole reason
# for a mutex rather than a pid file.
function Enter-SingleInstance {
    param([Parameter(Mandatory)][string]$Name)
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $owned = $false
    try {
        $owned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) { $mutex.Dispose(); return $null }
    return $mutex
}

# Is some trigger holding the hook right now? The mutex is the authority, but a
# trigger started from a checkout that predates it holds no mutex at all, so
# fall back to looking for the process. -Probe holds no hook worth protecting
# and is excluded on purpose, and so is any -Command host: a shell that merely
# mentions the path on its command line is not a trigger, and treating one as a
# trigger would keep this supervisor waiting for a hook nobody holds.
function Test-TriggerRunning {
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($script:TriggerMutexName)
    } catch {
        $mutex = $null
    }
    if ($null -ne $mutex) {
        $free = $false
        try {
            $free = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $free = $true
        }
        if ($free) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
        if (-not $free) { return $true }
    }
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and
                           $_.CommandLine -match '-File\s+"?[^"]*sayit-trigger\.ps1' -and
                           $_.CommandLine -notmatch '\s-Command\b' -and
                           $_.CommandLine -notmatch '-Probe' -and
                           $_.ProcessId -ne $PID })
        return ($procs.Count -gt 0)
    } catch {
        return $false
    }
}

# CreateNoWindow rather than -WindowStyle Hidden: hidden still creates a console
# window and hides it afterwards, which is the flash you see on the way past.
function Start-SayitChild {
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @()
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $text = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '"'
    foreach ($a in $Arguments) { $text += ' ' + $a }
    $psi.Arguments        = $text
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = $script:WinRoot
    return [System.Diagnostics.Process]::Start($psi)
}

# Seconds since the trigger last said it was pumping messages, or $null when it
# has said nothing at all. Nothing is the answer for a trigger from a checkout
# that predates the heartbeat, and it must not be read as "wedged": this script
# deletes the file before starting a trigger, so a missing file means the trigger
# does not write one, while a stale file means it stopped.
function Get-TriggerBeatAge {
    if (-not (Test-Path -LiteralPath $script:BeatFile)) { return $null }
    try {
        return ((Get-Date) - (Get-Item -LiteralPath $script:BeatFile).LastWriteTime).TotalSeconds
    } catch {
        return $null
    }
}

# A trigger that is killed never runs its own cleanup, so a recording it had
# started would hold the microphone until the recorder's time cap expired.
function Stop-StrayRecording {
    if (-not (Test-Path -LiteralPath $script:SayitScript)) { return }
    try { Start-SayitChild -Script $script:SayitScript -Arguments @('cancel') | Out-Null } catch { }
}

# --- Single instance --------------------------------------------------------

$script:SupervisorMutex = Enter-SingleInstance -Name $script:SupervisorMutexName
if ($null -eq $script:SupervisorMutex) {
    Write-Host 'sayit autostart is already running in this session - nothing to do.'
    exit 3
}

Limit-AutostartLog

if (-not (Test-Path -LiteralPath $script:TriggerScript)) {
    Write-AutostartLog 'autostart: sayit-trigger.ps1 not found - nothing to supervise'
    Write-SayitError 'autostart: sayit-trigger.ps1 not found'
    try { $script:SupervisorMutex.ReleaseMutex() } catch { }
    $script:SupervisorMutex.Dispose()
    exit 1
}

Write-AutostartLog ('autostart: supervising, pid {0}' -f $PID)

# --- Warm daemon ------------------------------------------------------------

if ($NoDaemon) {
    Write-AutostartLog 'autostart: -NoDaemon, leaving the warm daemon alone'
} elseif (-not (Test-Path -LiteralPath $script:DaemonScript)) {
    Write-AutostartLog 'autostart: sayit-daemon.ps1 not found - no warm daemon'
} else {
    # Fire and forget. sayit-daemon.ps1 start is a no-op when the server already
    # answers, and whether it succeeded is sayit-doctor.ps1's business, not this
    # script's: a model server that will not start must never keep the trigger
    # from arming, because dictation still works through the CLI fallback.
    try {
        Start-SayitChild -Script $script:DaemonScript -Arguments @('start') | Out-Null
        Write-AutostartLog 'autostart: warm daemon start requested'
    } catch {
        Write-AutostartLog ('autostart: could not start the warm daemon: {0}' -f $_.Exception.Message)
    }
}

# --- Supervise the trigger --------------------------------------------------

$deadline = [DateTime]::MaxValue
if ($Seconds -gt 0) { $deadline = (Get-Date).AddSeconds($Seconds) }

# Restarting a trigger that fails immediately - a hook Windows refuses to
# install, a missing Trigger.cs - must not turn into a spin. A run that lasted
# means the failure was not immediate, and the backoff drops back to the floor.
$minBackoff = 2
$maxBackoff = 60
$backoff    = $minBackoff

try {
    while ((Get-Date) -lt $deadline) {

        if (Test-TriggerRunning) {
            Write-AutostartLog 'autostart: another trigger holds the hook - waiting for it'
            while ((Get-Date) -lt $deadline -and (Test-TriggerRunning)) { Start-Sleep -Seconds 5 }
            continue
        }

        $startedAt = Get-Date
        $child = $null
        # Clear the previous trigger's last beat, so its age can only ever
        # describe the process this run is about to start.
        Remove-Item -LiteralPath $script:BeatFile -Force -ErrorAction SilentlyContinue
        try {
            $child = Start-SayitChild -Script $script:TriggerScript
        } catch {
            Write-AutostartLog ('autostart: could not start the trigger: {0}' -f $_.Exception.Message)
            Write-SayitError 'autostart: could not start the trigger'
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, $maxBackoff)
            continue
        }

        Write-AutostartLog ('autostart: trigger started, pid {0}' -f $child.Id)

        $lastBeatCheck = Get-Date
        while (-not $child.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (((Get-Date) - $lastBeatCheck).TotalSeconds -lt 15) { continue }
            $lastBeatCheck = Get-Date
            $age = Get-TriggerBeatAge
            if ($null -ne $age -and $age -gt $script:BeatTimeout) {
                Write-AutostartLog ('autostart: trigger pid {0} has not answered for {1:N0} s - restarting it' -f `
                    $child.Id, $age)
                Write-SayitError 'autostart: the trigger stopped responding'
                try { $child.Kill() } catch { }
                try { $child.WaitForExit(5000) | Out-Null } catch { }
            }
        }

        if (-not $child.HasExited) {
            # -Seconds expired. This run started the trigger, so this run stops
            # it: a test that left one behind would be the second hook.
            Write-AutostartLog ('autostart: -Seconds reached, stopping trigger pid {0}' -f $child.Id)
            try { $child.Kill() } catch { }
            try { $child.WaitForExit(5000) | Out-Null } catch { }
            Stop-StrayRecording
            $child.Dispose()
            break
        }

        $code   = $child.ExitCode
        $ranFor = ((Get-Date) - $startedAt).TotalSeconds
        $child.Dispose()

        if ($code -ne 0) { Write-SayitError ('autostart: trigger exited with {0}' -f $code) }
        Stop-StrayRecording

        if ($ranFor -ge 30) { $backoff = $minBackoff }

        # Invariant formatting: N0 under a Swedish locale inserts a non-breaking
        # space as the thousands separator, which lands in the log as a mangled
        # byte - "1 246 s" became "1<?>246 s" - and makes the number unreadable
        # exactly when a long-running trigger has just died and you want it.
        Write-AutostartLog ('autostart: trigger exited with {0} after {1} s - restarting in {2} s' -f `
            $code, ([int]$ranFor).ToString([System.Globalization.CultureInfo]::InvariantCulture), $backoff)
        Start-Sleep -Seconds $backoff

        if ($ranFor -lt 30) { $backoff = [Math]::Min($backoff * 2, $maxBackoff) }
    }
} finally {
    Write-AutostartLog ('autostart: supervisor pid {0} exiting' -f $PID)
    try { $script:SupervisorMutex.ReleaseMutex() } catch { }
    try { $script:SupervisorMutex.Dispose() } catch { }
}

exit 0
