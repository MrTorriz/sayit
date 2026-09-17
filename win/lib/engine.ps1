# Shared Windows engine configuration and lifecycle. Dot-source common.ps1 first.

function Get-SayitEngineMode {
    $path = Join-Path $script:ConfigDir 'engine-mode'
    if (-not (Test-Path -LiteralPath $path)) { return 'accurate' }
    $mode = (Read-Utf8Text $path).Trim()
    if ($mode -notin @('fast', 'accurate')) { throw 'Invalid engine-mode; expected fast or accurate.' }
    return $mode
}

function Get-SayitEngineHealth {
    param([int]$Port)
    try { return Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2 } catch { return $null }
}

function Test-SayitEngineHealth {
    param($Health, [string]$Mode)
    if ($null -eq $Health) { return $false }
    $turbo = $Health.PSObject.Properties['engine'] -and $Health.engine -eq 'openvino-turbo'
    if ($Mode -eq 'fast') { return [bool]($turbo -and $Health.PSObject.Properties['ready'] -and $Health.ready) }
    return [bool](-not $turbo -and $Health.PSObject.Properties['status'] -and $Health.status -eq 'ok')
}

function Get-SayitEngineLaunch {
    param([hashtable]$Config, [ValidateSet('fast','accurate')][string]$Mode)
    $runtime = Get-Setting -Env $Config -Name 'OPENVINO_HOME' -Default (Join-Path $script:DataDir 'openvino')
    $server = Get-Setting -Env $Config -Name 'WHISPER_SERVER' -Default (
        Join-Path $script:DataDir 'whisper.cpp\build-vulkan\bin\Release\whisper-server.exe')
    $vad = Get-Setting -Env $Config -Name 'VAD_MODEL' -Default (Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin')
    $port = [int](Get-Setting -Env $Config -Name 'DAEMON_PORT' -Default '9876')
    $language = Get-Setting -Env $Config -Name 'SPEECH_LANGUAGE' -Default 'sv'
    if ($Mode -eq 'fast') {
        $exe = Join-Path $runtime 'venv\Scripts\python.exe'
        $model = Join-Path $runtime 'model'
        $library = Get-Setting -Env $Config -Name 'WHISPER_LIB' -Default (Join-Path (Split-Path $server) 'whisper.dll')
        $arguments = @('-I', (Join-Path $script:RepoRoot 'engines\openvino\server.py'),
            '--model', $model, '--vad-model', $vad, '--whisper-lib', $library,
            '--device', (Get-Setting -Env $Config -Name 'OPENVINO_DEVICE' -Default 'GPU'),
            '--language', $language, '--cache', (Join-Path $runtime 'cache'), '--port', [string]$port)
        $required = @($exe, $model, $library, $vad)
    } else {
        $exe = $server
        $model = Get-Setting -Env $Config -Name 'MODEL_PATH' -Default (Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin')
        $arguments = @('--model', $model, '--language', $language,
            '--threads', (Get-Setting -Env $Config -Name 'THREADS' -Default '6'),
            '--beam-size', (Get-Setting -Env $Config -Name 'BEAM' -Default '5'),
            '--flash-attn', '--suppress-nst', '--host', '127.0.0.1', '--port', [string]$port)
        if (Test-Path -LiteralPath $vad) { $arguments += @('--vad', '--vad-model', $vad) }
        $required = @($exe, $model)
    }
    return [pscustomobject]@{ Exe=$exe; Arguments=$arguments; Required=$required; Port=$port; Mode=$Mode }
}

function Assert-SayitEngineLaunch {
    param($Launch)
    foreach ($path in $Launch.Required) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Required engine file missing: $path" }
    }
}

function Start-SayitEngine {
    param($Launch)
    Assert-SayitEngineLaunch $Launch
    $health = Get-SayitEngineHealth $Launch.Port
    if (Test-SayitEngineHealth $health $Launch.Mode) { return }
    if ($null -ne $health) { throw 'Another engine is running; use sayit-engine.ps1 to switch.' }
    $p = Start-Process -FilePath $Launch.Exe -WindowStyle Hidden -PassThru `
        -ArgumentList ($Launch.Arguments | ForEach-Object { Format-ProcessArgument $_ })
    $identity = @{ Id=$p.Id; Started=$p.StartTime.ToFileTimeUtc().ToString(); Path=$p.Path }
    Write-Utf8Text (Join-Path $script:RunDir 'engine-process.json') ($identity | ConvertTo-Json -Compress)
    Write-Utf8Text (Join-Path $script:RunDir 'daemon.pid') ([string]$p.Id)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        do {
            if (Test-SayitEngineHealth (Get-SayitEngineHealth $Launch.Port) $Launch.Mode) { return }
            if ($p.HasExited) { throw "Engine exited with code $($p.ExitCode)." }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Engine health check timed out after 120 seconds.'
    } catch {
        if (-not $p.HasExited) { Stop-SayitProcessTree $p }
        Remove-Item -LiteralPath (Join-Path $script:RunDir 'engine-process.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:RunDir 'daemon.pid') -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Stop-SayitProcessTree {
    param([System.Diagnostics.Process]$Process)
    # A Windows venv launcher owns a child interpreter. Stopping only its parent
    # would leave the server listening, so terminate the verified process tree.
    & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F | Out-Null
    if ($LASTEXITCODE -ne 0 -and -not $Process.HasExited) { throw 'Could not stop the owned engine.' }
    $Process.WaitForExit()
}

function Stop-SayitEngine {
    param([hashtable]$Config)
    $identityPath = Join-Path $script:RunDir 'engine-process.json'
    $pidPath = Join-Path $script:RunDir 'daemon.pid'
    if (Test-Path -LiteralPath $identityPath) {
        $identity = Read-Utf8Text $identityPath | ConvertFrom-Json
        $p = Get-Process -Id $identity.Id -ErrorAction SilentlyContinue
        if ($p -and $p.Path -eq $identity.Path -and $p.StartTime.ToFileTimeUtc().ToString() -eq $identity.Started) {
            Stop-SayitProcessTree $p
        }
    } elseif (Test-Path -LiteralPath $pidPath) {
        # Adopt only the legacy whisper-server that owns the configured port.
        $launch = Get-SayitEngineLaunch $Config 'accurate'
        $legacyId = [int](Read-Utf8Text $pidPath).Trim()
        $p = Get-Process -Id $legacyId -ErrorAction SilentlyContinue
        $listener = Get-NetTCPConnection -LocalPort $launch.Port -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $legacyId -and $_.LocalAddress -eq '127.0.0.1' }
        if ($p -and $p.Path -eq $launch.Exe -and $listener) { Stop-SayitProcessTree $p }
    }
    Remove-Item -LiteralPath $identityPath,$pidPath -Force -ErrorAction SilentlyContinue
}

function Set-SayitEngineMode {
    param([ValidateSet('fast','accurate')][string]$Mode, [hashtable]$Config)
    $gate = Open-SayitEngineGate -Exclusive
    try {
        if (Test-Path -LiteralPath (Join-Path $script:RunDir 'sayit.session')) {
            throw 'Finish or cancel the recording before switching engines.'
        }
        $previous = Get-SayitEngineMode
        $target = Get-SayitEngineLaunch $Config $Mode
        Assert-SayitEngineLaunch $target
        if ($previous -eq $Mode -and (Test-SayitEngineHealth (Get-SayitEngineHealth $target.Port) $Mode)) { return }
        Stop-SayitEngine $Config
        try {
            Start-SayitEngine $target
            # Persist only after readiness, using atomic replacement on one volume.
            $path = Join-Path $script:ConfigDir 'engine-mode'
            $temp = "$path.$PID.tmp"
            Write-Utf8Text $temp $Mode
            if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($temp, $path, [NullString]::Value) }
            else { [System.IO.File]::Move($temp, $path) }
        } catch {
            $failure = $_
            try {
                Stop-SayitEngine $Config
                Start-SayitEngine (Get-SayitEngineLaunch $Config $previous)
            } catch {
                throw "Engine switch and recovery failed. Previous mode remains selected. $($_.Exception.Message)"
            }
            throw "Engine switch failed; previous engine restored. $($failure.Exception.Message)"
        }
    } finally { $gate.Dispose() }
}
