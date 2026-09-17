# common.ps1 - shared helpers for the Windows implementation of sayit.
#
# Dot-source this from every win\*.ps1 entry point:
#     . "$PSScriptRoot\lib\common.ps1"
#
# Provides: repo/state paths, .env loading, UTF-8 file IO, stage profiling,
# session-file parsing, the wordlist engine and the error log.
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
        # Invariant formatting: under a Swedish locale these render with a
        # decimal comma, which silently splits every row into extra CSV columns.
        $inv   = [System.Globalization.CultureInfo]::InvariantCulture
        $line  = '{0},{1},{2},{3},{4}' -f $runId, $wall.ToString('F3', $inv), $mono.ToString('F3', $inv), $Stage, $Extra
        Add-Utf8Line -Path $csv -Line $line
    } catch {
        # Profiling must never break a dictation.
    }
}

# --- Session file -----------------------------------------------------------
# One line, tab separated:
#
#     pid <TAB> wav <TAB> start <TAB> stop-event <TAB> recorder-creation-time
#
# The last field is what turns the pid into an identity. Windows hands pids out
# again, so a session file left behind by a crash can name a process that has
# nothing to do with sayit - and the stop path signals, waits for and finally
# kills whatever the file names. Comparing the recorder's creation time as well
# makes that impossible. Lines written before the field existed parse with 0,
# which reads as "cannot verify" and never as a match.
#
# Parsed here rather than in each caller because both the state machine and the
# diagnostics read this file.

function ConvertFrom-SessionLine {
    param([AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $parts = $Line.Trim() -split "`t"
    if ($parts.Count -lt 4) { return $null }

    [long]$procStart = 0
    if ($parts.Count -ge 5) {
        [void][long]::TryParse($parts[4], [System.Globalization.NumberStyles]::Integer,
                               [System.Globalization.CultureInfo]::InvariantCulture, [ref]$procStart)
    }
    # Invariant parsing: the start stamp is always written with a decimal point,
    # and a Swedish locale would otherwise read "1.5" as fifteen.
    return [pscustomobject]@{
        ProcessId    = [int]$parts[0]
        Wav          = $parts[1]
        Start        = [double]::Parse($parts[2], [System.Globalization.CultureInfo]::InvariantCulture)
        EventName    = $parts[3]
        ProcessStart = $procStart
    }
}

# True only while the pid still belongs to the very process the session spawned.
function Test-SessionRecorder {
    param($Session)

    if (-not $Session) { return $false }
    $proc = Get-Process -Id $Session.ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($Session.ProcessStart -eq 0) { return $true }
    try {
        return ($proc.StartTime.ToFileTimeUtc() -eq $Session.ProcessStart)
    } catch {
        # No right to read the start time means it is not a process of ours.
        return $false
    }
}

# --- Wordlist ---------------------------------------------------------------
# Lives here rather than only in sayit-wordlist.ps1 so the transcription path can
# apply it in-process. Spawning a second PowerShell just to run a few regex
# replacements cost about 0.8 s per dictation, which was a fifth of the total.
#
# Contract, identical to bin/sayit-wordlist on the Linux side: rules are sorted
# by original length descending and applied sequentially and globally, matching
# is case-insensitive on Unicode word boundaries, and originals are literal
# strings rather than regexes.

function Convert-WithWordlist {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $Text }

    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # An unreadable wordlist must never take the dictation down.
        return $Text
    }

    $rules = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }

        # First tab only: a replacement may itself contain tabs.
        $tab = $line.IndexOf("`t")
        if ($tab -lt 1) { continue }
        $orig = $line.Substring(0, $tab)
        $repl = $line.Substring($tab + 1)
        if ($orig.Length -eq 0 -or $repl.Length -eq 0) { continue }

        $rules += [pscustomobject]@{ Original = $orig; Replacement = $repl }
    }

    if ($rules.Count -eq 0) { return $Text }

    $rules = $rules | Sort-Object -Property @{ Expression = { $_.Original.Length }; Descending = $true }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $out = $Text
    foreach ($rule in $rules) {
        $pattern = '\b' + [regex]::Escape($rule.Original) + '\b'
        # A MatchEvaluator keeps the replacement literal; a bare string would let
        # $1 and friends be read as capture-group references.
        $replacement = $rule.Replacement
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m) $replacement
        }.GetNewClosure()
        $out = [regex]::Replace($out, $pattern, $evaluator, $opts)
    }
    return $out
}

# --- Process arguments -------------------------------------------------------
# Start-Process joins -ArgumentList into a single command line with a space
# between the elements and quotes nothing at all, so an element holding a path
# with a space in it arrives at the target as two arguments and the file it
# names is never found. Every path handed to Start-Process therefore has to be
# quoted here first.
#
# The escaping is the one the Windows command line itself uses: a quote is
# escaped with a backslash, and backslashes are only special immediately before
# a quote - which includes the closing quote this function adds, so a value
# ending in a backslash has to have those doubled.

function Format-ProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# --- C# helpers -------------------------------------------------------------
# Two of the C# files have to be compiled together because one references a
# constant from the other. Concatenating them naively is invalid C#: the second
# file's using directives would follow the first file's namespace block. This
# hoists every using to the top and emits the remaining declarations after them.

function Merge-CSharpSources {
    param([Parameter(Mandatory)][string[]]$Sources)

    $usings = New-Object System.Collections.Generic.List[string]
    $bodies = New-Object System.Collections.Generic.List[string]

    foreach ($src in $Sources) {
        $body = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($src -split "`r?`n")) {
            if ($line -match '^\s*using\s+[A-Za-z_][A-Za-z0-9_.]*\s*;\s*$') {
                $u = $line.Trim()
                if (-not $usings.Contains($u)) { $usings.Add($u) }
            } else {
                $body.Add($line)
            }
        }
        $bodies.Add(($body -join "`n"))
    }
    return (($usings -join "`n") + "`n" + ($bodies -join "`n"))
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
