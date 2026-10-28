## What

<!-- What does this PR change, and why? -->

## Platform

<!-- Tick one. It decides which checks below apply. -->

- [ ] Linux (`bin/`, `install.sh`, `tests/`, `docs/*.py`)
- [ ] macOS (`mac/`, and the Darwin branches in `bin/` and `install.sh`)
- [ ] Windows (`win/`)
- [ ] More than one
- [ ] Documentation or assets only

## How tested

<!-- Which machine and desktop did you exercise this on? Recording, Bluetooth,
     injection, the overlay, the input hook, task registration, the event tap,
     the pill and the macOS permissions are not covered by any test suite, so
     say so explicitly if you touched them. -->

## Checklist

Run the list for each platform you ticked — see `CONTRIBUTING.md`. A change to
the shared bash core (`bin/`) is a Linux and a macOS change.

**Linux**

- [ ] Syntax check passes (`bash -n` / `py_compile`, dispatched by shebang)
- [ ] `shellcheck` is clean over the shell scripts
- [ ] `bats tests/` passes

**macOS**

- [ ] `bash -n` and `shellcheck` are clean over `mac/install.sh` and `mac/sayit-doctor`
- [ ] The three Swift targets build with `swiftc` as `mac/install.sh` builds them
- [ ] `mac/tests/run.sh` and `bats tests/mac.bats` pass
- [ ] `python3 docs/check-geometry.py` passes

**Windows**

- [ ] Every `win\*.ps1` parses
- [ ] The C# helpers compile with `Add-Type`
- [ ] `Invoke-ScriptAnalyzer -Path win -Recurse -Severity Error` is clean
- [ ] `.\win\tests\Invoke-Tests.ps1` passes

**Every platform**

- [ ] Documentation updated if behaviour or flags changed — the relevant
      document under `docs/`, and the script's own header comment
- [ ] A new setting has all three: a default in `.env.example`, a row in
      `docs/CONFIGURATION.md`, and the code that reads it
