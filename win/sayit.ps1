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
#   Stopping signals a named event instead of sending a signal. The recorder
#   then finalises its own RIFF header, so there is no need to poll for process
#   exit to avoid reading a half-written file.
#
# A session is still claimed atomically, because hold-to-talk still generates
# racy press and release pairs.

[CmdletBinding()]
param([Parameter(Position = 0)][string]$Action = 'toggle')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

$sessionFile = Join-Path $script:RunDir 'sayit.session'
$historyFile = Join-Path $script:DataDir 'history.jsonl'

$cfg = Import-DotEnv
$indicatorOn = (Get-Setting -Env $cfg -Name 'RECORDING_INDICATOR' -Default '1') -ne '0'

function Show-Indicator {
    param([string]$State)
    if (-not $indicatorOn) { return }
    $script = Join-Path $PSScriptRoot 'sayit-indicator.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,$State | Out-Null
    } catch { }
}

function Get-Session {
    if (-not (Test-Path -LiteralPath $sessionFile)) { return $null }
    try {
        $parts = (Read-Utf8Text -Path $sessionFile).Trim() -split "`t"
        if ($parts.Count -lt 4) { return $null }
        return [pscustomobject]@{
            ProcessId = [int]$parts[0]
            Wav       = $parts[1]
            Start     = [double]::Parse($parts[2], [System.Globalization.CultureInfo]::InvariantCulture)
            EventName = $parts[3]
        }
    } catch { return $null }
}

# Claim by rename: exactly one stop or cancel can win a session.
function Claim-Session {
    $claimed = "$sessionFile.claimed.$PID"
    try {
        [System.IO.File]::Move($sessionFile, $claimed)
    } catch { return $null }
    try {
        $parts = ([System.IO.File]::ReadAllText($claimed)).Trim() -split "`t"
        Remove-Item -LiteralPath $claimed -Force -ErrorAction SilentlyContinue
        if ($parts.Count -lt 4) { return $null }
        return [pscustomobject]@{
            ProcessId = [int]$parts[0]
            Wav       = $parts[1]
            Start     = [double]::Parse($parts[2], [System.Globalization.CultureInfo]::InvariantCulture)
            EventName = $parts[3]
        }
    } catch { return $null }
}

# A session is live only if the recorded pid is still a recorder for this WAV.
function Test-RecorderAlive {
    param($Session)
    if (-not $Session) { return $false }
    $proc = Get-Process -Id $Session.ProcessId -ErrorAction SilentlyContinue
    return [bool]$proc
}

function Stop-Recorder {
    param($Session)
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($Session.EventName)
        $ev.Set() | Out-Null
        $ev.Dispose()
    } catch {
        # No event means the recorder is already gone.
    }
    for ($i = 0; $i -lt 200; $i++) {
        if (-not (Get-Process -Id $Session.ProcessId -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 20
    }
    Get-Process -Id $Session.ProcessId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Recording {
    Write-Mark 'start.enter'

    $existing = Get-Session
    if ($existing -and (Test-RecorderAlive $existing)) { return 0 }
    if ($existing) { Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue }

    # Clean up anything older than an hour that a crash left behind.
    Get-ChildItem -LiteralPath $script:RunDir -Filter 'sayit-*.wav' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $eventName = "Local\sayit-stop-$PID"
    $wav = Join-Path $script:RunDir "sayit-$PID.wav"
    $recorder = Join-Path $PSScriptRoot 'sayit-record.ps1'
    $start = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0

    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$recorder,
                      '-OutFile',$wav,'-StopEvent',$eventName

    Write-Mark 'record.spawned' $proc.Id

    # Invariant formatting: under a Swedish locale a bare double renders with a
    # decimal comma, which reads back as garbage and silently zeroes the duration.
    $startText = $start.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $line = @($proc.Id, $wav, $startText, $eventName) -join "`t"
    Write-Utf8Text -Path "$sessionFile.tmp.$PID" -Text $line
    [System.IO.File]::Move("$sessionFile.tmp.$PID", $sessionFile)
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
    $session = Claim-Session
    if (-not $session) { Show-Indicator 'hide'; return 0 }
    Write-Mark 'session.claimed'

    Show-Indicator 'hide'
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

    Write-Mark 'transcribe.begin'
    $transcriber = Join-Path $PSScriptRoot 'sayit-transcribe.ps1'
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $text = ''
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait -PassThru `
            -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$transcriber,$session.Wav `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($proc.ExitCode -eq 0) {
            $text = (Read-Utf8Text -Path $stdout)
        } else {
            Write-SayitError "stop: transcribe exit $($proc.ExitCode)"
        }
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $session.Wav -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $text) { $text = '' }
    $text = $text.Trim()
    Write-Mark 'transcribe.end' $text.Length

    if (-not $text) { return 0 }

    # Injected in-process rather than by spawning sayit-inject.ps1: the spawn cost
    # roughly a second, which was a quarter of the release-to-text latency.
    . "$PSScriptRoot\lib\inject.ps1"
    $threshold = [int](Get-Setting -Env $cfg -Name 'INJECT_CLIPBOARD_THRESHOLD' -Default '100')
    $method    = Get-Setting -Env $cfg -Name 'INJECT_METHOD' -Default 'auto'
    Invoke-TextInjection -Text $text -Threshold $threshold -Method $method | Out-Null
    Write-Mark 'inject.end'

    # history.jsonl: same field names, order and types as the Linux side, so a
    # history file is portable between the two.
    $seconds = [math]::Round($end - $session.Start, 2)
    if ($seconds -lt 0) { $seconds = 0.0 }
    $words = ($text -split '\s+' | Where-Object { $_ -ne '' }).Count
    $entry = [ordered]@{
        time    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
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
        if ($session -and (Test-RecorderAlive $session)) { exit (Stop-Recording) }
        exit (Start-Recording)
    }
    default {
        Write-Error "Usage: sayit.ps1 [start|stop|cancel|toggle|doctor]"
        exit 1
    }
}
