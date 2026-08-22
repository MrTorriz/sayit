# transcribe.ps1 - shared WAV-to-text engine, dot-sourced by sayit.ps1 and by
# sayit-transcribe.ps1.
#
# It lives here rather than only in sayit-transcribe.ps1 for the same reason
# lib\inject.ps1 does: a dictation should not have to start a second PowerShell
# to get its own text back. Measured on this machine from transcribe.begin to
# t.daemon.begin across three real dictations, that spawn cost 377, 622 and
# 386 ms before the daemon had even been contacted.
#
# The contract is the Linux one: the warm daemon first, whisper-cli only when
# the daemon fails to answer, and an empty answer from a healthy daemon is a
# final "no speech" rather than a reason to try again.
#
# Requires lib\common.ps1 to have been dot-sourced already.

# Settings that reach whisper as numbers are normalised here rather than passed
# through as written. Both the daemon (std::stof) and the CLI parse in the C
# locale, where "0,30" reads as 30 - and 30 as a VAD threshold silences every
# dictation. A value the invariant culture rejects is therefore retried in the
# user's own culture, and what goes out is always invariant.
function ConvertTo-InvariantNumber {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Default,
        [switch]$Integer
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    # Float rather than Integer even for the whole-number settings, so that a
    # written 250.4 rounds instead of being discarded for the default. And
    # deliberately not AllowThousands: with it, invariant parsing accepts "0,30"
    # and returns 30, which is exactly the misreading this function exists for.
    $styles = [System.Globalization.NumberStyles]::Float

    foreach ($candidate in @($Value, $Default)) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        $text = $candidate.Trim()
        [double]$parsed = 0
        if ([double]::TryParse($text, $styles, $inv, [ref]$parsed) -or
            [double]::TryParse($text, $styles, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed)) {
            if ($Integer) { return ([int][math]::Round($parsed)).ToString($inv) }
            return $parsed.ToString('0.####', $inv)
        }
    }
    return $Default
}

