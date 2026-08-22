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

function Convert-WithWordlist {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $Text
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # Unreadable wordlist must never take the dictation down.
        return $Text
    }

    $rules = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }

        $tab = $line.IndexOf("`t")
        if ($tab -lt 1) { continue }

        # Split on the FIRST tab only: a replacement may itself contain tabs.
        $orig = $line.Substring(0, $tab)
        $repl = $line.Substring($tab + 1)

        if ($orig.Length -eq 0 -or $repl.Length -eq 0) { continue }
        $rules += [pscustomobject]@{ Original = $orig; Replacement = $repl }
    }

    # Longest original first, so multi-word rules win over substrings.
    $rules = $rules | Sort-Object -Property @{ Expression = { $_.Original.Length }; Descending = $true }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $out = $Text
    foreach ($rule in $rules) {
        $pattern = '\b' + [regex]::Escape($rule.Original) + '\b'
        # A MatchEvaluator keeps the replacement literal: a bare string would
        # let $1 and friends be interpreted as capture references.
        $repl = $rule.Replacement
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $repl }.GetNewClosure()
        $out = [regex]::Replace($out, $pattern, $evaluator, $opts)
    }
    return $out
}

$result = Convert-WithWordlist -Text $stdin -Path $WordlistPath

# No trailing newline, matching the Linux contract.
[Console]::Out.Write($result)
