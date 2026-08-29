# Contributing

Thanks for your interest in improving sayit. Bug reports, fixes and focused
features are all welcome.

sayit is one repository with two implementations. `bin/` is Linux (bash, plus
one Python file); `win/` is Windows (PowerShell 5.1, plus small C# helpers).
They share no code. Almost every change belongs to exactly one of them, and
knowing which decides what you have to run.

## Which platform does your change belong to?

| You touched | Platform | CI jobs that judge it |
| --- | --- | --- |
| `bin/`, `install.sh`, `tests/`, `docs/*.py` | Linux | `lint` and `test` |
| `win/` (`.ps1`, `lib/*.cs`, `tests/`) | Windows | `windows` |
| `README.md`, `docs/*.md`, `.github/` | Neither | review only |
| `.env.example` plus the code that reads the setting | Whichever side reads it | that side's jobs |

The workflow's globs make this exact: the lint job looks only at `bin/`,
`install.sh`, `tests/*.sh` and `docs/*.py`, the test job runs `bats tests/`,
and the Windows job covers `win/` and nothing else. The Windows
implementation cannot break the Linux jobs, or the reverse.

An unrecognised shebang inside one of those four globs is a hard CI failure,
not a skip — a new script needs a `bash`, `sh` or `python` shebang, or the
workflow needs a new arm.

Note that CI triggers only on pushes to `main` and on pull requests. A feature
branch gets no run of its own — open the pull request to get one.

## Getting started

Linux:

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh            # builds whisper.cpp, downloads models, creates .env
./bin/test-pipeline     # end-to-end smoke test (no microphone needed)
```

Windows:

```powershell
git clone https://github.com/MrTorriz/sayit.git
cd sayit
.\win\install.ps1       # checks prerequisites, builds whisper.cpp, creates .env
.\win\sayit-doctor.ps1  # reports what resolved and what did not
```

Full walkthroughs: [docs/INSTALL-LINUX.md](docs/INSTALL-LINUX.md) and
[docs/INSTALL-WINDOWS.md](docs/INSTALL-WINDOWS.md).

You do **not** need a working install to work on most of the code. The Linux
test suite and the Windows test suite both run without a microphone, a model
or a whisper.cpp build — see the two check lists below.

## Checks for a Linux change

All three run on any Linux machine. None needs a microphone, a compositor,
`ydotool`, a model or a whisper.cpp build.

```bash
# 1. Syntax, dispatched by shebang — the same loop CI runs
for f in bin/* install.sh tests/*.sh docs/*.py; do
    [ -f "$f" ] || continue
    case "$(head -1 "$f")" in
        *python*)     python3 -m py_compile "$f" ;;
        *bash*|*/sh)  bash -n "$f" ;;
        *)            echo "no known interpreter: $f" >&2; exit 1 ;;
    esac
done

# 2. shellcheck over the shell scripts only
scripts=()
for f in bin/* install.sh tests/*.sh docs/*.py; do
    [ -f "$f" ] || continue
    case "$(head -1 "$f")" in *bash*|*/sh) scripts+=("$f") ;; esac
done
shellcheck "${scripts[@]}"

# 3. The bats suite
bats tests/

