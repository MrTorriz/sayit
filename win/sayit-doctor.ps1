# sayit-doctor.ps1 - read-only diagnostics for the Windows recording path.
#
# Usage:
#   .\sayit-doctor.ps1            full report
#   .\sayit-doctor.ps1 -Quiet     only warnings, failures and the summary
#
# Arguments:
#   -Quiet   suppress the ok/info lines; warnings, failures and the result stay
#
# Behaviour:
#   - Changes nothing. It starts no recording, opens no capture stream, writes
#     no setting and touches no state file. Enumerating capture devices uses
#     waveInGetDevCaps only, which reports what the driver exposes without
#     opening the device.
#   - Resolves AUDIO_SOURCE the same way sayit-record.ps1 does, and says
#     plainly when a configured device is not among the ones Windows reports.
#   - Reports the resolved paths and numbers from .env. It never prints .env
#     itself, and never prints INITIAL_PROMPT or SUPPRESS_REGEX, which hold
#     user-written text - only whether they are set.
#
# Exit codes:
#   0  Nothing required is missing (warnings may still be present)
#   1  At least one required piece is missing

[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

# Device names carry non-ASCII characters on a localised system.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:Failures = 0
$script:Warnings = 0

function Write-Section { param([string]$Title) if (-not $Quiet) { "`n$Title" } }
function Write-Ok      { param([string]$Text)  if (-not $Quiet) { "  ok    $Text" } }
function Write-Info    { param([string]$Text)  if (-not $Quiet) { "  --    $Text" } }
function Write-Warn    { param([string]$Text)  "  warn  $Text"; $script:Warnings++ }
function Write-Fail    { param([string]$Text)  "  FAIL  $Text"; $script:Failures++ }
# Continuation of the line above: printed, never counted twice.
function Write-More    { param([string]$Text)  "        $Text" }

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -ge 1073741824) { return [string]::Format($inv, '{0:F1} GB', $Bytes / 1073741824) }
    if ($Bytes -ge 1048576)    { return [string]::Format($inv, '{0:F1} MB', $Bytes / 1048576) }
    if ($Bytes -ge 1024)       { return [string]::Format($inv, '{0:F1} kB', $Bytes / 1024) }
    return "$Bytes B"
}

$cfg = Import-DotEnv

$repoModel = Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin'
$repoVad   = Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin'
$defaultCli    = Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp\build-vulkan\bin\Release\whisper-cli.exe'
$defaultServer = Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp\build-vulkan\bin\Release\whisper-server.exe'

$cliPath     = Get-Setting -Env $cfg -Name 'WHISPER_CLI'      -Default $defaultCli
$serverPath  = Get-Setting -Env $cfg -Name 'WHISPER_SERVER'   -Default $defaultServer
$model       = Get-Setting -Env $cfg -Name 'MODEL_PATH'       -Default $repoModel
$vad         = Get-Setting -Env $cfg -Name 'VAD_MODEL'        -Default $repoVad
$language    = Get-Setting -Env $cfg -Name 'SPEECH_LANGUAGE'  -Default 'sv'
$threads     = Get-Setting -Env $cfg -Name 'THREADS'          -Default '6'
$beam        = Get-Setting -Env $cfg -Name 'BEAM'             -Default '5'
$port        = Get-Setting -Env $cfg -Name 'DAEMON_PORT'      -Default '9876'
$audioSource = Get-Setting -Env $cfg -Name 'AUDIO_SOURCE'     -Default ''
# The four VAD tuning settings, with the same defaults lib\transcribe.ps1 uses.
# They are sent with every request, so they need no daemon restart.
$vadPad      = Get-Setting -Env $cfg -Name 'VAD_SPEECH_PAD_MS'  -Default '250'
$vadThresh   = Get-Setting -Env $cfg -Name 'VAD_THRESHOLD'      -Default '0.30'
$vadMinSp    = Get-Setting -Env $cfg -Name 'VAD_MIN_SPEECH_MS'  -Default '0'
$vadMinSil   = Get-Setting -Env $cfg -Name 'VAD_MIN_SILENCE_MS' -Default '300'
$wordlist    = Get-Setting -Env $cfg -Name 'WORDLIST'         -Default (Join-Path $script:ConfigDir 'wordlist.tsv')
$trigger     = Get-Setting -Env $cfg -Name 'TRIGGER_BUTTON'   -Default 'XBUTTON2'
$suppressKey = Get-Setting -Env $cfg -Name 'TRIGGER_SUPPRESS' -Default '1'
$injectHow   = Get-Setting -Env $cfg -Name 'INJECT_METHOD'    -Default 'auto'
$injectAt    = Get-Setting -Env $cfg -Name 'INJECT_CLIPBOARD_THRESHOLD' -Default '100'
$maxRecord   = Get-Setting -Env $cfg -Name 'MAX_RECORD_SECONDS' -Default '120'
$typingWpm   = Get-Setting -Env $cfg -Name 'TYPING_WPM'       -Default '40'
$prompt      = Get-Setting -Env $cfg -Name 'INITIAL_PROMPT'   -Default ''
$suppressRx  = Get-Setting -Env $cfg -Name 'SUPPRESS_REGEX'   -Default ''

