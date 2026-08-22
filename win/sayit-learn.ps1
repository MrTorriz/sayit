# sayit-learn.ps1 - teach sayit your vocabulary by growing the wordlist.
#
# Usage:
#   .\sayit-learn.ps1 "wrong" "right"   add a replacement rule (deduplicated)
#   .\sayit-learn.ps1 -List             show the current rules
#   .\sayit-learn.ps1 -Undo "wrong"     remove the rule whose original is "wrong"
#
# Arguments:
#   -Wrong <s>   positional 1; the transcribed form to replace
#   -Right <s>   positional 2; what to replace it with
#   -List        print every rule, excluding comments and blank lines
#   -Undo <s>    remove every rule whose first column matches, case-insensitively
#
# Behaviour:
#   - Appends the line "wrong<TAB>right" unless the original already exists
#     (compared case-insensitively). sayit-wordlist.ps1 applies it to every
#     later transcription, matching case-insensitively on word boundaries.
#   - Wordlist location: %APPDATA%\sayit\wordlist.tsv, or WORDLIST from .env.
#     The file and its directory are created on first use.
#   - Written as UTF-8 without a BOM, the encoding sayit-wordlist.ps1 reads.
#
# Exit codes:
#   0  Success
#   1  Bad arguments, an identical original and replacement, an original that is
#      already in the wordlist, or -Undo finding nothing to remove

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Wrong,
    [Parameter(Position = 1)][string]$Right,
    [switch]$List,
    [string]$Undo
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

# Rules are not ASCII in any language sayit is useful for.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Write-Stderr {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine($Message)
}

$cfg = Import-DotEnv
$wordlist = Get-Setting -Env $cfg -Name 'WORDLIST' `
                        -Default (Join-Path $script:ConfigDir 'wordlist.tsv')

$dir = Split-Path -Parent $wordlist
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
if (-not (Test-Path -LiteralPath $wordlist)) {
    Write-Utf8Text -Path $wordlist -Text ''
}

# The leading comma keeps the pipeline from unrolling the array, so an empty
# wordlist comes back as an empty array rather than as $null.
function Get-WordlistLines {
    try {
        return ,[System.IO.File]::ReadAllLines($wordlist, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Stderr ("Could not read the wordlist: {0}" -f $_.Exception.Message)
        exit 1
    }
}

# The original is everything before the FIRST tab, matching the split that
# sayit-wordlist.ps1 performs when it applies the rules.
function Get-Original {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $tab = $Line.IndexOf("`t")
    if ($tab -lt 0) { return $null }
    return $Line.Substring(0, $tab)
}

function Test-SameWord {
    param([AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    return [string]::Equals($A, $B, [StringComparison]::InvariantCultureIgnoreCase)
}

if ($List) {
    foreach ($line in (Get-WordlistLines)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        $line
    }
    exit 0
}

if ($Undo) {
    $lines = Get-WordlistLines
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = 0
    foreach ($line in $lines) {
        $orig = Get-Original -Line $line
        if ($null -ne $orig -and (Test-SameWord $orig $Undo)) { $removed++; continue }
        $kept.Add($line)
    }
    if ($removed -eq 0) {
        Write-Stderr "No rule found with original: $Undo"
        exit 1
    }
    # Rewritten whole: a trailing newline is kept so a later append starts on a
    # line of its own.
    $text = ''
    if ($kept.Count -gt 0) { $text = ($kept -join "`n") + "`n" }
    Write-Utf8Text -Path $wordlist -Text $text
    "Removed: $Undo"
    exit 0
}

if (-not $Wrong) {
    Write-Stderr 'Usage: sayit-learn.ps1 "wrong" "right" | -List | -Undo "wrong"'
    exit 1
}
if (-not $Right) {
    Write-Stderr 'Usage: sayit-learn.ps1 "wrong" "right"'
    exit 1
}

# A rule that replaces a word with itself changes nothing and would only hide a
# later, real rule behind the deduplication check below.
if ($Wrong -ceq $Right) {
    Write-Stderr 'Original and replacement are identical - no rule added'
    exit 1
}

# A tab in the original would split the rule in two when it is read back.
if ($Wrong.Contains("`t") -or $Wrong.Contains("`n") -or $Right.Contains("`n")) {
    Write-Stderr 'A rule cannot contain a tab in the original or a newline in either field'
    exit 1
}

foreach ($line in (Get-WordlistLines)) {
    $orig = Get-Original -Line $line
    if ($null -ne $orig -and (Test-SameWord $orig $Wrong)) {
        Write-Stderr "Already in the wordlist: $Wrong (run -Undo first to change it)"
        exit 1
    }
}

# A wordlist whose last line has no newline would otherwise absorb the new rule
# into it, turning two rules into one unusable line.
$existing = Read-Utf8Text -Path $wordlist
if ($existing -and -not $existing.EndsWith("`n")) {
    Write-Utf8Text -Path $wordlist -Text ($existing + "`n")
}

Add-Utf8Line -Path $wordlist -Line ("{0}`t{1}" -f $Wrong, $Right)
"Added: $Wrong -> $Right"
exit 0
