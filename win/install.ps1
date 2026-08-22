# install.ps1 - one-time setup for the Windows side of sayit.
#
# Usage:
#   .\win\install.ps1                      interactive setup
#   .\win\install.ps1 -Yes                 answer yes to every prompt
#   .\win\install.ps1 -Rebuild             rebuild whisper.cpp at the pinned tag
#   .\win\install.ps1 -SkipBuild -SkipModel   only .env, wordlist and autostart
#
# Arguments:
#   -SkipBuild     do not build whisper.cpp, and only report the build tools
#   -SkipModel     do not check the model files
#   -Yes           answer yes to prompts instead of asking
#   -Rebuild       fetch and rebuild whisper.cpp at the pinned reference, even
#                  when a build is already present
#   -NoAutostart   do not offer to register the logon task
#
# What it does, in order:
#   1. Checks git, cmake, the MSVC C++ build tools and the Vulkan SDK. It
#      reports what is missing together with a winget command or a URL, and
#      installs nothing without being told to.
#   2. Clones and builds whisper.cpp at the pinned reference below, into
#      %LOCALAPPDATA%\sayit\whisper.cpp. With the Vulkan SDK present it
#      configures -DGGML_VULKAN=ON; without it, it builds for CPU and says so.
#   3. Verifies that the models are present in the repo's models\ directory and
#      prints their sha256. It NEVER downloads them - they are supplied
#      separately - and says plainly when one is missing.
#   4. Creates .env from .env.example when there is none, rewriting the two
#      Unix paths in it (WHISPER_CLI, WHISPER_SERVER) to the Windows build.
#      An existing .env is never overwritten; the settings it lacks are listed.
#   5. Seeds the wordlist from config\wordlist.example.tsv when there is none.
#   6. Offers to register a scheduled task named "sayit" that runs at logon.
#
# Re-running is safe: an existing build, .env, wordlist or task is left alone.
#
# Removing the autostart task:
#   Unregister-ScheduledTask -TaskName 'sayit' -Confirm:$false
#
# Exit codes:
#   0  Setup completed
#   1  A required prerequisite is missing: a tool the user declined to install,
#      a tool that needs a new shell before it is on PATH, or the Whisper model
#   2  whisper.cpp could not be fetched or built

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipModel,
    [switch]$Yes,
    [switch]$Rebuild,
    [switch]$NoAutostart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\common.ps1"
Initialize-SayitDirs

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Write-Log  { param([string]$Text) "[sayit] $Text" }
function Write-Warn { param([string]$Text) "[warning] $Text" }
function Write-Fail { param([string]$Text) [Console]::Error.WriteLine("[error] $Text") }

# Read-Host has nothing to read when stdin is not a console, so an unattended
# run declines every optional step instead of failing.
function Confirm-Step {
    param([Parameter(Mandatory)][string]$Question)
    if ($Yes) { return $true }
    $answer = $null
    try { $answer = Read-Host "$Question (y/N)" } catch { return $false }
    if ([string]::IsNullOrEmpty($answer)) { return $false }
    return ($answer -match '^[yY]')
}

# Pinned upstream revision for whisper.cpp, the same release the Linux
# install.sh builds. Bump it deliberately; -Rebuild applies the new value.
$whisperRef = 'v1.9.2'
$whisperUrl = 'https://github.com/ggml-org/whisper.cpp.git'
$whisperSrc = Join-Path $env:LOCALAPPDATA 'sayit\whisper.cpp'

# Official sha256 checksums for the files that install.sh downloads on Linux,
# taken from the Hugging Face LFS pointer files. Only used to tell the user
# whether the model they were given is the published one.
$modelSha = '7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0'
$vadSha   = '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf'

$modelFile = Join-Path $script:RepoRoot 'models\ggml-kb-whisper-medium-q5_0.bin'
$vadFile   = Join-Path $script:RepoRoot 'models\ggml-silero-v5.1.2.bin'

# --- 1. Prerequisites -------------------------------------------------------