# --- whisper.cpp binaries ---------------------------------------------------

Write-Section 'whisper.cpp'

$haveCli    = Test-Path -LiteralPath $cliPath
$haveServer = Test-Path -LiteralPath $serverPath

if ($haveCli) {
    Write-Ok "whisper-cli: $cliPath"
} else {
    Write-Warn "whisper-cli missing: $cliPath"
    Write-More 'the CLI fallback is unavailable - run win\install.ps1'
}

if ($haveServer) {
    Write-Ok "whisper-server: $serverPath"
} else {
    Write-Warn "whisper-server missing: $serverPath"
    Write-More 'the warm daemon cannot be started - run win\install.ps1'
}

if (-not $haveCli -and -not $haveServer) {
    Write-Fail 'no transcription backend at all: neither whisper-cli nor whisper-server exists'
}

# --- Backend ----------------------------------------------------------------

Write-Section 'Compute backend'

$binDir = $null
if ($haveCli)         { $binDir = Split-Path -Parent $cliPath }
elseif ($haveServer)  { $binDir = Split-Path -Parent $serverPath }

if ($null -eq $binDir) {
    Write-Info 'no build directory to inspect - nothing is built yet'
} else {
    # ggml-vulkan.dll is produced only by a -DGGML_VULKAN=ON build and is loaded
    # from beside the executable, so its presence there is what decides whether
    # this build can use the GPU.
    $vulkanDll = Join-Path $binDir 'ggml-vulkan.dll'
    if (Test-Path -LiteralPath $vulkanDll) {
        Write-Ok "Vulkan backend present: $vulkanDll"
    } else {
        Write-Warn 'no ggml-vulkan.dll beside the binaries - this is a CPU-only build'
        Write-More 'transcription still works, just slower. To get GPU support,'
        Write-More 'install the Vulkan SDK and re-run: .\win\install.ps1 -Rebuild'
    }
    # install.ps1 records what it built in the checkout root; the binaries sit a
    # few directories below it, and how many depends on the generator.
    $probe = $binDir
    for ($i = 0; $i -lt 4 -and $probe; $i++) {
        $info = Join-Path $probe '.sayit-build-info'
        if (Test-Path -LiteralPath $info) {
            foreach ($line in (Get-Content -LiteralPath $info)) { Write-Info "build $line" }
            break
        }
        $probe = Split-Path -Parent $probe
    }
}

# --- Models -----------------------------------------------------------------

Write-Section 'Models'

if (Test-Path -LiteralPath $model) {
    $size = (Get-Item -LiteralPath $model).Length
    Write-Ok ("model: {0} ({1})" -f $model, (Format-Size $size))
} else {
    Write-Fail "model missing: $model"
    Write-More 'the model is supplied separately and belongs in the repo models\ directory'
}

if ($vad -and (Test-Path -LiteralPath $vad)) {
    $size = (Get-Item -LiteralPath $vad).Length
    Write-Ok ("VAD model: {0} ({1})" -f $vad, (Format-Size $size))
} else {
    Write-Warn "VAD model missing: $vad"
    Write-More 'voice activity detection stays off, which makes hallucinated text on'
    Write-More 'silence more likely; transcription itself is unaffected'
}

