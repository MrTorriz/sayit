# sayit-wordlist.ps1 - pure text transform: stdin to stdout, TSV rules.
#
# Usage:   ... | powershell.exe -NoProfile -File .\sayit-wordlist.ps1 [-WordlistPath <file>]
# Reads:   text on stdin (whole stream), rules from the TSV file
# Writes:  transformed text on stdout, with no trailing newline
# Exit:    0 always (a missing or unreadable wordlist passes text through)
#
# The usage line spells powershell.exe out because the redirection has to reach
# a process. Piping into the script from inside a PowerShell session instead
# ("... | .\sayit-wordlist.ps1") binds nothing and fails: this script reads the
# real stdin handle rather than the object pipeline, and PowerShell rejects the
# input before the script body runs.
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

# Both directions, before the first read. Redirected stdin and stdout otherwise
# use the console code page - 850 on a default Swedish install - which turns
# every non-ASCII character of a rule into a mangled byte in each direction.
# sayit-transcribe.ps1 and sayit-history.ps1 set the output side for the same
# reason; this front end, which reads as well as writes, set neither.
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

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