Write-Log 'Checking prerequisites'

function Test-Msvc {
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) {
        $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $found = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath
            return [bool]$found
        }
    }
    # No Visual Studio Installer: the compiler is still usable if a developer
    # shell put it on PATH.
    return [bool](Get-Command cl.exe -ErrorAction SilentlyContinue)
}

function Test-VulkanSdk {
    if ($env:VULKAN_SDK -and (Test-Path -LiteralPath $env:VULKAN_SDK)) { return $true }
    return [bool](Get-Command glslc.exe -ErrorAction SilentlyContinue)
}

$required = @(
    [pscustomobject]@{
        Name   = 'git'
        Test   = { [bool](Get-Command git -ErrorAction SilentlyContinue) }
        Winget = 'Git.Git'
        Url    = 'https://git-scm.com/download/win'
    },
    [pscustomobject]@{
        Name   = 'cmake'
        Test   = { [bool](Get-Command cmake -ErrorAction SilentlyContinue) }
        Winget = 'Kitware.CMake'
        Url    = 'https://cmake.org/download/'
    },
    [pscustomobject]@{
        Name   = 'MSVC C++ build tools'
        Test   = { Test-Msvc }
        Winget = 'Microsoft.VisualStudio.2022.BuildTools'
        Url    = 'https://visualstudio.microsoft.com/downloads/'
    }
)

$missing = @()
foreach ($tool in $required) {
    if (& $tool.Test) {
        Write-Log ("  found: {0}" -f $tool.Name)
    } else {
        Write-Warn ("  missing: {0}" -f $tool.Name)
        $missing += $tool
    }
}

$haveVulkan = Test-VulkanSdk
if ($haveVulkan) {
    Write-Log '  found: Vulkan SDK'
} else {
    Write-Warn '  missing: Vulkan SDK (optional - without it whisper.cpp is built for CPU)'
    Write-Warn '    winget install --id KhronosGroup.VulkanSDK -e'
    Write-Warn '    https://vulkan.lunarg.com/sdk/home'
}

if ($missing.Count -gt 0) {
    foreach ($tool in $missing) {
        Write-Warn ("{0}:" -f $tool.Name)
        Write-Warn ("    winget install --id {0} -e" -f $tool.Winget)
        Write-Warn ("    {0}" -f $tool.Url)
    }
    if ($SkipBuild) {
        Write-Warn 'Only the whisper.cpp build needs these, and -SkipBuild was given - continuing'
    } else {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        $installed = $false
        if ($winget -and (Confirm-Step 'Install the missing prerequisites now with winget?')) {
            foreach ($tool in $missing) {
                Write-Log ("Installing {0}" -f $tool.Name)
                & winget install --id $tool.Winget -e --accept-source-agreements --accept-package-agreements
                if ($LASTEXITCODE -ne 0) {
                    Write-Fail ("winget failed for {0} (exit {1})" -f $tool.Name, $LASTEXITCODE)
                }
            }
            $installed = $true
        } elseif (-not $winget) {
            Write-Warn 'winget is not available - install the tools above by hand'
        }
        if ($installed) {
            Write-Fail 'Installed tools reach PATH only in a new shell. Open a new PowerShell and re-run this script.'
            exit 1
        }
        Write-Fail 'Cannot build whisper.cpp without the tools above. Install them, or re-run with -SkipBuild.'
        exit 1
    }
}

# --- 2. whisper.cpp ---------------------------------------------------------

# The build directory decides the default paths in sayit-transcribe.ps1 and
# sayit-daemon.ps1, which point at build-vulkan\bin\Release. A CPU build gets a
# directory of its own so the two never overwrite each other, and the settings
# it needs are printed below.
$buildName = 'build-cpu'
if ($haveVulkan) { $buildName = 'build-vulkan' }
$buildDir  = Join-Path $whisperSrc $buildName
$cliOut    = Join-Path $buildDir 'bin\Release\whisper-cli.exe'
$serverOut = Join-Path $buildDir 'bin\Release\whisper-server.exe'

