# sayit-history.ps1 - show transcription history and statistics.
#
# Usage:
#   .\sayit-history.ps1                 show the latest 20 entries
#   .\sayit-history.ps1 50              show the latest 50 entries
#   .\sayit-history.ps1 -Stat           total words, speaking WPM and time saved
#   .\sayit-history.ps1 -Stat -Period 7d   same, limited to a period: Nd, Nh, Nm
#   .\sayit-history.ps1 -Copy 12        copy entry 12 to the clipboard
#   .\sayit-history.ps1 -Inject 12      re-inject entry 12 into the focused window
#   .\sayit-history.ps1 -Clear          empty the history file
#
# Arguments:
#   -Count <N>   positional; how many of the latest entries to list (default 20)
#   -Stat        print statistics instead of a listing
#   -Period <P>  with -Stat only; N followed by d (days), h (hours) or m (minutes)
#   -Copy <N>    absolute line number of the entry to put on the clipboard
#   -Inject <N>  absolute line number of the entry to hand to sayit-inject.ps1
#   -Clear       truncate the history file
#
# Numbering: the listing shows each entry's ABSOLUTE 1-based line number in the
# history file, so the same N works directly with -Copy and -Inject.
#
# Data source:
#   %LOCALAPPDATA%\sayit\history.jsonl - one JSON object per line, fields
#   time (local ISO-8601 to seconds), seconds, words, text. Same format as the
#   Linux side, so a history file is portable between the two.
#
# A corrupt line (a crash mid-append, a manual edit) is skipped and counted;
# the count goes to stderr, never the content. Blank lines are skipped silently.
#
# Exit codes:
#   0  Success, including an empty history
#   1  Unknown or conflicting arguments, an invalid entry number, or a corrupt
#      entry requested by -Copy or -Inject

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Count,
    [switch]$Stat,
    [string]$Period,
    [string]$Copy,
    [string]$Inject,
    [switch]$Clear
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

# Transcribed text is not ASCII, and neither is the ellipsis used for
# truncation. Without this both are mangled as soon as stdout is redirected.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$historyFile = Join-Path $script:DataDir 'history.jsonl'

function Write-Stderr {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine($Message)
}

# Exactly one mode per run: silently ignoring the others would make
# "-Stat -Clear" look like it did what the user asked.
$modes = @()
if ($Stat)   { $modes += '-Stat' }
if ($Copy)   { $modes += '-Copy' }
if ($Inject) { $modes += '-Inject' }
if ($Clear)  { $modes += '-Clear' }
if ($Count)  { $modes += 'count' }
if ($modes.Count -gt 1) {
    Write-Stderr ("Conflicting arguments: {0}" -f ($modes -join ', '))
    exit 1
}
if ($Period -and -not $Stat) {
    Write-Stderr '-Period is only valid together with -Stat'
    exit 1
}

# --- Reading ----------------------------------------------------------------

