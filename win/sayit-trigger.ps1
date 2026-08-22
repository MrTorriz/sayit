# sayit-trigger.ps1 - global push-to-talk trigger.
#
# Usage:
#   .\sayit-trigger.ps1                 run the trigger (hold to talk)
#   .\sayit-trigger.ps1 -Probe          print every button and key transition
#   .\sayit-trigger.ps1 -Probe -Seconds 20
#
# Holding the bound button runs "sayit start"; releasing runs "sayit stop".
# Probe mode binds nothing and suppresses nothing - it only reports what the
# hardware actually emits, which is the reliable way to discover the code a
# given mouse sends for its thumb buttons.
#
# Exit codes: 0 normal, 1 the hook could not be installed.

[CmdletBinding()]
param(
    [switch]$Probe,
    [int]$Seconds = 0,
    [string]$Button
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

Add-Type -AssemblyName System.Windows.Forms

$cs = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\Trigger.cs')
if (-not $cs) { Write-Error 'lib\Trigger.cs not found'; exit 1 }
Add-Type -TypeDefinition $cs -Language CSharp

$cfg = Import-DotEnv
if (-not $Button) {
    $Button = Get-Setting -Env $cfg -Name 'TRIGGER_BUTTON' -Default 'XBUTTON2'
}
$suppressSetting = Get-Setting -Env $cfg -Name 'TRIGGER_SUPPRESS' -Default '1'
$suppress = ($suppressSetting -ne '0')

[Sayit.Trigger]::Configure($Button, $suppress, [bool]$Probe)
[Sayit.Trigger]::Install()

if ($Probe) {
    Write-Host 'Probing input. Press your mouse thumb buttons and any keys you want to test.'
    Write-Host 'Nothing is suppressed and no dictation is started.'
    if ($Seconds -gt 0) { Write-Host "Stopping automatically after $Seconds seconds." }
    Write-Host ''
} else {
    Write-Host "sayit trigger armed on $Button (suppress=$suppress). Hold to talk."
}

$sayit = Join-Path $PSScriptRoot 'sayit.ps1'
$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
$lastReinstall = Get-Date
$probeLog = Join-Path $script:RunDir 'trigger-probe.log'
if ($Probe) { Add-Utf8Line -Path $probeLog -Line ('--- probe started {0} ---' -f (Get-Date -Format 'HH:mm:ss')) }

# A plain pump loop rather than a Timer event handler: an event handler runs in
# its own scope and cannot see this script's variables, and its console output
# does not reach a redirected stdout. DoEvents pumps the message queue, which is
# what makes the low-level hooks fire at all.
try {
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()

        foreach ($e in [Sayit.Trigger]::Drain()) {
            if ($Probe) {
                $state = if ($e.Down) { 'down' } else { 'up' }
                $inj   = if ($e.Injected) { ' [injected]' } else { '' }
                $line  = "{0} {1,-6} {2,-10} {3,-4} raw={4}{5}" -f (Get-Date -Format 'HH:mm:ss.fff'), $e.Kind, $e.Button, $state, $e.Raw, $inj
                Write-Host $line
                Add-Utf8Line -Path $probeLog -Line $line
            } else {
                $verb = if ($e.Down) { 'start' } else { 'stop' }
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$sayit,$verb `
                    -WindowStyle Hidden
            }
        }

        # The OS removes a slow hook without telling anyone, so re-arm periodically.
        if (((Get-Date) - $lastReinstall).TotalSeconds -ge 30) {
            [Sayit.Trigger]::Reinstall()
            $lastReinstall = Get-Date
        }

        Start-Sleep -Milliseconds 15
    }
} finally {
    [Sayit.Trigger]::Uninstall()
    # Never leave a recording running when the trigger goes away: without this a
    # release that never arrives would hold the microphone open until the
    # recorder's own time cap expires.
    if (-not $Probe) {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$sayit,'cancel' | Out-Null
    }
}