# --- Warm daemon ------------------------------------------------------------

Write-Section 'Warm daemon'

$daemonUp = $false
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $daemonUp = $client.ConnectAsync('127.0.0.1', [int]$port).Wait(500)
    $client.Close()
} catch {
    $daemonUp = $false
}

if ($daemonUp) {
    Write-Ok "answers on 127.0.0.1:$port"
} else {
    Write-Warn "nothing answers on 127.0.0.1:$port"
    Write-More 'the first dictation falls back to whisper-cli and loads the model'
    Write-More 'each time. Start it with: .\win\sayit-daemon.ps1 start'
}

# --- Autostart --------------------------------------------------------------

Write-Section 'Autostart'

# Only powershell.exe running the script with -File counts. Never a -Probe run:
# probe mode installs a hook but suppresses nothing and starts no dictation.
# Never a -Command host either: a shell that merely names the path - this
# script's own parent, for one - is not the trigger.
function Get-SayitHostProcess {
    param([Parameter(Mandatory)][string]$Script)
    $pattern = '-File\s+"?[^"]*' + [regex]::Escape($Script)
    try {
        # The leading comma keeps the array an array on the way out. Without it
        # a single match is returned as one CimInstance, whose .Count is not 1
        # but $null - a property that class does not have - and every count
        # below would silently take the wrong branch.
        return ,@(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and
                           $_.CommandLine -match $pattern -and
                           $_.CommandLine -notmatch '\s-Command\b' -and
                           $_.CommandLine -notmatch '-Probe' })
    } catch {
        return $null
    }
}

