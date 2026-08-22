# sayit-rawprobe.ps1 - identify what a button actually reports at HID level.
#
# Usage:  .\sayit-rawprobe.ps1 [-Seconds 20]
#
# Diagnostic only: registers for raw mouse and consumer-control input and prints
# every transition. Nothing is suppressed and no dictation is started. Use it when
# a mouse button produces no low-level hook event, which happens when the device
# reports the button as a consumer-control usage rather than as a mouse button.
#
# Exit codes: 0 normal, 1 raw input registration failed.

[CmdletBinding()]
param([int]$Seconds = 20)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

Add-Type -AssemblyName System.Windows.Forms

$cs = Read-Utf8Text -Path (Join-Path $PSScriptRoot 'lib\RawInput.cs')
if (-not $cs) { Write-Error 'lib\RawInput.cs not found'; exit 1 }
Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Windows.Forms','System.Drawing'

$log = Join-Path $script:RunDir 'rawprobe.log'
Add-Utf8Line -Path $log -Line ('--- rawprobe started {0} ---' -f (Get-Date -Format 'HH:mm:ss'))

$window = New-Object Sayit.RawInputWindow
try {
    [Sayit.RawInput]::Register($window.Handle, $true)
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host "Raw input probe running for $Seconds seconds. Press the button in question."

$deadline = (Get-Date).AddSeconds($Seconds)
try {
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        foreach ($e in [Sayit.RawInput]::Drain()) {
            $state = if ($e.Down) { 'down' } else { 'up' }
            $line = "{0,-6} {1,-16} {2,-4} dev={3} {4}" -f $e.Source, $e.Button, $state, $e.DeviceId, $e.RawBytes
            Write-Host $line
            Add-Utf8Line -Path $log -Line $line
        }
        Start-Sleep -Milliseconds 10
    }
} finally {
    $window.DestroyHandle()
}
