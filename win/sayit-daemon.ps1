# sayit-daemon.ps1 - keep the model warm in a local whisper-server.
#
# Usage:
#   .\sayit-daemon.ps1 start     start the server if it is not already running
#   .\sayit-daemon.ps1 stop      stop it
#   .\sayit-daemon.ps1 status    report whether it answers
#   .\sayit-daemon.ps1 run       run it in the foreground (for a scheduled task)
#
# The server listens on 127.0.0.1 only and has no authentication, so any local
# process can reach it. Keep it on loopback.
#
# Model, VAD, threads and beam size are fixed when the server starts; changing
# them in .env requires a restart. Language and initial prompt are per request.
#
# Exit codes: 0 success, 1 the binary or the model is missing, 2 start failed.

[CmdletBinding()]
param([Parameter(Position = 0)][ValidateSet('start', 'stop', 'status', 'run')][string]$Action = 'status')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

$cfg = Import-DotEnv

$repoModel = Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin'
$repoVad   = Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin'

$model    = Get-Setting -Env $cfg -Name 'MODEL_PATH'      -Default $repoModel
$language = Get-Setting -Env $cfg -Name 'SPEECH_LANGUAGE' -Default 'sv'
$threads  = Get-Setting -Env $cfg -Name 'THREADS'         -Default '6'
$beam     = Get-Setting -Env $cfg -Name 'BEAM'            -Default '5'
$port     = Get-Setting -Env $cfg -Name 'DAEMON_PORT'     -Default '9876'
$vad      = Get-Setting -Env $cfg -Name 'VAD_MODEL'       -Default $repoVad
$suppress = Get-Setting -Env $cfg -Name 'SUPPRESS_REGEX'  -Default ''
$server   = Get-Setting -Env $cfg -Name 'WHISPER_SERVER' `
                -Default (Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp\build-vulkan\bin\Release\whisper-server.exe')

$pidFile = Join-Path $script:RunDir 'daemon.pid'

function Test-DaemonAlive {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', [int]$port).Wait(500)
        $c.Close()
        return $ok
    } catch { return $false }
}

function Get-ServerArgs {
    $a = @('--model', $model, '--language', $language, '--threads', $threads,
           '--beam-size', $beam, '--flash-attn', '--suppress-nst',
           '--host', '127.0.0.1', '--port', $port)
    if ($vad -and (Test-Path -LiteralPath $vad)) { $a += @('--vad', '--vad-model', $vad) }
    if ($suppress) { $a += @('--suppress-regex', $suppress) }
    return $a
}

switch ($Action) {

    'status' {
        if (Test-DaemonAlive) { "running on 127.0.0.1:$port"; exit 0 }
        'not running'
        exit 0
    }

    'run' {
        if (-not (Test-Path -LiteralPath $server)) { Write-Error "whisper-server missing: $server"; exit 1 }
        if (-not (Test-Path -LiteralPath $model))  { Write-Error "Model missing: $model"; exit 1 }
        & $server @(Get-ServerArgs)
        exit $LASTEXITCODE
    }

    'start' {
        if (Test-DaemonAlive) { "already running on 127.0.0.1:$port"; exit 0 }
        if (-not (Test-Path -LiteralPath $server)) { Write-Error "whisper-server missing: $server"; exit 1 }
        if (-not (Test-Path -LiteralPath $model))  { Write-Error "Model missing: $model"; exit 1 }

        $p = Start-Process -FilePath $server -ArgumentList (Get-ServerArgs) `
                           -WindowStyle Hidden -PassThru
        Write-Utf8Text -Path $pidFile -Text ([string]$p.Id)

        # Poll rather than sleep a fixed amount: model load dominates and varies.
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 250
            if (Test-DaemonAlive) { "started (pid $($p.Id)) on 127.0.0.1:$port"; exit 0 }
            if ($p.HasExited) { Write-Error "whisper-server exited with $($p.ExitCode)"; exit 2 }
        }
        Write-Error 'whisper-server did not start listening within 15 s'
        exit 2
    }

    'stop' {
        $stopped = $false
        if (Test-Path -LiteralPath $pidFile) {
            $daemonPid = (Read-Utf8Text -Path $pidFile).Trim()
            $proc = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
            # Identity check before signalling: a recycled pid must never be killed.
            if ($proc -and $proc.Path -and
                [System.IO.Path]::GetFileName($proc.Path) -eq [System.IO.Path]::GetFileName($server)) {
                $proc | Stop-Process -Force
                $stopped = $true
            }
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        }
        if ($stopped) { 'stopped' } else { 'not running' }
        exit 0
    }
}
