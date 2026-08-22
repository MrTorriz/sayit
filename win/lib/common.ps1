# common.ps1 - shared helpers for the Windows implementation of sayit.
#
# Dot-source this from every win\*.ps1 entry point:
#     . "$PSScriptRoot\lib\common.ps1"
#
# Provides: repo/state paths, .env loading, UTF-8 file IO, stage profiling.
# Exit codes are defined by each entry point, not here.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Paths ------------------------------------------------------------------
# RepoRoot is the directory holding win\, i.e. the checkout root.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:WinRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Transient per-session state. Windows has no RAM-backed tmpfs equivalent of
# XDG_RUNTIME_DIR, so this is on disk and is cleaned up explicitly instead.
$script:RunDir = Join-Path $env:LOCALAPPDATA 'sayit\run'

# Persistent data and configuration.
$script:DataDir   = Join-Path $env:LOCALAPPDATA 'sayit'
$script:ConfigDir = Join-Path $env:APPDATA     'sayit'

function Initialize-SayitDirs {
    foreach ($d in @($script:RunDir, $script:DataDir, $script:ConfigDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

# --- UTF-8 file IO ----------------------------------------------------------
# PowerShell 5.1's Out-File -Encoding utf8 writes a BOM, which corrupts
# history.jsonl for any strict JSONL reader. These helpers never write one.

function Read-Utf8Text {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Add-Utf8Line {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($Path, $Line + "`n", $enc)
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# --- .env -------------------------------------------------------------------
# Same file format as the Linux side: KEY=VALUE, one per line, # comments,
# optional surrounding quotes. Deliberately NOT executed as a script - the
# Linux side sources it as bash, but running arbitrary code from a config file
# is a worse trade on either platform, and nothing in .env.example needs it.
#
# Windows-only additions expand %VAR% so paths stay machine-independent.

function Import-DotEnv {
    param([string]$Path = (Join-Path $script:RepoRoot '.env'))

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }

        $key = $line.Substring(0, $eq).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }

        $val = $line.Substring($eq + 1).Trim()
        # Strip one layer of matching quotes.
        if ($val.Length -ge 2 -and
            (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $result[$key] = [Environment]::ExpandEnvironmentVariables($val)
    }
    return $result
}

# Resolve one setting: ambient environment wins over .env, .env wins over the
# built-in default. An empty value in .env falls through to the default, which
# matches the ${VAR:-default} behaviour the Linux scripts rely on.
function Get-Setting {
    param(
        [Parameter(Mandatory)][hashtable]$Env,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Default = ''
    )
    $ambient = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrEmpty($ambient)) { return $ambient }
    if ($Env.ContainsKey($Name) -and -not [string]::IsNullOrEmpty($Env[$Name])) { return $Env[$Name] }
    return $Default
}

# --- Profiling --------------------------------------------------------------
# Mirrors the Linux mark() helper. Enabled by any non-empty SAYIT_PROFILE.
# Writes timing data only - never transcribed text.

$script:ProfileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Mark {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowEmptyString()][string]$Extra = ''
    )
    if ([string]::IsNullOrEmpty($env:SAYIT_PROFILE)) { return }
    try {
        $runId = if ($env:SAYIT_PROFILE_RUN) { $env:SAYIT_PROFILE_RUN } else { '0' }
        $wall  = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0
        $mono  = $script:ProfileStopwatch.Elapsed.TotalSeconds
        $csv   = Join-Path $script:RunDir 'sayit-profile.csv'
        $line  = '{0},{1:F3},{2:F3},{3},{4}' -f $runId, $wall, $mono, $Stage, $Extra
        Add-Utf8Line -Path $csv -Line $line
    } catch {
        # Profiling must never break a dictation.
    }
}

# --- Errors -----------------------------------------------------------------
# Error classes only, never transcribed text - same rule as the Linux side.

function Write-SayitError {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $log = Join-Path $script:RunDir 'sayit-last-error.log'
        Add-Utf8Line -Path $log -Line ('{0} {1}' -f (Get-Date -Format 's'), $Message)
    } catch { }
}
