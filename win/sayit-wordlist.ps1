# sayit-wordlist.ps1 - pure text transform: stdin to stdout, TSV rules.
#
# Usage:   ... | .\sayit-wordlist.ps1 [-WordlistPath <file>]
# Reads:   text on stdin (whole stream), rules from the TSV file
# Writes:  transformed text on stdout, with no trailing newline
# Exit:    0 always (a missing or unreadable wordlist passes text through)
#
# Rule format: original<TAB>replacement, one per line. Lines starting with #
# and blank lines are ignored, as are rows without a tab or with an empty
# original or replacement.
#
# Matching contract, identical to bin/sayit-wordlist on the Linux side:
#   - rules sorted by original length descending, so a multi-word rule always
#     beats a substring rule regardless of file order
#   - applied sequentially, every occurrence, so a replacement can itself be
#     matched by a later shorter rule
#   - case-insensitive, on word boundaries, Unicode aware
#   - originals are literal strings, never regexes

[CmdletBinding()]
param(
    [string]$WordlistPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"

# Read the whole of stdin as one string, preserving Unicode.
$stdin = [Console]::In.ReadToEnd()
if ($null -eq $stdin) { $stdin = '' }

if (-not $WordlistPath) {
    $cfg = Import-DotEnv
    $WordlistPath = Get-Setting -Env $cfg -Name 'WORDLIST' `
                                -Default (Join-Path $script:ConfigDir 'wordlist.tsv')
}

# The engine itself lives in lib\common.ps1 so the transcription path can call it
# in-process; this script is the command-line front end to the same function.
$result = Convert-WithWordlist -Text $stdin -Path $WordlistPath

# No trailing newline, matching the Linux contract.
[Console]::Out.Write($result)
