# sayit-transcribe.ps1 - WAV in, transcribed text on stdout.
#
# Usage:  .\sayit-transcribe.ps1 <file.wav>
# Writes: the transcription on stdout, with no trailing newline
# Exit:   0 success (including a legitimately empty result),
#         1 the file is missing or both the daemon and the CLI failed
#
# Tries the warm whisper-server first and falls back to whisper-cli ONLY on a
# transport failure. An empty 200 from a healthy daemon means "no speech" and is
# final - re-running it on the CLI would just spend a second to get the same
# answer. This mirrors the Linux contract exactly.
#
# Post-processing order: strip special tokens, collapse whitespace, then apply
# the wordlist. The wordlist runs last so its exact replacements always win.

[CmdletBinding()]
param([Parameter(Position = 0)][string]$WavPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

# Without this the transcription is written in the console code page, which
# mangles every non-ASCII character the moment stdout is redirected.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if (-not $WavPath) { Write-Error 'Usage: sayit-transcribe.ps1 <file.wav>'; exit 1 }
if (-not (Test-Path -LiteralPath $WavPath)) { Write-Error "File not found: $WavPath"; exit 1 }

$cfg = Import-DotEnv

$repoModel = Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin'
$repoVad   = Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin'

$model    = Get-Setting -Env $cfg -Name 'MODEL_PATH'       -Default $repoModel
$language = Get-Setting -Env $cfg -Name 'SPEECH_LANGUAGE'  -Default 'sv'
$threads  = Get-Setting -Env $cfg -Name 'THREADS'          -Default '6'
$beam     = Get-Setting -Env $cfg -Name 'BEAM'             -Default '5'
$port     = Get-Setting -Env $cfg -Name 'DAEMON_PORT'      -Default '9876'
$prompt   = Get-Setting -Env $cfg -Name 'INITIAL_PROMPT'   -Default ''
$vad      = Get-Setting -Env $cfg -Name 'VAD_MODEL'        -Default $repoVad
$suppress = Get-Setting -Env $cfg -Name 'SUPPRESS_REGEX'   -Default ''
$wordlist = Get-Setting -Env $cfg -Name 'WORDLIST'         -Default (Join-Path $script:ConfigDir 'wordlist.tsv')
$cliPath  = Get-Setting -Env $cfg -Name 'WHISPER_CLI' `
                -Default (Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp\build-vulkan\bin\Release\whisper-cli.exe')

$daemonUrl = "http://127.0.0.1:$port/inference"

function Invoke-Daemon {
    param([string]$Path)

    # Deadline scales with audio length: 16 kHz mono 16-bit is 32000 bytes/s.
    $bytes = (Get-Item -LiteralPath $Path).Length
    $deadline = [int]($bytes / 32000) + 10

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client  = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($deadline)
    try {
        $content = New-Object System.Net.Http.MultipartFormDataContent
        $fileBytes = [System.IO.File]::ReadAllBytes($Path)
        # The comma keeps PowerShell from splatting the byte array into separate
        # constructor arguments.
        $fileContent = New-Object System.Net.Http.ByteArrayContent(, $fileBytes)
        $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($Path))
        $content.Add((New-Object System.Net.Http.StringContent($language)), 'language')
        # Sent even when empty, so a prompt from an earlier request is cleared.
        $content.Add((New-Object System.Net.Http.StringContent($prompt)), 'prompt')
        $content.Add((New-Object System.Net.Http.StringContent('text')), 'response_format')

        $response = $client.PostAsync($daemonUrl, $content).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "daemon returned HTTP $([int]$response.StatusCode)"
        }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
    }
}

function Invoke-Cli {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $cliPath)) { throw "whisper-cli missing: $cliPath - run install.ps1" }
    if (-not (Test-Path -LiteralPath $model))   { throw "Model missing: $model - run install.ps1" }

    $cliArgs = @('-m', $model, '-l', $language, '-t', $threads, '-bs', $beam,
                 '-fa', '-sns', '-nt', '-np')
    if ($vad -and (Test-Path -LiteralPath $vad)) { $cliArgs += @('--vad', '-vm', $vad) }
    if ($prompt)   { $cliArgs += @('--prompt', $prompt) }
    if ($suppress) { $cliArgs += @('--suppress-regex', $suppress) }
    $cliArgs += @('-f', $Path)

    # Start-Process with file redirection rather than a 2>$null pipeline: in
    # Windows PowerShell 5.1 redirecting a native command's stderr wraps every
    # line in an error record, which would turn whisper's progress chatter into
    # a spurious failure.
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $cliPath -ArgumentList $cliArgs -NoNewWindow -Wait -PassThru `
                              -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($proc.ExitCode -ne 0) { throw "whisper-cli exited $($proc.ExitCode)" }
        return (Read-Utf8Text -Path $stdout)
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

Write-Mark 't.daemon.begin'
$raw = $null
$daemonError = $null
try {
    $raw = Invoke-Daemon -Path $WavPath
    Write-Mark 't.daemon.end' '0'
} catch {
    $daemonError = $_.Exception.Message
    Write-Mark 't.daemon.end' '1'
}

if ($null -eq $raw) {
    Write-Mark 't.cli.begin'
    try {
        $raw = Invoke-Cli -Path $WavPath
        Write-Mark 't.cli.end' '0'
    } catch {
        Write-Mark 't.cli.end' '1'
        Write-SayitError "transcribe: daemon ($daemonError), cli ($($_.Exception.Message))"
        Write-Error "transcription failed: daemon unreachable ($daemonError), CLI fallback failed ($($_.Exception.Message))"
        exit 1
    }
}

# Normalisation, always applied.
$raw = [regex]::Replace($raw, '<\|[^>]*\|>', '')   # special tokens
$raw = $raw -replace "`r", ''
$raw = $raw -replace "`n", ' '
$raw = [regex]::Replace($raw, ' {2,}', ' ')
$raw = $raw.Trim()

# Wordlist last, so its exact replacements have the final say.
if ($raw -and $wordlist -and (Test-Path -LiteralPath $wordlist)) {
    $engine = Join-Path $PSScriptRoot 'sayit-wordlist.ps1'
    $raw = $raw | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -WordlistPath $wordlist
    Write-Mark 't.wordlist.end'
}

[Console]::Out.Write($raw)
exit 0
