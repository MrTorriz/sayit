# Install and verify the optional Turbo runtime without selecting it.
# Usage: install-openvino.ps1 [-Python python] [-ModelSource DIR]
[CmdletBinding()]
param([string]$Python='python', [string]$ModelSource='')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\engine.ps1"
Initialize-SayitDirs
$cfg = Import-DotEnv
$launch = Get-SayitEngineLaunch $cfg 'fast'
if ((Test-SayitEngineHealth (Get-SayitEngineHealth $launch.Port) 'fast') -or
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $launch.Exe }).Count -gt 0) {
    throw 'Switch to accurate before updating the running Turbo runtime.'
}
$runtime = Get-Setting -Env $cfg -Name 'OPENVINO_HOME' -Default (Join-Path $script:DataDir 'openvino')
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$lock = [System.IO.File]::Open((Join-Path $runtime 'install.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if (-not (Test-Path -LiteralPath $launch.Exe)) {
        & $Python -m venv (Join-Path $runtime 'venv')
        if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 or newer with venv is required.' }
    }
    & $launch.Exe -I -m pip install --disable-pip-version-check --only-binary=:all: `
        -r (Join-Path $script:RepoRoot 'engines\openvino\requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned runtime installation failed.' }
    $device = Get-Setting -Env $cfg -Name 'OPENVINO_DEVICE' -Default 'GPU'
    & $launch.Exe -I -c 'import os; os.environ[''CI'']=''true''; import sys, openvino as ov; print(ov.Core().get_property(sys.argv[1], ''FULL_DEVICE_NAME''))' $device
    if ($LASTEXITCODE -ne 0) { throw 'Configured OpenVINO device is unavailable.' }
    $download = @((Join-Path $script:RepoRoot 'engines\openvino\download.py'), '--destination', (Join-Path $runtime 'model'))
    if ($ModelSource) { $download += @('--source', $ModelSource) }
    & $launch.Exe -I @download
    if ($LASTEXITCODE -ne 0) { throw 'Model download or checksum verification failed.' }
    Assert-SayitEngineLaunch $launch
    & $launch.Exe @($launch.Arguments) --check
    if ($LASTEXITCODE -ne 0) { throw 'Model or native speech detector verification failed.' }
    'Turbo verified. Select it with: .\win\sayit-engine.ps1 fast'
} finally { $lock.Dispose() }
