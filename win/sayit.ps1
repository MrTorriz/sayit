# sayit.ps1 - session state machine: record, transcribe, inject.
#
# Usage:
#   .\sayit.ps1            toggle
#   .\sayit.ps1 start      hold-mode: on button press
#   .\sayit.ps1 stop       hold-mode: on button release
#   .\sayit.ps1 cancel     discard the current recording
#   .\sayit.ps1 doctor     read-only check of the recording path
#
# Exit codes: 0 normal flow (including an empty result),
#             1 unknown argument, or the recorder failed to start
#
# Differences from the Linux implementation, and why:
#
#   No Bluetooth profile switching. Windows selects HFP automatically when an
#   application opens a capture endpoint, so the whole sayit-bt stage, its state
#   file and the intent marker that covered the switch window do not exist here.
#
#   Stopping signals a named event instead of sending a signal, so the recorder
#   finalises its own RIFF header rather than being cut off mid-write. Killing it
#   is the last resort and costs the whole recording: the header is written with
#   a zero length first and only corrected on the way out.
#
# A session is still claimed atomically, because hold-to-talk still generates
# racy press and release pairs. Claiming alone is not enough here, where every
# press and every release is a separate PowerShell process: a release can reach
# its claim before the press has written the session file at all. A named mutex
# therefore serialises the start against the claim, so a release always finds
# the session its own press created.

[CmdletBinding()]
param([Parameter(Position = 0)][string]$Action = 'toggle')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

$sessionFile   = Join-Path $script:RunDir 'sayit.session'
$indicatorFile = Join-Path $script:RunDir 'indicator.on'
$historyFile   = Join-Path $script:DataDir 'history.jsonl'

$cfg = Import-DotEnv
$indicatorOn = (Get-Setting -Env $cfg -Name 'RECORDING_INDICATOR' -Default '1') -ne '0'

# Only one process at a time may start a session or claim one. A named mutex
# rather than a lock file, because the OS releases a named mutex by itself when
# its holder dies: a process killed mid-session cannot wedge every dictation
# that follows.
function Enter-SessionLock {
    $m = New-Object System.Threading.Mutex($false, 'Local\sayit-session')
    try {
        if (-not $m.WaitOne(15000)) { $m.Dispose(); return $null }
    } catch [System.Threading.AbandonedMutexException] {
        # The previous holder died holding it; ownership passes to us.
    }
    return $m
}

function Exit-SessionLock {
    param($Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

# The indicator's state file is written and removed here, under the session
# lock, rather than by the indicator process itself. Spawning the script for
# 'hide' finished long before the indicator got as far as creating the file, so
# any dictation shorter than about a second used to hide before it had shown and
# left the pill on screen. Not spawning also takes a process start off the
# release-to-text path.
function Show-Indicator {
    param([string]$State)
    if (-not $indicatorOn) { return }
    if ($State -eq 'hide') {
        Remove-Item -LiteralPath $indicatorFile -Force -ErrorAction SilentlyContinue
        return
    }
    $script = Join-Path $PSScriptRoot 'sayit-indicator.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    try {
        Write-Utf8Text -Path $indicatorFile -Text '1'
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                          '-File',(Format-ProcessArgument $script),
                          (Format-ProcessArgument $State),'-Managed' | Out-Null
    } catch { }
}

function Get-Session {
    if (-not (Test-Path -LiteralPath $sessionFile)) { return $null }
    try {
        return (ConvertFrom-SessionLine -Line (Read-Utf8Text -Path $sessionFile))
    } catch { return $null }
}

# Claim by rename: exactly one stop or cancel can win a session.
function Claim-Session {
    $claimed = "$sessionFile.claimed.$PID"
    try {
        [System.IO.File]::Move($sessionFile, $claimed)
    } catch { return $null }
    try {
        $line = [System.IO.File]::ReadAllText($claimed)
        Remove-Item -LiteralPath $claimed -Force -ErrorAction SilentlyContinue
        return (ConvertFrom-SessionLine -Line $line)
    } catch { return $null }
}

function Stop-Recorder {
    param($Session)

    # The recorder creates its stop event a moment after it is spawned, so a
    # quick release can reach this before the event exists. Absence is therefore
    # not evidence that the recorder is gone, and treating it as such fell
    # straight through to the kill below - which loses the recording, because
    # the RIFF header is only finalised on the way out and still claims zero
    # data bytes. Keep asking while the process is alive instead.
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $ev = [System.Threading.EventWaitHandle]::OpenExisting($Session.EventName)
            $ev.Set() | Out-Null
            $ev.Dispose()
            break
        } catch { }
        # Nothing to open yet. Checking the process costs a moment, so it only
        # happens on this path, never on the release-to-text path that succeeds
        # on the first attempt.
        if (-not (Test-SessionRecorder $Session)) { return }
        Start-Sleep -Milliseconds 20
    }

    # The WAV is whole as soon as the recorder closes it, which it announces on a
    # second event named after the stop event. Waiting for the process to exit as
    # well would put its whole PowerShell teardown - measured at 122-300 ms - on
    # every dictation, for a file that is already complete on disk.
    try {
        $done = [System.Threading.EventWaitHandle]::OpenExisting("$($Session.EventName)-done")
        try {
            if ($done.WaitOne(4000)) { return }
        } finally { $done.Dispose() }
    } catch {
        # No such event: a recorder from before this existed. Fall back to the
        # exit poll below, which is what guaranteed a complete file then.
    }

    for ($i = 0; $i -lt 200; $i++) {
        if (-not (Test-SessionRecorder $Session)) { return }
        Start-Sleep -Milliseconds 20
    }

    if ($Session.ProcessStart -eq 0) {
        # An unverifiable session, so the pid is a number and nothing more.
        # Killing on that alone is how an unrelated process gets shot; the
        # recorder's own time cap has to end this one instead.
        Write-SayitError 'stop: recorder identity unverifiable, not forcing it'
        return
    }
    Get-Process -Id $Session.ProcessId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Recording {
    Write-Mark 'start.enter'
    $lock = Enter-SessionLock
    if (-not $lock) {
        Write-SayitError 'start: session lock timed out'
        return 0
    }
    try {
        return (Start-RecordingLocked)
    } finally {
        Exit-SessionLock $lock
    }
}

