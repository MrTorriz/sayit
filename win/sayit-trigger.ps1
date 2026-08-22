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
# Exit codes: 0 normal, 1 the hook could not be installed, 3 another trigger is
# already holding the hook in this session.

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

# Single-instance guard. Two hooks bound to the same button start and stop the
# dictation twice per press, which is worse than having none at all, and it is
# an easy state to reach: the autostart task brings one back while another is
# still running, or the same script is started by hand from a shell.
#
# A named mutex rather than a pid file because the kernel releases it however
# this process dies, so there is no stale state to clean up and no window where
# a recycled pid looks like a live trigger. Local\ scopes it to the logon
# session, which is the scope a desktop's input hook belongs to.
#
# Probe mode is exempt: it installs a hook but suppresses nothing and starts no
# dictation, so running it beside a live trigger is a diagnostic, not a clash.
$script:InstanceMutex = $null
if (-not $Probe) {
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\sayit-trigger')
    $owned = $false
    try {
        $owned = $script:InstanceMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # The previous trigger died without releasing it. The hook died with it.
        $owned = $true
    }
    if (-not $owned) {
        $script:InstanceMutex.Dispose()
        Write-Host 'Another sayit trigger already holds the hook in this session - not arming a second one.'
        exit 3
    }
}

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
# Documented exit code 1. SetWindowsHookEx failing is otherwise invisible: the
# pump would run all session long having observed nothing at all.
if (-not [Sayit.Trigger]::Install()) {
    [Sayit.Trigger]::Uninstall()
    Write-SayitError 'trigger: SetWindowsHookEx failed'
    Write-Error 'Could not install the input hook, so no button would ever reach the trigger.'
    exit 1
}

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

# Heartbeat. A trigger process that is alive but has stopped pumping messages is
# as useless as one that exited, and from the outside the two look the same: the
# process is there either way. Only this loop can tell them apart, so it says so
# every few seconds and sayit-autostart.ps1 restarts the trigger when the file
# goes stale. Probe mode holds nothing worth restarting and writes no beat.
$beatFile = Join-Path $script:RunDir 'trigger.beat'
$lastBeat = [DateTime]::MinValue
function Write-TriggerBeat {
    # A failed write must never take the trigger down; a stale beat only costs a
    # restart, and the supervisor waits 90 s before it draws that conclusion.
    try { Write-Utf8Text -Path $beatFile -Text ((Get-Date -Format 'o') + "`n") } catch { }
}
if (-not $Probe) { Write-TriggerBeat; $lastBeat = Get-Date }

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

        if (-not $Probe -and ((Get-Date) - $lastBeat).TotalSeconds -ge 5) {
            Write-TriggerBeat
            $lastBeat = Get-Date
        }

        # The OS removes a slow hook without telling anyone, so re-arm periodically.
        if (((Get-Date) - $lastReinstall).TotalSeconds -ge 30) {
            if (-not [Sayit.Trigger]::Reinstall()) {
                Write-SayitError 'trigger: re-arming the input hook failed'
            }
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
    if ($null -ne $script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        try { $script:InstanceMutex.Dispose() } catch { }
    }
}
