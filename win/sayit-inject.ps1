# sayit-inject.ps1 - deliver text to the window that has focus.
#
# Usage:  .\sayit-inject.ps1 "text"
# Exit:   0 delivered, 1 nothing worked, 2 left on the clipboard for the user
#         to paste (an elevated window cannot be typed into)
#
# Method is chosen by length. SendInput with KEYEVENTF_UNICODE sends the
# character itself rather than a scan code, so it is layout independent and
# correct for Swedish without any clipboard involvement - the Linux side's
# clipboard workaround exists only because ydotool sends US scan codes.
#
# Long text still goes through the clipboard, for reasons specific to Windows:
# SendInput is capped by the OS at roughly 5000 characters, and it silently
# loses its atomicity guarantee whenever another process holds a low-level
# keyboard hook. sayit's own trigger is such a hook, so that is always the case.
#
# Dictated text is marked so it stays out of clipboard history and cloud sync.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][AllowEmptyString()][string]$Text,
    # Preferred when called from sayit.ps1: a command line mangles non-ASCII and
    # forces quoting decisions on text the user dictated.
    [string]$TextFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

if ($TextFile) {
    if (-not (Test-Path -LiteralPath $TextFile)) { Write-Error "Text file not found: $TextFile"; exit 1 }
    $Text = Read-Utf8Text -Path $TextFile
}
if ([string]::IsNullOrEmpty($Text)) { exit 0 }

$cfg = Import-DotEnv
$threshold = [int](Get-Setting -Env $cfg -Name 'INJECT_CLIPBOARD_THRESHOLD' -Default '100')
$method    = Get-Setting -Env $cfg -Name 'INJECT_METHOD' -Default 'auto'

Add-Type -AssemblyName System.Windows.Forms
$trigger  = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\Trigger.cs')
$injector = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\Injector.cs')
if (-not $injector) { Write-Error 'lib\Injector.cs not found'; exit 1 }
# Injector references Trigger.InjectionSignature, so both are compiled together.
Add-Type -TypeDefinition ($trigger + "`n" + $injector) -Language CSharp `
         -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

Write-Mark 'i.begin'

# Synthetic input cannot cross into a higher integrity level, and the failure is
# invisible to the caller. Detect it up front and degrade honestly instead.
if ([Sayit.Injector]::IsForegroundElevated()) {
    if ([Sayit.Injector]::SetClipboard($Text, 10)) {
        Write-Mark 'i.clipboard.elevated'
        Write-Warning 'The focused window runs elevated; text is on the clipboard - press Ctrl+V.'
        exit 2
    }
    Write-SayitError 'inject: elevated target and clipboard unavailable'
    Write-Error 'The focused window runs elevated and the clipboard could not be set.'
    exit 1
}

$useClipboard = switch ($method) {
    'clipboard' { $true }
    'type'      { $false }
    default     { $Text.Length -gt $threshold }
}

if ($useClipboard) {
    if (-not [Sayit.Injector]::SetClipboard($Text, 10)) {
        Write-SayitError 'inject: clipboard stayed locked'
        Write-Error 'Could not put the text on the clipboard.'
        exit 1
    }
    Write-Mark 'i.copied'
    Start-Sleep -Milliseconds 30
    if (-not [Sayit.Injector]::SendPasteChord()) {
        Write-SayitError 'inject: paste chord rejected'
        Write-Warning 'Paste was rejected; the text is on the clipboard - press Ctrl+V.'
        exit 2
    }
    Write-Mark 'i.pasted'
} else {
    if (-not [Sayit.Injector]::TypeUnicode($Text, 512, 5)) {
        # Fall back rather than lose the text.
        if ([Sayit.Injector]::SetClipboard($Text, 10)) {
            Write-Warning 'Typing was rejected; the text is on the clipboard - press Ctrl+V.'
            exit 2
        }
        Write-SayitError 'inject: typing rejected and clipboard unavailable'
        Write-Error 'Could not deliver the text.'
        exit 1
    }
    Write-Mark 'i.typed'
}

exit 0