if ($SkipBuild) {
    Write-Log 'Skipping the whisper.cpp build (-SkipBuild)'
} elseif ((Test-Path -LiteralPath $cliOut) -and -not $Rebuild) {
    Write-Log "whisper-cli already built at $cliOut"
    Write-Log "Run '.\win\install.ps1 -Rebuild' to rebuild it at $whisperRef"
} else {
    Write-Log "Fetching whisper.cpp $whisperRef into $whisperSrc"
    if (-not (Test-Path -LiteralPath $whisperSrc)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $whisperSrc) | Out-Null
        & git clone --depth 1 --branch $whisperRef $whisperUrl $whisperSrc
        if ($LASTEXITCODE -ne 0) { Write-Fail 'git clone failed'; exit 2 }
    } else {
        # Guard against a directory left behind by an interrupted clone.
        & git -C $whisperSrc rev-parse --git-dir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "$whisperSrc exists but is not a git repository (interrupted clone?) - remove it and re-run"
            exit 2
        }
        & git -C $whisperSrc fetch --depth 1 origin tag $whisperRef
        if ($LASTEXITCODE -ne 0) { & git -C $whisperSrc fetch --depth 1 origin $whisperRef }
        if ($LASTEXITCODE -ne 0) { Write-Fail "could not fetch $whisperRef"; exit 2 }
        & git -C $whisperSrc checkout --detach $whisperRef
        if ($LASTEXITCODE -ne 0) { Write-Fail "could not check out $whisperRef"; exit 2 }
    }

    $cmakeArgs = @('-S', $whisperSrc, '-B', $buildDir, '-DCMAKE_BUILD_TYPE=Release')
    if ($haveVulkan) {
        $cmakeArgs += '-DGGML_VULKAN=ON'
        Write-Log 'Configuring whisper.cpp with the Vulkan backend'
    } else {
        Write-Warn 'No Vulkan SDK - configuring a CPU-only build. It works, it is just slower.'
        Write-Warn 'Install the Vulkan SDK and re-run with -Rebuild to get GPU support.'
    }
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { Write-Fail 'cmake configuration failed'; exit 2 }

    $cores = [Environment]::ProcessorCount
    Write-Log "Building whisper.cpp ($cores parallel jobs) - this takes a while"
    & cmake --build $buildDir --config Release -j $cores
    if ($LASTEXITCODE -ne 0) { Write-Fail 'the whisper.cpp build failed'; exit 2 }

    if (-not (Test-Path -LiteralPath $cliOut)) {
        # bin\Release is where a Visual Studio generator puts it, and it is what
        # the other scripts expect. A single-config generator puts it elsewhere,
        # which is a working build with a path sayit does not know about.
        $found = @(Get-ChildItem -LiteralPath $buildDir -Filter 'whisper-cli.exe' -Recurse `
                                 -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Write-Fail "the build finished but produced no $cliOut"
            exit 2
        }
        Write-Warn ("the build put whisper-cli somewhere sayit does not look by default: {0}" -f $found[0].FullName)
        Write-Warn 'set WHISPER_CLI and WHISPER_SERVER in .env to the built binaries'
    }

    # Record what was built, for reproducibility and rollback. sayit-doctor.ps1
    # reads this back.
    $commit = & git -C $whisperSrc rev-parse HEAD
    $vulkanText = 'no'
    if ($haveVulkan) { $vulkanText = 'yes' }
    $info = @(
        "ref=$whisperRef",
        "commit=$commit",
        "vulkan=$vulkanText",
        "build=$buildName",
        ("date=" + (Get-Date -Format 's'))
    ) -join "`n"
    Write-Utf8Text -Path (Join-Path $whisperSrc '.sayit-build-info') -Text ($info + "`n")

    if (Test-Path -LiteralPath $cliOut) { Write-Log "Built: $cliOut" }
    if (-not $haveVulkan) {
        Write-Warn 'A CPU build lives outside the paths sayit uses by default. Put these in .env:'
        Write-Warn ('    WHISPER_CLI="{0}"' -f $cliOut)
        Write-Warn ('    WHISPER_SERVER="{0}"' -f $serverOut)
    }
}

# --- 3. Models --------------------------------------------------------------

$modelMissing = $false
if ($SkipModel) {
    Write-Log 'Skipping the model check (-SkipModel)'
} else {
    Write-Log 'Checking the models (this script never downloads them)'

    if (Test-Path -LiteralPath $modelFile) {
        $hash = (Get-FileHash -LiteralPath $modelFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Log "  Whisper model: $modelFile"
        Write-Log "    sha256 $hash"
        if ($hash -eq $modelSha) {
            Write-Log '    matches the published KB-Whisper medium q5_0 checksum'
        } else {
            Write-Warn '    this is not the published KB-Whisper medium q5_0 file'
            Write-Warn '    (expected if you were given a different model - set MODEL_PATH in .env)'
        }
    } else {
        Write-Warn "  Whisper model missing: $modelFile"
        Write-Warn '  The models are supplied separately and are not downloaded here.'
        Write-Warn '  Put the .bin file in the repo models\ directory, or point MODEL_PATH at it.'
        $modelMissing = $true
    }

    if (Test-Path -LiteralPath $vadFile) {
        $hash = (Get-FileHash -LiteralPath $vadFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Log "  VAD model: $vadFile"
        Write-Log "    sha256 $hash"
        if ($hash -eq $vadSha) {
            Write-Log '    matches the published Silero v5.1.2 checksum'
        } else {
            Write-Warn '    this is not the published Silero v5.1.2 file'
        }
    } else {
        Write-Warn "  VAD model missing: $vadFile"
        Write-Warn '  Voice activity detection stays off until the file exists; dictation still works.'
    }
}

# --- 4. .env ----------------------------------------------------------------

# Which build a fresh .env should point at: an existing one wins over the one
# this run would have produced, so re-running with -SkipBuild never writes a
# path to a build that is not there.
$buildUsed = $buildName
foreach ($candidate in @($buildName, 'build-vulkan', 'build-cpu')) {
    $probe = Join-Path $whisperSrc ($candidate + '\bin\Release\whisper-cli.exe')
    if (Test-Path -LiteralPath $probe) { $buildUsed = $candidate; break }
}

$envFile     = Join-Path $script:RepoRoot '.env'
$envTemplate = Join-Path $script:RepoRoot '.env.example'

function Get-SettingNames {
    param([Parameter(Mandatory)][string]$Path)
    $names = @()
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $names += $matches[1] }
    }
    return $names
}

if (-not (Test-Path -LiteralPath $envTemplate)) {
    Write-Warn ".env.example not found at $envTemplate - skipping the .env step"
} elseif (Test-Path -LiteralPath $envFile) {
    Write-Log '.env already exists - left untouched'
    # Surface template settings the existing .env lacks, so an upgrade never
    # runs on in-script fallback defaults without the user knowing.
    $have = Get-SettingNames -Path $envFile
    $want = Get-SettingNames -Path $envTemplate
    $lacking = @($want | Where-Object { $have -notcontains $_ } | Select-Object -Unique)
    if ($lacking.Count -gt 0) {
        Write-Warn ("Settings in .env.example that your .env lacks: {0}" -f ($lacking -join ', '))
        Write-Warn 'Copy the ones you want from .env.example (their defaults apply meanwhile)'
    }
} else {
    # .env.example is shared with the Linux side, where WHISPER_CLI and
    # WHISPER_SERVER are Unix paths that mean nothing here. Copying it verbatim
    # would hand Windows a configuration that cannot find either binary, so
    # those two lines are rewritten - as %LOCALAPPDATA%-relative values, which
    # Import-DotEnv expands, so the file stays machine-independent.
    $cliValue    = '%LOCALAPPDATA%\sayit\whisper.cpp\' + $buildUsed + '\bin\Release\whisper-cli.exe'
    $serverValue = '%LOCALAPPDATA%\sayit\whisper.cpp\' + $buildUsed + '\bin\Release\whisper-server.exe'
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($envTemplate, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -match '^WHISPER_CLI=') {
            $out.Add('WHISPER_CLI="' + $cliValue + '"')
        } elseif ($line -match '^WHISPER_SERVER=') {
            $out.Add('WHISPER_SERVER="' + $serverValue + '"')
        } else {
            $out.Add($line)
        }
    }
    # LF, like every other text file in this repository.
    Write-Utf8Text -Path $envFile -Text (($out -join "`n") + "`n")
    Write-Log 'Created .env from .env.example'
    Write-Log "  WHISPER_CLI and WHISPER_SERVER point at the $buildUsed build"
}