# The leading comma keeps the pipeline from unrolling the array: an empty
# history would otherwise come back as $null and strict mode would then reject
# every .Count on it.
function Get-HistoryLines {
    if (-not (Test-Path -LiteralPath $historyFile)) { return ,@() }
    try {
        return ,[System.IO.File]::ReadAllLines($historyFile, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Stderr ("Could not read the history file: {0}" -f $_.Exception.Message)
        exit 1
    }
}

# ConvertFrom-Json throws on malformed JSON, and a valid JSON scalar or array is
# just as unusable here as a broken line. Both come back as $null.
function ConvertTo-Entry {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return $obj
}

# Strict mode turns a missing property into a terminating error, so every field
# read goes through here.
function Get-Field {
    param($Entry, [Parameter(Mandatory)][string]$Name, $Default)
    if ($null -eq $Entry) { return $Default }
    $prop = $Entry.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-EntryText {
    param([Parameter(Mandatory)][string]$Number)
    if ($Number -notmatch '^[0-9]+$') {
        Write-Stderr "Invalid line number: $Number"
        exit 1
    }
    $n = [int]$Number
    $lines = Get-HistoryLines
    if ($n -lt 1 -or $n -gt $lines.Count -or $lines[$n - 1].Trim() -eq '') {
        Write-Stderr "No entry on line $n"
        exit 1
    }
    $entry = ConvertTo-Entry -Line $lines[$n - 1]
    if ($null -eq $entry) {
        Write-Stderr "Corrupt entry on line $n"
        exit 1
    }
    $text = Get-Field -Entry $entry -Name 'text' -Default $null
    if ($null -eq $text) {
        Write-Stderr "Entry on line $n has no text field"
        exit 1
    }
    return [string]$text
}

# --- Formatting -------------------------------------------------------------

# Durations: seconds below 90 s, minutes below 90 min, hours above that.
function Format-Duration {
    param([Parameter(Mandatory)][double]$Seconds)
    $s = [math]::Abs($Seconds)
    if ($s -lt 90)   { return [string]::Format($inv, '{0:F0}s', $s) }
    if ($s -lt 5400) { return [string]::Format($inv, '{0:F1} min', $s / 60) }
    return [string]::Format($inv, '{0:F1} h', $s / 3600)
}

function ConvertTo-Double {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    try { return [double]::Parse([string]$Value, $inv) } catch { return 0.0 }
}

# --- Commands ---------------------------------------------------------------

if ($Clear) {
    Write-Utf8Text -Path $historyFile -Text ''
    'History cleared'
    exit 0
}

if ($Copy) {
    $text = Get-EntryText -Number $Copy
    try {
        Set-Clipboard -Value $text
        'Copied to clipboard'
    } catch {
        # Losing the clipboard must not lose the text: print it instead.
        Write-Stderr ("Could not set the clipboard: {0}" -f $_.Exception.Message)
        $text
    }
    exit 0
}

if ($Inject) {
    $text = Get-EntryText -Number $Inject
    $injector = Join-Path $PSScriptRoot 'sayit-inject.ps1'
    if (-not (Test-Path -LiteralPath $injector)) {
        Write-Stderr "sayit-inject.ps1 not found next to this script"
        exit 1
    }
    # Handed over in a file, not on a command line: a command line mangles
    # non-ASCII text and forces quoting decisions on dictated content.
    $textFile = Join-Path $script:RunDir "history-inject-$PID.txt"
    try {
        Write-Utf8Text -Path $textFile -Text $text
        $proc = Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait -PassThru `
            -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$injector,
                          '-TextFile',$textFile
        exit $proc.ExitCode
    } finally {
        Remove-Item -LiteralPath $textFile -Force -ErrorAction SilentlyContinue
    }
}

$lines = Get-HistoryLines
# A file holding nothing but a newline is an empty history too.
$hasEntry = $false
foreach ($line in $lines) { if ($line.Trim() -ne '') { $hasEntry = $true; break } }
if (-not $hasEntry) { 'Empty history'; exit 0 }

if ($Stat) {
    $cutoff = $null
    if ($Period) {
        if ($Period -notmatch '^[0-9]+[dhm]$') {
            Write-Stderr "Invalid period: $Period (use e.g. 7d, 12h or 30m)"
            exit 1
        }
        $amount = [int]$Period.Substring(0, $Period.Length - 1)
        $unit   = $Period.Substring($Period.Length - 1)
        $span = $null
        switch ($unit) {
            'd' { $span = [TimeSpan]::FromDays($amount) }
            'h' { $span = [TimeSpan]::FromHours($amount) }
            'm' { $span = [TimeSpan]::FromMinutes($amount) }
        }
        $cutoff = (Get-Date) - $span
    }

    $totalWords = 0
    $totalSec   = 0.0
    $n = 0
    $bad = 0
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        $entry = ConvertTo-Entry -Line $line
        if ($null -eq $entry) { $bad++; continue }
        if ($null -ne $cutoff) {
            $stamp = [string](Get-Field -Entry $entry -Name 'time' -Default '')
            $parsed = [DateTime]::MinValue
            # The writer's format, parsed exactly: a locale-dependent parse would
            # silently reinterpret the entry on a machine with another culture.
            if (-not [DateTime]::TryParseExact($stamp, 'yyyy-MM-ddTHH:mm:ss', $inv,
                    [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                continue
            }
            if ($parsed -lt $cutoff) { continue }
        }
        $totalWords += [int](ConvertTo-Double (Get-Field -Entry $entry -Name 'words' -Default 0))
        $totalSec   += (ConvertTo-Double (Get-Field -Entry $entry -Name 'seconds' -Default 0))
        $n++
    }

    if ($bad -gt 0) { Write-Stderr "Warning: skipped $bad corrupt history line(s)" }

    if ($n -eq 0) {
        if ($Period) { "No entries within $Period" } else { 'No entries' }
        exit 0
    }

    $cfg = Import-DotEnv
    $typingWpm = ConvertTo-Double (Get-Setting -Env $cfg -Name 'TYPING_WPM' -Default '40')

    $speakWpm = 0.0
    if ($totalSec -gt 0) { $speakWpm = $totalWords / ($totalSec / 60) }
    # Estimated keyboard time for the same word count, minus the time spoken.
    $typingSec = 0.0
    if ($typingWpm -gt 0) { $typingSec = $totalWords / $typingWpm * 60 }
    $savedSec = $typingSec - $totalSec

    if ($Period) { "Period:          last $Period" }
    "Entries:         $n"
    "Total words:     $totalWords"
    [string]::Format($inv, 'Speaking time:   {0} ({1:F0} words/min spoken)', (Format-Duration $totalSec), $speakWpm)
    [string]::Format($inv, 'Typing time est: {0} (at {1:F0} words/min keyboard)', (Format-Duration $typingSec), $typingWpm)
    $label = 'saved'
    if ($savedSec -lt 0) { $label = 'LOST' }
    "Time {0}:      {1}  (speaking vs typing)" -f $label, (Format-Duration $savedSec)
    if ($totalWords -gt 0) {
        [string]::Format($inv, 'Avg/dictation:   {0:F0} words, {1:F1}s', ($totalWords / $n), ($totalSec / $n))
    }
    exit 0
}

# --- Listing ----------------------------------------------------------------

$howMany = 20
if ($Count) {
    if ($Count -notmatch '^[0-9]+$') {
        Write-Stderr "Unknown argument: $Count"
        exit 1
    }
    $howMany = [int]$Count
}

$start = [math]::Max(0, $lines.Count - $howMany)
$bad = 0
for ($i = $start; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()
    if ($line -eq '') { continue }
    $entry = ConvertTo-Entry -Line $line
    if ($null -eq $entry) { $bad++; continue }

    $time  = [string](Get-Field -Entry $entry -Name 'time'  -Default '?')
    $words = [string](Get-Field -Entry $entry -Name 'words' -Default '?')
    $text  = [string](Get-Field -Entry $entry -Name 'text'  -Default '')
    # Long dictations are shortened so one entry cannot swamp the listing. The
    # ellipsis matters: without it a cut entry looks like one that genuinely
    # ended there, and -Copy/-Inject would hand back more than was shown.
    if ($text.Length -gt 80) { $text = $text.Substring(0, 79) + [char]0x2026 }

    [string]::Format($inv, '{0,3} [{1}] ({2} words) {3}', ($i + 1), $time, $words, $text)
}
if ($bad -gt 0) { Write-Stderr "Warning: skipped $bad corrupt history line(s)" }

exit 0
