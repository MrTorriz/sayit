# Invoke-Tests.ps1 - run the whole Windows test suite with one command.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File win\tests\Invoke-Tests.ps1
#   powershell.exe ... -File win\tests\Invoke-Tests.ps1 -Output Detailed
#
# Discovers every *.Tests.ps1 next to this script and exits non-zero if any test
# fails, so CI can call it directly.
#
# Pester: the tests use Pester 5 syntax. Windows 11 ships Pester 3.4.0 in
# C:\Program Files\WindowsPowerShell\Modules, and that version silently
# misinterprets Should -Be as a positional argument rather than an operator, so
# a suite run under it would report nonsense instead of failing loudly. This
# script therefore requires 5.0 or newer explicitly and refuses to run
# otherwise, with the command needed to install it.

[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
                Sort-Object -Property Name)

if ($testFiles.Count -eq 0) {
    Write-Error "No *.Tests.ps1 files found in $PSScriptRoot"
    exit 1
}

# Pester 3.4.0 is almost always loadable, so ask for 5.0+ by name rather than
# letting command discovery auto-load whatever is first on the module path.
try {
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
} catch {
    Write-Error @'
Pester 5.0 or newer is required; only the in-box Pester 3.4.0 was found.
Install it for the current user with:

    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
'@
    exit 1
}

$pesterVersion = (Get-Module Pester).Version
Write-Host ("Pester {0} - {1} test file(s) in {2}" -f $pesterVersion, $testFiles.Count, $PSScriptRoot)

$result = Invoke-Pester -Path $PSScriptRoot -Output $Output -PassThru

Write-Host ("Passed {0}, Failed {1}, Skipped {2}, Total {3}" -f
    $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount)

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