function Start-RecordingLocked {
    $existing = Get-Session
    if ($existing -and (Test-SessionRecorder $existing)) { return 0 }
    # Everything else here is stale: a dead recorder, or a file too damaged for
    # Get-Session to parse. Both have to go, because the commit below refuses to
    # overwrite an existing session file, and that failure would abort with the
    # recorder already spawned and nothing left able to stop it.
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue

    # Clean up anything older than an hour that a crash left behind.
    Get-ChildItem -LiteralPath $script:RunDir -Filter 'sayit-*.wav' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $eventName = "Local\sayit-stop-$PID"
    $wav = Join-Path $script:RunDir "sayit-$PID.wav"
    $recorder = Join-Path $PSScriptRoot 'sayit-record.ps1'
    $start = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0

    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                      '-File',(Format-ProcessArgument $recorder),
                      '-OutFile',(Format-ProcessArgument $wav),
                      '-StopEvent',(Format-ProcessArgument $eventName)

    Write-Mark 'record.spawned' $proc.Id

    # The recorder's own creation time goes into the session as well: a pid on
    # its own is a number Windows will hand out again, and everything that later
    # signals or kills this recorder has to be sure it is still this recorder.
    [long]$procStart = 0
    try { $procStart = $proc.StartTime.ToFileTimeUtc() } catch { }

    # Invariant formatting: under a Swedish locale a bare double renders with a
    # decimal comma, which reads back as garbage and silently zeroes the duration.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $startText = $start.ToString($inv)
    $line = @($proc.Id, $wav, $startText, $eventName, $procStart.ToString($inv)) -join "`t"
    try {
        Write-Utf8Text -Path "$sessionFile.tmp.$PID" -Text $line
        [System.IO.File]::Move("$sessionFile.tmp.$PID", $sessionFile)
    } catch {
        # A recorder no session names is a recorder holding the microphone until
        # its own time cap expires, so stop it here rather than let the error out.
        Remove-Item -LiteralPath "$sessionFile.tmp.$PID" -Force -ErrorAction SilentlyContinue
        Stop-Recorder ([pscustomobject]@{ ProcessId = $proc.Id; EventName = $eventName; ProcessStart = $procStart })
        Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
        Write-SayitError 'start: could not commit the session file'
        Write-Error 'Recording failed to start - the session file could not be written.'
        return 1
    }
    Write-Mark 'session.written'

    Start-Sleep -Milliseconds 300
    if ($proc.HasExited) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
        Show-Indicator 'hide'
        Write-SayitError 'start: recorder exited immediately'
        Write-Error 'Recording failed to start - check the microphone.'
        return 1
    }

    Show-Indicator 'show'
    return 0
}

