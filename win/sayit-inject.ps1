# sayit-inject.ps1 - deliver text to the window that has focus.
#
# Usage:
#   .\sayit-inject.ps1 "text"
#   .\sayit-inject.ps1 -TextFile <path>
#
# Exit:  0 delivered, 1 nothing worked, 2 left on the clipboard for the user to
#        paste (which is what happens when the focused window runs elevated)
#
# Method is chosen by length. SendInput with KEYEVENTF_UNICODE sends the
# character itself rather than a scan code, so it is layout independent and
# correct for Swedish without any clipboard involvement - the Linux side's
# clipboard workaround exists only because ydotool sends US scan codes.
#
# Long text still goes through the clipboard, for reasons specific to Windows:
# SendInput is capped by the OS at roughly 5000 characters, and it loses its
# ordering guarantee whenever another process holds a low-level keyboard hook.
# sayit's own trigger is such a hook, so that is always the case here.
#
# Dictated text is marked so it stays out of clipboard history and cloud sync.
#
# sayit.ps1 does not call this script - it dot-sources lib\inject.ps1 directly,
# because starting a second PowerShell per dictation cost about a second. This
# front end exists for manual use and for sayit-history.ps1 -Inject.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][AllowEmptyString()][string]$Text,
    # Preferred when called from another script: a command line mangles non-ASCII
    # and forces quoting decisions on text the user dictated.
    [string]$TextFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\inject.ps1"
Initialize-SayitDirs

if ($TextFile) {
    if (-not (Test-Path -LiteralPath $TextFile)) { Write-Error "Text file not found: $TextFile"; exit 1 }
    $Text = Read-Utf8Text -Path $TextFile
}
if ([string]::IsNullOrEmpty($Text)) { exit 0 }

$cfg       = Import-DotEnv
$threshold = [int](Get-Setting -Env $cfg -Name 'INJECT_CLIPBOARD_THRESHOLD' -Default '100')
$method    = Get-Setting -Env $cfg -Name 'INJECT_METHOD' -Default 'auto'

Write-Mark 'i.begin'
$result = Invoke-TextInjection -Text $Text -Threshold $threshold -Method $method
Write-Mark 'i.end' $result
exit $result