$taskName = 'sayit'
$task = $null
try { $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { $task = $null }

if ($null -eq $task) {
    Write-Info "no scheduled task named '$taskName' - nothing starts sayit at logon"
    Write-More 'register one with: .\win\install.ps1 -SkipBuild -SkipModel'
} else {
    if ($task.State -eq 'Disabled') {
        Write-Warn "the scheduled task '$taskName' is registered but disabled - it will not start"
        Write-More "enable it with: Enable-ScheduledTask -TaskName '$taskName'"
    } else {
        Write-Ok ("scheduled task '{0}' is registered, state {1}" -f $taskName, $task.State)
    }

    $taskXml = ''
    try { $taskXml = (Export-ScheduledTask -TaskName $taskName) -join "`n" } catch { $taskXml = '' }
    # The task's action is the .vbs launcher; a task that names the .ps1 directly
    # still supervises, but leaves a console window on screen at logon.
    if ($taskXml -match 'sayit-autostart\.ps1') {
        Write-Warn 'the task starts the supervisor through powershell.exe'
        Write-More 'a console window sits on the desktop from logon until it is hidden.'
        Write-More 'Update it with:'
        Write-More '.\win\install.ps1 -SkipBuild -SkipModel'
    } elseif ($taskXml -notmatch 'sayit-autostart\.vbs') {
        Write-Warn 'the task predates win\sayit-autostart and does not supervise the trigger'
        Write-More 'a trigger that dies stays dead until the next logon. Update it with:'
        Write-More '.\win\install.ps1 -SkipBuild -SkipModel'
    }
    if ($taskXml -notmatch '(?s)<TimeTrigger>.*?<Repetition>') {
        Write-Warn 'the task has no repeating trigger, so nothing restarts it if it dies'
        Write-More 'update it with: .\win\install.ps1 -SkipBuild -SkipModel'
    }

    $info = $null
    try { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue } catch { $info = $null }
    if ($null -ne $info) {
        $result = [uint32]$info.LastTaskResult
        # 0 is the normal result: the task's action is a launcher that starts the
        # supervisor and exits at once, so each repeat finishes cleanly whether or
        # not it had anything to do - a repeat that finds a live supervisor is
        # turned away by the supervisor's own mutex, not by the scheduler.
        # 0x800710E0 appears instead on a task registered before that change,
        # where the action was the supervisor itself and the scheduler refused
        # the repeat. Neither is a fault.
        $meaning = switch ($result) {
            0          { 'the last run finished cleanly' }
            267009     { 'an instance is running now' }
            267011     { 'it has not run yet' }
            267014     { 'the last run was stopped by hand' }
            2147946720 { 'a repeat was refused because one instance was already running - normal' }
            4294967295 { 'the last run was killed' }
            default    { 'see the task history for what it means' }
        }
        Write-Info ("LastTaskResult 0x{0:X8} - {1}" -f $result, $meaning)
        Write-Info ("last run {0}, next run {1}" -f $info.LastRunTime, $info.NextRunTime)
    }
}

$supervisors = Get-SayitHostProcess -Script 'sayit-autostart.ps1'
if ($null -eq $supervisors) {
    Write-Info 'could not enumerate processes, so the supervisor was not checked'
} elseif ($supervisors.Count -eq 1) {
    Write-Ok ("supervisor running (pid {0})" -f $supervisors[0].ProcessId)
} elseif ($supervisors.Count -eq 0) {
    Write-Warn 'no sayit-autostart.ps1 supervisor is running'
    Write-More 'nothing will restart the trigger if it exits. Start it with:'
    Write-More ".\win\sayit-autostart.ps1   (or: Start-ScheduledTask -TaskName '$taskName')"
} else {
    # The supervisor takes a named mutex, so this should be unreachable.
    Write-Warn ("{0} supervisors are running: pid {1}" -f `
        $supervisors.Count, (($supervisors | ForEach-Object { $_.ProcessId }) -join ', '))
}

$triggers = Get-SayitHostProcess -Script 'sayit-trigger.ps1'
if ($null -eq $triggers) {
    Write-Info 'could not enumerate processes, so the trigger was not checked'
} elseif ($triggers.Count -eq 1) {
    Write-Ok ("trigger armed (pid {0})" -f $triggers[0].ProcessId)
} elseif ($triggers.Count -eq 0) {
    Write-Warn 'no trigger process is running - the push-to-talk button does nothing'
    Write-More 'with the task registered it comes back within a minute; start it now with:'
    Write-More '.\win\sayit-trigger.ps1'
} else {
    Write-Fail ("{0} trigger processes are running: pid {1}" -f `
        $triggers.Count, (($triggers | ForEach-Object { $_.ProcessId }) -join ', '))
    Write-More 'two hooks on the same button start and stop the dictation twice per'
    Write-More 'press. Stop all but one:'
    Write-More ("Stop-Process -Id {0}" -f (($triggers | ForEach-Object { $_.ProcessId }) -join ','))
}

if ($daemonUp) {
    Write-Ok "warm daemon answering on 127.0.0.1:$port"
} else {
    Write-Info "warm daemon not answering - dictation falls back to whisper-cli (see above)"
}

$autostartLog = Join-Path $script:RunDir 'autostart.log'
if (Test-Path -LiteralPath $autostartLog) {
    $last = @(Get-Content -LiteralPath $autostartLog -Tail 1)
    if ($last.Count -gt 0) { Write-Info ("last supervisor log line: {0}" -f $last[0]) }
}

# --- Capture devices --------------------------------------------------------

Write-Section 'Capture devices'

$devices = $null
if (-not ('Sayit.Recorder' -as [type])) {
    $cs = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\Recorder.cs')
    if (-not $cs) {
        Write-Fail 'lib\Recorder.cs not found - the checkout is incomplete'
    } else {
        try {
            Add-Type -TypeDefinition $cs -Language CSharp
        } catch {
            Write-Fail ("lib\Recorder.cs did not compile: {0}" -f $_.Exception.Message)
        }
    }
}

if ('Sayit.Recorder' -as [type]) {
    try {
        $devices = [Sayit.Recorder]::ListDevices()
    } catch {
        Write-Fail ("could not enumerate capture devices: {0}" -f $_.Exception.Message)
    }
}

if ($null -ne $devices) {
    if ($devices.Count -eq 0) {
        Write-Fail 'Windows reports no capture device at all - recording cannot work'
    } else {
        foreach ($d in $devices) {
            Write-Info ("[{0}] {1}" -f $d.Index, $d.Name)
            if ($d.EndpointId) { Write-More "      $($d.EndpointId)" }
        }
        # waveInMessage is documented to return an endpoint ID per device, but on
        # some drivers it returns nothing at all. Only advertise the endpoint ID
        # as a selector when this machine actually produced one.
        if ($devices | Where-Object { $_.EndpointId }) {
            Write-Info 'AUDIO_SOURCE accepts the endpoint ID above, which is stable,'
            Write-Info 'or the name, which the API truncates at 31 characters'
        } else {
            Write-Info 'this driver reports no endpoint ID, so AUDIO_SOURCE has to match'
            Write-Info 'on name - exactly, or as a substring either way round. The API'
            Write-Info 'truncates names at 31 characters, and a name can change when'
            Write-Info 'the device is renamed or reconnected'
        }
        # Only endpoints reach this list, and a vendor audio suite can be the
        # only endpoint on the machine.
        Write-Info 'only what Windows exposes as a capture endpoint can be selected here.'
        Write-Info 'A virtual device from a vendor audio suite can be the only endpoint,'
        Write-Info 'with the physical microphone behind it not exposed at all. Which'
        Write-Info 'microphone that one carries is decided in that software, not by'
        Write-Info 'AUDIO_SOURCE'

        if (-not $audioSource) {
            Write-Ok 'AUDIO_SOURCE is empty - recording uses the Windows default capture device'
            Write-More 'which device that is follows the Sound settings, not sayit'
        } else {
            $index = [Sayit.Recorder]::ResolveDevice($audioSource)
            if ($index -eq -2) {
                Write-Fail "AUDIO_SOURCE matches no capture device Windows reports: $audioSource"
                Write-More 'recording will refuse to start until it matches or is cleared'
            } else {
                $match = $devices | Where-Object { $_.Index -eq $index } | Select-Object -First 1
                if ($match) {
                    Write-Ok ("AUDIO_SOURCE resolves to [{0}] {1}" -f $match.Index, $match.Name)
                } else {
                    Write-Ok "AUDIO_SOURCE resolves to device index $index"
                }
            }
        }
    }
}

# --- Settings ---------------------------------------------------------------

Write-Section 'Resolved settings'

Write-Info "SPEECH_LANGUAGE            $language"
Write-Info "THREADS                    $threads"
Write-Info "BEAM                       $beam"
Write-Info "DAEMON_PORT                $port"
Write-Info "VAD_SPEECH_PAD_MS          $vadPad"
Write-Info "VAD_THRESHOLD              $vadThresh"
Write-Info "VAD_MIN_SPEECH_MS          $vadMinSp"
Write-Info "VAD_MIN_SILENCE_MS         $vadMinSil"
Write-Info "MAX_RECORD_SECONDS         $maxRecord"
Write-Info "TYPING_WPM                 $typingWpm"
Write-Info "TRIGGER_BUTTON             $trigger"
Write-Info "TRIGGER_SUPPRESS           $suppressKey"
Write-Info "INJECT_METHOD              $injectHow"
Write-Info "INJECT_CLIPBOARD_THRESHOLD $injectAt"
Write-Info "WORDLIST                   $wordlist"
# Values withheld on purpose: both hold text the user wrote.
if ($prompt)     { Write-Info 'INITIAL_PROMPT             set' }    else { Write-Info 'INITIAL_PROMPT             empty' }
if ($suppressRx) { Write-Info 'SUPPRESS_REGEX             set' }    else { Write-Info 'SUPPRESS_REGEX             empty' }

if (Test-Path -LiteralPath $wordlist) {
    $rules = 0
    foreach ($line in [System.IO.File]::ReadAllLines($wordlist, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line.IndexOf("`t") -ge 1) { $rules++ }
    }
    Write-Ok "wordlist present with $rules rule(s)"
} else {
    Write-Info 'no wordlist yet - transcriptions are used as whisper produced them'
}

$envFile = Join-Path $script:RepoRoot '.env'
if (Test-Path -LiteralPath $envFile) {
    Write-Ok '.env found (its contents are never printed)'
} else {
    Write-Info 'no .env - every setting above is a built-in default. Run win\install.ps1'
}

# --- Leftover state ---------------------------------------------------------

Write-Section 'Session state'

$sessionFile = Join-Path $script:RunDir 'sayit.session'
$livePid = 0
if (Test-Path -LiteralPath $sessionFile) {
    # Parsed and identity-checked by the same helpers the state machine uses. A
    # live pid is not enough: Windows reuses pids, so a stale session file can
    # name a process that has nothing to do with sayit, and calling that a
    # recording in progress would invite the reader to kill an innocent process.
    $session = $null
    try { $session = ConvertFrom-SessionLine -Line (Read-Utf8Text -Path $sessionFile) } catch { $session = $null }
    if ($null -eq $session) {
        Write-Warn "unreadable session file: $sessionFile"
        Write-More "remove it with: Remove-Item -LiteralPath '$sessionFile'"
    } elseif (Test-SessionRecorder -Session $session) {
        $livePid = $session.ProcessId
        Write-Info ("a recording is in progress (pid {0})" -f $session.ProcessId)
        if ($session.ProcessStart -eq 0) {
            Write-More 'written by an older version, so only the pid identifies it'
        }
    } else {
        Write-Warn "stale session file: $sessionFile names no live recorder"
        Write-More "remove it with: Remove-Item -LiteralPath '$sessionFile'"
    }
} else {
    Write-Ok 'no leftover recording session'
}

# Recorders run as powershell.exe hosting sayit-record.ps1, so the command line
# is what identifies them. A recorder that no session claims is an orphan: it
# still holds the microphone until MAX_RECORD_SECONDS expires.
try {
    $recorders = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'sayit-record\.ps1' })
    $orphans = @($recorders | Where-Object { $_.ProcessId -ne $livePid })
    if ($orphans.Count -eq 0) {
        Write-Ok 'no orphaned recorder process'
    } else {
        Write-Warn ("{0} recorder process(es) with no session: pid {1}" -f `
            $orphans.Count, (($orphans | ForEach-Object { $_.ProcessId }) -join ', '))
        Write-More 'each one stops by itself at MAX_RECORD_SECONDS, or now with:'
        Write-More ("Stop-Process -Id {0}" -f (($orphans | ForEach-Object { $_.ProcessId }) -join ','))
    }
} catch {
    Write-Info 'could not enumerate processes, so orphaned recorders were not checked'
}

$wavs = @(Get-ChildItem -LiteralPath $script:RunDir -Filter 'sayit-*.wav' -ErrorAction SilentlyContinue)
if ($wavs.Count -eq 0) {
    Write-Ok 'no leftover WAV files in the run directory'
} else {
    $bytes = 0
    foreach ($w in $wavs) { $bytes += $w.Length }
    Write-Warn ("{0} leftover WAV file(s) in {1} ({2}) - they hold recorded audio" -f `
        $wavs.Count, $script:RunDir, (Format-Size ([long]$bytes)))
    Write-More 'sayit.ps1 deletes the ones older than an hour when the next'
    Write-More 'recording starts; delete them now with:'
    Write-More ("Remove-Item -LiteralPath '{0}\sayit-*.wav'" -f $script:RunDir)
}

# --- Platform limits --------------------------------------------------------

Write-Section 'Platform limits'

Write-Info 'These are properties of Windows, not defects, and no setting changes them:'
Write-Info '  - the low-level input hook behind the push-to-talk trigger, and the'
Write-Info '    synthetic input used to type or paste, do not work while a window'
Write-Info '    running at a higher integrity level has focus. With such a window'
Write-Info '    in front, the trigger does not fire, and text that was already'
Write-Info '    transcribed is left on the clipboard to paste manually.'
Write-Info '  - the recording indicator cannot appear over an exclusive-fullscreen'
Write-Info '    application, or on the UAC secure desktop.'

# --- Result -----------------------------------------------------------------

Write-Section 'Result'
"  {0} failure(s), {1} warning(s)" -f $script:Failures, $script:Warnings

if ($script:Failures -gt 0) { exit 1 }
exit 0