function Stop-Recording {
    param([switch]$Discard)

    Write-Mark 'stop.enter'
    # Held across the claim only. Transcription takes seconds, and the press that
    # begins the next dictation must not have to wait behind it.
    $lock = Enter-SessionLock
    $session = $null
    try {
        $session = Claim-Session
        Show-Indicator 'hide'
    } finally {
        Exit-SessionLock $lock
    }
    if (-not $session) { return 0 }
    Write-Mark 'session.claimed'

    Stop-Recorder $session
    Write-Mark 'record.stopped'
    $end = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0

    if ($Discard) {
        Remove-Item -LiteralPath $session.Wav -Force -ErrorAction SilentlyContinue
        return 0
    }

    if (-not (Test-Path -LiteralPath $session.Wav)) {
        Write-SayitError 'stop: no wav produced'
        return 0
    }

    # Transcribed in-process rather than by spawning sayit-transcribe.ps1, for the
    # same reason the injection below is: the spawn alone cost 377, 622 and 386 ms
    # on three measured dictations, before the daemon had even been contacted.
    # sayit-transcribe.ps1 remains the command-line front end to this same engine.
    Write-Mark 'transcribe.begin'
    $text = ''
    try {
        . "$PSScriptRoot\lib\transcribe.ps1"
        $text = Convert-WavToText -Path $session.Wav -Settings (New-TranscribeSettings -Env $cfg)
    } catch {
        Write-SayitError "stop: transcribe failed ($($_.Exception.Message))"
    } finally {
        Remove-Item -LiteralPath $session.Wav -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $text) { $text = '' }
    $text = $text.Trim()
    Write-Mark 'transcribe.end' $text.Length

    if (-not $text) { return 0 }

    # Injected in-process rather than by spawning sayit-inject.ps1: the spawn cost
    # roughly a second, which was a quarter of the release-to-text latency.
    #
    # Delivery is allowed to fail. The history entry written below is then the
    # only remaining record of what was said, so a failure here must not take it
    # down as well.
    try {
        . "$PSScriptRoot\lib\inject.ps1"
        $threshold = [int](Get-Setting -Env $cfg -Name 'INJECT_CLIPBOARD_THRESHOLD' -Default '100')
        $method    = Get-Setting -Env $cfg -Name 'INJECT_METHOD' -Default 'auto'
        Invoke-TextInjection -Text $text -Threshold $threshold -Method $method | Out-Null
    } catch {
        Write-SayitError "stop: inject failed ($($_.Exception.Message))"
    }
    Write-Mark 'inject.end'

    # history.jsonl: same field names, order and types as the Linux side, so a
    # history file is portable between the two.
    #
    # Invariant formatting again: ':' in a custom date format is the culture's
    # time separator rather than a literal, and fourteen cultures render it as a
    # full stop. sayit-history.ps1 parses this field with an exact invariant
    # pattern, so a localised stamp drops the entry from every -Period silently.
    $seconds = [math]::Round($end - $session.Start, 2)
    if ($seconds -lt 0) { $seconds = 0.0 }
    $words = ($text -split '\s+' | Where-Object { $_ -ne '' }).Count
    $entry = [ordered]@{
        time    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        seconds = $seconds
        words   = $words
        text    = $text
    }
    Add-Utf8Line -Path $historyFile -Line ($entry | ConvertTo-Json -Compress)
    Write-Mark 'history.done'
    return 0
}

switch ($Action.ToLowerInvariant()) {
    'start'  { exit (Start-Recording) }
    'stop'   { exit (Stop-Recording) }
    'cancel' { exit (Stop-Recording -Discard) }
    'doctor' {
        $doctor = Join-Path $PSScriptRoot 'sayit-doctor.ps1'
        if (Test-Path -LiteralPath $doctor) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctor
            exit $LASTEXITCODE
        }
        Write-Error 'sayit-doctor.ps1 not found'; exit 1
    }
    'toggle' {
        $session = Get-Session
        if ($session -and (Test-SessionRecorder $session)) { exit (Stop-Recording) }
        exit (Start-Recording)
    }
    default {
        Write-Error "Usage: sayit.ps1 [start|stop|cancel|toggle|doctor]"
        exit 1
    }
}