# Every setting the two transcription paths need, resolved once.
#
# The VAD defaults are not whisper's. whisper.cpp v1.9.2 ends a speech segment
# at the first 32 ms frame scoring below threshold - 0.15 and stores that frame
# as the end (src\whisper.cpp, whisper_vad_segments_from_probs), so only
# vad_speech_pad_ms puts any audio back. With whisper's own 0.5 and 30 ms the
# tail is cut some 30-62 ms after the last confident frame, which is inside the
# 80-150 ms a Swedish unvoiced final (-t, -s, -st, -rt) occupies: the end of the
# sentence goes missing. Raising the silence duration does not help, because it
# only delays when the segment is closed, not where it ends.
#
# vad_min_speech_duration_ms is a correctness setting rather than a quality one:
# any segment shorter than it is deleted outright, and a request whose segments
# all vanish returns an empty transcription with no error at all - a one-word
# answer disappearing into what looks like a successful silent dictation.
function New-TranscribeSettings {
    param([Parameter(Mandatory)][hashtable]$Env)

    $repoModel = Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin'
    $repoVad   = Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin'
    $port      = Get-Setting -Env $Env -Name 'DAEMON_PORT' -Default '9876'

    return [pscustomobject]@{
        Model     = Get-Setting -Env $Env -Name 'MODEL_PATH'      -Default $repoModel
        Language  = Get-Setting -Env $Env -Name 'SPEECH_LANGUAGE' -Default 'sv'
        Threads   = Get-Setting -Env $Env -Name 'THREADS'         -Default '6'
        Beam      = Get-Setting -Env $Env -Name 'BEAM'            -Default '5'
        Prompt    = Get-Setting -Env $Env -Name 'INITIAL_PROMPT'  -Default ''
        Vad       = Get-Setting -Env $Env -Name 'VAD_MODEL'       -Default $repoVad
        Suppress  = Get-Setting -Env $Env -Name 'SUPPRESS_REGEX'  -Default ''
        Wordlist  = Get-Setting -Env $Env -Name 'WORDLIST' -Default (Join-Path $script:ConfigDir 'wordlist.tsv')
        CliPath   = Get-Setting -Env $Env -Name 'WHISPER_CLI' `
                        -Default (Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp\build-vulkan\bin\Release\whisper-cli.exe')
        DaemonUrl = "http://127.0.0.1:$port/inference"

        VadThreshold   = ConvertTo-InvariantNumber -Value (Get-Setting -Env $Env -Name 'VAD_THRESHOLD')      -Default '0.30'
        VadMinSpeechMs = ConvertTo-InvariantNumber -Value (Get-Setting -Env $Env -Name 'VAD_MIN_SPEECH_MS')  -Default '0'   -Integer
        VadMinSilenceMs= ConvertTo-InvariantNumber -Value (Get-Setting -Env $Env -Name 'VAD_MIN_SILENCE_MS') -Default '300' -Integer
        VadSpeechPadMs = ConvertTo-InvariantNumber -Value (Get-Setting -Env $Env -Name 'VAD_SPEECH_PAD_MS')  -Default '250' -Integer
    }
}

function Invoke-WhisperDaemon {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Settings
    )

    # Deadline scales with audio length: 16 kHz mono 16-bit is 32000 bytes/s.
    $bytes = (Get-Item -LiteralPath $Path).Length
    $deadline = [int]($bytes / 32000) + 10

    Add-Type -AssemblyName System.Net.Http
    $handler  = New-Object System.Net.Http.HttpClientHandler
    $client   = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($deadline)
    $response = $null
    try {
        $content = New-Object System.Net.Http.MultipartFormDataContent
        $fileBytes = [System.IO.File]::ReadAllBytes($Path)
        # The comma keeps PowerShell from splatting the byte array into separate
        # constructor arguments.
        $fileContent = New-Object System.Net.Http.ByteArrayContent(, $fileBytes)
        $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($Path))
        $content.Add((New-Object System.Net.Http.StringContent($Settings.Language)), 'language')
        # Sent even when empty, so a prompt from an earlier request is cleared.
        $content.Add((New-Object System.Net.Http.StringContent($Settings.Prompt)), 'prompt')
        $content.Add((New-Object System.Net.Http.StringContent('text')), 'response_format')

        # token_timestamps defaults to !no_timestamps on the server, and having
        # them on is also what activates the 60-character segment wrap
        # (examples\server\server.cpp: max_len defaults to 60). Neither is of any
        # use here - the text format never carries a timestamp - so this asks for
        # neither rather than working around the wrap afterwards.
        $content.Add((New-Object System.Net.Http.StringContent('true')), 'no_timestamps')

        # Per request, so a changed VAD setting needs no daemon restart.
        $content.Add((New-Object System.Net.Http.StringContent($Settings.VadThreshold)),    'vad_threshold')
        $content.Add((New-Object System.Net.Http.StringContent($Settings.VadMinSpeechMs)),  'vad_min_speech_duration_ms')
        $content.Add((New-Object System.Net.Http.StringContent($Settings.VadMinSilenceMs)), 'vad_min_silence_duration_ms')
        $content.Add((New-Object System.Net.Http.StringContent($Settings.VadSpeechPadMs)),  'vad_speech_pad_ms')

        try {
            $response = $client.PostAsync($Settings.DaemonUrl, $content).GetAwaiter().GetResult()
        } catch [System.Threading.Tasks.TaskCanceledException] {
            # Distinct from a refused connection: the daemon took the request and
            # is still working on it. The caller still falls back to the CLI,
            # because the alternative is losing what was said, but the log has to
            # separate the two - this one means the model is struggling, not that
            # the daemon is down.
            throw "daemon did not answer within $deadline s"
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "daemon returned HTTP $([int]$response.StatusCode)"
        }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Invoke-WhisperCli {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Settings
    )

    if (-not (Test-Path -LiteralPath $Settings.CliPath)) {
        throw "whisper-cli missing: $($Settings.CliPath) - run install.ps1"
    }
    if (-not (Test-Path -LiteralPath $Settings.Model)) {
        throw "Model missing: $($Settings.Model) - run install.ps1"
    }

    $cliArgs = @('-m', $Settings.Model, '-l', $Settings.Language, '-t', $Settings.Threads,
                 '-bs', $Settings.Beam, '-fa', '-sns', '-nt', '-np')
    # The same VAD settings as the daemon request, so the fallback does not cut
    # sentence ends the warm path keeps.
    if ($Settings.Vad -and (Test-Path -LiteralPath $Settings.Vad)) {
        $cliArgs += @('--vad', '-vm', $Settings.Vad,
                      '-vt',   $Settings.VadThreshold,
                      '-vspd', $Settings.VadMinSpeechMs,
                      '-vsd',  $Settings.VadMinSilenceMs,
                      '-vp',   $Settings.VadSpeechPadMs)
    }
    if ($Settings.Prompt)   { $cliArgs += @('--prompt', $Settings.Prompt) }
    # whisper-cli suppresses these at the token level, which the daemon cannot do
    # at all; Convert-WavToText removes what is left from the text of both paths.
    if ($Settings.Suppress) { $cliArgs += @('--suppress-regex', $Settings.Suppress) }
    $cliArgs += @('-f', $Path)

    # Start-Process with file redirection rather than a 2>$null pipeline: in
    # Windows PowerShell 5.1 redirecting a native command's stderr wraps every
    # line in an error record, which would turn whisper's progress chatter into
    # a spurious failure.
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $Settings.CliPath -ArgumentList $cliArgs -NoNewWindow -PassThru `
                              -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        # -PassThru and WaitForExit rather than -Wait: -Wait costs about 0.9 s of
        # pure waiting in Windows PowerShell 5.1 (measured 1010-1040 ms against
        # 135-150 ms for this). Reading the handle first is what keeps ExitCode
        # readable afterwards - without it the property comes back empty and
        # every run would look like a success. Both streams go to files, so there
        # is no pipe left undrained while waiting.
        $null = $proc.Handle
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "whisper-cli exited $($proc.ExitCode)" }
        return (Read-Utf8Text -Path $stdout)
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

# WAV in, finished text out. Throws only when neither path produced anything; an
# empty string is a legitimate result and means no speech.
function Convert-WavToText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Settings
    )

    Write-Mark 't.daemon.begin'
    $raw = $null
    $daemonError = $null
    try {
        $raw = Invoke-WhisperDaemon -Path $Path -Settings $Settings
        Write-Mark 't.daemon.end' '0'
    } catch {
        $daemonError = $_.Exception.Message
        Write-Mark 't.daemon.end' '1'
    }

    # Only a daemon that failed to answer reaches the CLI. An empty answer from a
    # healthy daemon is a string, not $null, and is final.
    if ($null -eq $raw) {
        Write-Mark 't.cli.begin'
        try {
            $raw = Invoke-WhisperCli -Path $Path -Settings $Settings
            Write-Mark 't.cli.end' '0'
        } catch {
            Write-Mark 't.cli.end' '1'
            Write-SayitError "transcribe: daemon ($daemonError), cli ($($_.Exception.Message))"
            throw "transcription failed: daemon ($daemonError), CLI fallback failed ($($_.Exception.Message))"
        }
        Write-SayitError "transcribe: fell back to the CLI ($daemonError)"
    }
    if ($null -eq $raw) { $raw = '' }

    # Normalisation, always applied.
    $raw = [regex]::Replace($raw, '<\|[^>]*\|>', '')   # special tokens
    $raw = $raw -replace "`r", ''
    $raw = $raw -replace "`n", ' '

    # SUPPRESS_REGEX applied here, to the text, because whisper-server has no
    # --suppress-regex at all: the setting used to reach only the CLI fallback,
    # so the same dictation came out differently depending on which path served
    # it. Removing the phrase from the text is what the setting is documented to
    # do. A regex the user got wrong must not cost them the dictation.
    if ($Settings.Suppress) {
        try {
            $raw = [regex]::Replace($raw, $Settings.Suppress, '')
        } catch {
            Write-SayitError 'transcribe: SUPPRESS_REGEX is not a valid regular expression'
        }
    }

    $raw = [regex]::Replace($raw, ' {2,}', ' ')
    $raw = $raw.Trim()

    # Wordlist last, so its exact replacements have the final say.
    if ($raw) {
        $raw = Convert-WithWordlist -Text $raw -Path $Settings.Wordlist
        Write-Mark 't.wordlist.end'
    }
    return $raw
}
