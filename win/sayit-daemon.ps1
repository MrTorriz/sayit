# Manage the selected local engine. Usage: sayit-daemon.ps1 start|stop|status|run
[CmdletBinding()]
param([Parameter(Position=0)][ValidateSet('start','stop','status','run')][string]$Action='status')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\engine.ps1"
Initialize-SayitDirs
$cfg = Import-DotEnv
$mode = Get-SayitEngineMode
$launch = Get-SayitEngineLaunch $cfg $mode
if ($Action -eq 'status') {
    if (Test-SayitEngineHealth (Get-SayitEngineHealth $launch.Port) $mode) { "running: $mode on 127.0.0.1:$($launch.Port)" }
    else { 'not running' }
    exit 0
}
$gate = Open-SayitEngineGate -Exclusive
try {
    if (Test-Path -LiteralPath (Join-Path $script:RunDir 'sayit.session')) {
        throw 'Finish or cancel the recording before changing the daemon.'
    }
    switch ($Action) {
        'start' { Start-SayitEngine $launch; "ready: $mode" }
        'stop' { Stop-SayitEngine $cfg; 'stopped' }
        'run' {
            Assert-SayitEngineLaunch $launch
            # Foreground diagnostics must not hold the switch lock indefinitely.
            $gate.Dispose(); $gate = $null
            & $launch.Exe @($launch.Arguments)
            exit $LASTEXITCODE
        }
    }
} finally { if ($null -ne $gate) { $gate.Dispose() } }
