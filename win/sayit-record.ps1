# sayit-record.ps1 - capture the microphone to a 16 kHz mono 16-bit WAV.
#
# Usage:
#   .\sayit-record.ps1 -OutFile <path> [-StopEvent <name>] [-Device <sel>]
#                      [-MaxSeconds 300] [-Seconds N]
#   .\sayit-record.ps1 -List
#
# Recording runs until the named stop event is signalled, or -Seconds elapses,
# or MaxSeconds is reached. Signalling an event rather than killing the process
# is what lets the recorder finalise the RIFF header itself, so a truncated or
# invalid WAV is not a failure mode here.
#
# -Device accepts an MMDevice endpoint ID (preferred, stable) or a device name.
# Empty selects the Windows default capture device.
#
# Exit codes: 0 recorded, 1 bad arguments or the device could not be opened,
#             2 recorded but the capture was digitally silent.

[CmdletBinding()]
param(
    [string]$OutFile,
    [string]$StopEvent,
    [string]$Device,
    [string]$LevelFile,
    [int]$MaxSeconds = 0,
    [int]$Seconds = 0,
    [switch]$List
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

$cs = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\Recorder.cs')
if (-not $cs) { Write-Error 'lib\Recorder.cs not found'; exit 1 }
Add-Type -TypeDefinition $cs -Language CSharp

if ($List) {
    foreach ($d in [Sayit.Recorder]::ListDevices()) {
        [pscustomobject]@{
            Index      = $d.Index
            Name       = $d.Name
            EndpointId = $d.EndpointId
        }
    }
    exit 0
}

if (-not $OutFile) { Write-Error 'Usage: sayit-record.ps1 -OutFile <path> [-StopEvent <name>]'; exit 1 }

$cfg = Import-DotEnv
if (-not $Device) { $Device = Get-Setting -Env $cfg -Name 'AUDIO_SOURCE' -Default '' }

# A hard cap on how long the microphone can stay open. It exists for the case
# where the process that started the recording dies before it can stop it: a
# dictation tool holding the microphone open indefinitely is a privacy defect,
# not merely untidy.
if ($MaxSeconds -le 0) {
    $MaxSeconds = [int](Get-Setting -Env $cfg -Name 'MAX_RECORD_SECONDS' -Default '120')
}

$index = [Sayit.Recorder]::ResolveDevice($Device)
if ($index -eq -2) {
    Write-SayitError "record: configured AUDIO_SOURCE not found"
    Write-Error "Configured audio device not found. Run sayit-record.ps1 -List to see what is available."
    exit 1
}

# A stop event that nobody signals still terminates via MaxSeconds, so the
# recorder can never hold the microphone open indefinitely.
$stopHandle = $null
$createdNew = $false
if ($StopEvent) {
    $stopHandle = New-Object System.Threading.EventWaitHandle(
        $false, [System.Threading.EventResetMode]::ManualReset, $StopEvent, [ref]$createdNew)
} else {
    $stopHandle = New-Object System.Threading.ManualResetEvent($false)
}

if ($Seconds -gt 0 -and $Seconds -lt $MaxSeconds) { $MaxSeconds = $Seconds }

# Publishing the level from here means the recording indicator never has to open
# a second capture stream to animate.
if (-not $LevelFile) { $LevelFile = Join-Path $script:RunDir 'level' }
[Sayit.Recorder]::LevelFile = $LevelFile

$peak = 0
try {
    $frames = [Sayit.Recorder]::CaptureToWav($OutFile, $index, $stopHandle, $MaxSeconds, [ref]$peak)
} catch {
    Write-SayitError "record: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
} finally {
    $stopHandle.Dispose()
}

$seconds = [math]::Round($frames / [double][Sayit.Recorder]::SampleRate, 2)
Write-Verbose "recorded $frames frames ($seconds s), peak $peak"

# A digitally silent capture means the audio path is broken rather than that the
# user said nothing quietly; report it distinctly so the caller can explain it.
if ($peak -eq 0 -and $frames -gt 0) {
    Write-SayitError 'record: capture was digitally silent (peak 0)'
    exit 2
}

exit 0