# 4. Only if you changed the overlay's pill: the logo is generated from it
python3 docs/build-logo.py --check
```

Step 4 exists because the logo is not a separate drawing. `docs/logo.svg` is
the overlay's pill, written out of the overlay's own constants by
`docs/build-logo.py`. Change `WIDTH`, `MARK_SCALE`, `BAR_MAX_U`, `LAMP_LIT` or
the wordmark outlines and the check fails; rerun the script without `--check`
and commit what it writes. The two were maintained separately once, and the
README ended up showing a mark the product had stopped drawing.

The shebang filter in steps 1 and 2 is not decoration. `bin/sayit-overlay` is
Python, and a plain `shellcheck bin/*` fails on it with `SC1071` before it has
checked anything else.

Requirements: bash 5.0 or newer, shellcheck, bats 1.4 or newer, plus `jq`,
`perl` and `python3` — the suite uses all three through the scripts under
test. Every system tool that touches hardware (`pw-record`, `pactl`,
`notify-send`, `ydotool`) is replaced by a stub on a cut-down `PATH`, and the
overlay tests clear `WAYLAND_DISPLAY` so no window is ever created.

## Checks for a Windows change

These need a real Windows machine. There is no cross-platform substitute:
`Add-Type` compiles against the in-box C# compiler, and PSScriptAnalyzer and
Pester run against Windows PowerShell. None of them needs a microphone — the
suite refuses to open one by design.

```powershell
# 1. Parse every script (parse only, nothing is executed)
$failed = $false
Get-ChildItem win -Recurse -Filter *.ps1 | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors) { $failed = $true; Write-Host "$($_.Name): $($errors[0].Message)" }
}
if ($failed) { Write-Host 'parse errors above' }

# 2. Compile the C# helpers, as CI does
. .\win\lib\common.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition (Read-Utf8Text "win\lib\Recorder.cs") -Language CSharp
Add-Type -TypeDefinition (Merge-CSharpSources -Sources @(
           (Read-Utf8Text "win\lib\Trigger.cs"),
           (Read-Utf8Text "win\lib\Injector.cs"))) `
         -Language CSharp -ReferencedAssemblies 'System.Windows.Forms','System.Drawing'
Add-Type -TypeDefinition (Read-Utf8Text "win\lib\RawInput.cs") `
         -Language CSharp -ReferencedAssemblies 'System.Windows.Forms','System.Drawing'

# 3. Static analysis, errors only
Invoke-ScriptAnalyzer -Path win -Recurse -Severity Error

# 4. The Pester suite
.\win\tests\Invoke-Tests.ps1
```

Requirements: Windows PowerShell 5.1, PSScriptAnalyzer, and Pester 5.0 or
newer. Windows ships Pester 3.4.0, which reads `Should -Be` as a positional
argument rather than an operator and would report nonsense;
`Invoke-Tests.ps1` refuses to run under it and prints the install command.

`Trigger.cs` and `Injector.cs` must be compiled together — `Injector`
references a type from `Trigger` — and plain concatenation is not valid C#,
which is why `Merge-CSharpSources` hoists the `using` directives first.

## Machine checks, when you have a working install

Neither of these runs in CI, and neither is required for a change CI can
judge. They check your machine, not your diff.

```bash
./bin/test-pipeline           # Linux: synthetic voice through the whole pipeline
./bin/sayit doctor            # Linux: read-only check of the recording path
```

```powershell
.\win\sayit-doctor.ps1        # Windows: same job for the Windows path
```

`test-pipeline` needs `espeak-ng` and a working `bin/sayit-transcribe`, so in
practice a completed `./install.sh`. It opens no microphone: it synthesises
the test audio with `espeak-ng` and feeds the WAV straight to the transcriber.

`bin/sayit doctor` reads and reports; it starts no recording and writes
nothing. Note that it sources `.env` as shell, which is a property of the
config format on Linux. The Windows doctor is read-only in the same sense —
it opens no capture stream and executes none of the fixes it suggests — but it
does create its own state directories on first run, so it is not quite
"touches nothing".

Neither dumps `.env`, the wordlist or dictated text, and neither prints the
values of `INITIAL_PROMPT` or `SUPPRESS_REGEX`. Both do print resolved local
paths, device names and most setting values, so treat their output as
something to read before sharing, not as pre-sanitised.

## What nothing can check

Recording, Bluetooth profile switching, `ydotool`/uinput injection, the
layer-shell overlay, the Windows input hook and scheduled-task registration
are all hardware- or session-bound, and both suites deliberately exclude
them: opening the microphone from a test run is not acceptable in a dictation
tool. A change in that territory needs a note in the pull request saying
which machine and desktop you exercised it on.

## Code style

### Shared

- All code, comments and documentation in English. No emojis.
- Errors go to stderr, and a failure exits non-zero.
- A new setting needs all three: a default in `.env.example`, a row in
  [docs/CONFIGURATION.md](docs/CONFIGURATION.md), and the code that reads it.
- Documentation that overstates is a defect, not marketing. Do not describe a
  behaviour the code does not have.

### Linux (`bin/`)

- Bash by default: `#!/usr/bin/env bash`, `set -euo pipefail`, and a header
  comment covering usage, arguments and exit codes.
- Bash 5.0 or newer. `EPOCHREALTIME` is used by the profiling helpers, and on
  bash 4 it expands to nothing rather than failing.
- Another language only where bash genuinely cannot do the job. Today that is
  one file: `bin/sayit-overlay` is Python because the pill is drawn through
  GTK and layer-shell bindings. Its `gi` imports are deliberately inside
  functions, so the file compiles and its tests run without GTK installed.
  `bin/sayit-wordlist` shells out to perl for its regex engine but is itself
  a bash script.
- CI dispatches on the shebang, so a new Python file goes through
  `py_compile` and a new shell file through `shellcheck` with no workflow
  change — as long as it lands inside one of the four globs above.

### Windows (`win/`)

- Windows PowerShell 5.1 is the target, not PowerShell 7. Every process the
  scripts start is `powershell.exe`, and CI runs the same.
- Every entry point sets `Set-StrictMode -Version 2.0` and
  `$ErrorActionPreference = 'Stop'`, dot-sources `win\lib\common.ps1`, and
  carries a header comment covering usage, parameters and exit codes.
- File IO goes through `Read-Utf8Text` / `Add-Utf8Line` / `Write-Utf8Text`.
  `Out-File -Encoding utf8` writes a BOM on 5.1, which corrupts
  `history.jsonl`.
- Paths passed to `Start-Process` go through `Format-ProcessArgument`.
  `-ArgumentList` joins its elements with spaces and quotes nothing, so an
  unquoted path with a space arrives split in two.
- The C# in `win\lib\` is written to **C# 5**. `Add-Type` on Windows
  PowerShell 5.1 uses the in-box compiler, which accepts nothing newer: no
  string interpolation, no `?.`, no expression-bodied members, no `nameof`,
  no `out var`, no `async`. Modern C# compiles in an IDE and fails in CI.

## Before opening a pull request

1. Run the checks for your platform, from the matching list above.
2. Update the documentation if behaviour or flags changed: the README when it
   affects the landing page, the relevant document under `docs/`, and the
   script's own header comment.
3. Keep the pull request focused on one change.
4. Describe what changed and why. Reviewers should not have to
   reverse-engineer intent from the diff.

## Scope

Deliberate non-goals — pull requests for these will be declined: cloud STT
backends, wake-word activation, and GUI frontends. Speech recognition stays on
the machine and everything is driven from the command line. The one optional
step that sends anything anywhere is `LLM_CLEANUP`, which POSTs text to a
configurable URL and is off by default; see
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#settings).