# --- 5. Wordlist ------------------------------------------------------------

$cfg = Import-DotEnv
$wordlist = Get-Setting -Env $cfg -Name 'WORDLIST' `
                        -Default (Join-Path $script:ConfigDir 'wordlist.tsv')
$wordlistSeed = Join-Path $script:RepoRoot 'config\wordlist.example.tsv'

if (Test-Path -LiteralPath $wordlist) {
    Write-Log "Wordlist already exists at $wordlist - left untouched"
} elseif (-not (Test-Path -LiteralPath $wordlistSeed)) {
    Write-Warn "No wordlist seed at $wordlistSeed - starting without one"
} else {
    $dir = Split-Path -Parent $wordlist
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Copy-Item -LiteralPath $wordlistSeed -Destination $wordlist
    Write-Log "Seeded the wordlist at $wordlist"
}

# --- 6. Autostart -----------------------------------------------------------

$taskName = 'sayit'

if ($NoAutostart) {
    Write-Log 'Skipping the autostart task (-NoAutostart)'
} else {
    $existing = $null
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    } catch {
        $existing = $null
    }

    if ($existing) {
        Write-Log "Scheduled task '$taskName' already registered - left untouched"
    } else {
        Write-Log 'An optional scheduled task can start sayit at logon. It runs two'
        Write-Log 'actions in order: sayit-daemon.ps1 start, which returns once the'
        Write-Log 'model server answers, and sayit-trigger.ps1, which keeps running'
        Write-Log 'and holds the push-to-talk hook.'
        if (Confirm-Step "Register the scheduled task '$taskName' to run at logon?") {
            try {
                $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $daemon  = Join-Path $PSScriptRoot 'sayit-daemon.ps1'
                $trigger = Join-Path $PSScriptRoot 'sayit-trigger.ps1'
                $common  = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File'
                $actions = @(
                    (New-ScheduledTaskAction -Execute $psExe -Argument ('{0} "{1}" start' -f $common, $daemon)),
                    (New-ScheduledTaskAction -Execute $psExe -Argument ('{0} "{1}"' -f $common, $trigger))
                )
                $atLogon  = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
                # No execution time limit: the trigger is meant to run all session.
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                -MultipleInstances IgnoreNew
                Register-ScheduledTask -TaskName $taskName -Action $actions -Trigger $atLogon `
                    -Settings $settings -Description 'sayit push-to-talk dictation' | Out-Null
                Write-Log "Registered the scheduled task '$taskName'"
            } catch {
                Write-Warn ("Could not register the scheduled task: {0}" -f $_.Exception.Message)
                Write-Warn 'Start the two scripts by hand, or register the task from an elevated shell.'
            }
        } else {
            Write-Log 'No task registered'
        }
    }
    Write-Log "Remove it later with: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
}

# --- Result -----------------------------------------------------------------

if ($modelMissing) {
    Write-Fail 'Setup is incomplete: the Whisper model is missing (see above).'
    exit 1
}

Write-Log 'Done. Check the result with: .\win\sayit-doctor.ps1'
Write-Log 'Then hold your trigger button and speak: .\win\sayit-trigger.ps1'
exit 0
