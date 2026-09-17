# sayit-transcribe.ps1 - WAV in, transcribed text on stdout.
#
# Usage:  .\sayit-transcribe.ps1 <file.wav>
# Writes: the transcription on stdout, with no trailing newline
# Exit:   0 success (including a legitimately empty result),
#         1 the file is missing or both the daemon and the CLI failed
#
# The engine itself lives in lib\transcribe.ps1 so the dictation path can call it
# in-process; this script is the command-line front end to the same function, and
# the counterpart of bin/sayit-transcribe on the Linux side.

[CmdletBinding()]
param([Parameter(Position = 0)][string]$WavPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\transcribe.ps1"
Initialize-SayitDirs

# Without this the transcription is written in the console code page, which
# mangles every non-ASCII character the moment stdout is redirected.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if (-not $WavPath) { Write-Error 'Usage: sayit-transcribe.ps1 <file.wav>'; exit 1 }
if (-not (Test-Path -LiteralPath $WavPath)) { Write-Error "File not found: $WavPath"; exit 1 }

$settings = New-TranscribeSettings -Env (Import-DotEnv)

try {
    $text = Convert-WavToText -Path $WavPath -Settings $settings
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

[Console]::Out.Write($text)
exit 0
