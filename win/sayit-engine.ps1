# Select a local engine. Usage: sayit-engine.ps1 fast|accurate|status
[CmdletBinding()]
param([Parameter(Position=0)][ValidateSet('fast','accurate','status')][string]$Mode='status')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\engine.ps1"
Initialize-SayitDirs
$cfg = Import-DotEnv
if ($Mode -ne 'status') { Set-SayitEngineMode $Mode $cfg }
$selected = Get-SayitEngineMode
"Configured: $selected"
$launch = Get-SayitEngineLaunch $cfg $selected
if (Test-SayitEngineHealth (Get-SayitEngineHealth $launch.Port) $selected) {
    "Ready: $selected on 127.0.0.1:$($launch.Port)"
} else { Write-Error 'Selected engine is not ready.'; exit 1 }
