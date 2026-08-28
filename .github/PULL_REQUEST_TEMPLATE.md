## What

<!-- What does this PR change, and why? -->

## Platform

<!-- Tick one. It decides which checks below apply. -->

- [ ] Linux (`bin/`, `install.sh`, `tests/`, `docs/*.py`)
- [ ] Windows (`win/`)
- [ ] Both
- [ ] Documentation or assets only

## How tested

<!-- Which machine and desktop did you exercise this on? Recording, Bluetooth,
     injection, the overlay, the input hook and task registration are not
     covered by either test suite, so say so explicitly if you touched them. -->

## Checklist

Run the list for the platform you ticked. Neither side needs the other's — see
`CONTRIBUTING.md`.

**Linux**

- [ ] Syntax check passes (`bash -n` / `py_compile`, dispatched by shebang)
- [ ] `shellcheck` is clean over the shell scripts
- [ ] `bats tests/` passes

**Windows**

- [ ] Every `win\*.ps1` parses
- [ ] The C# helpers compile with `Add-Type`
- [ ] `Invoke-ScriptAnalyzer -Path win -Recurse -Severity Error` is clean
- [ ] `.\win\tests\Invoke-Tests.ps1` passes

**Both**

- [ ] Documentation updated if behaviour or flags changed — the relevant
      document under `docs/`, and the script's own header comment
- [ ] A new setting has all three: a default in `.env.example`, a row in
      `docs/CONFIGURATION.md`, and the code that reads it
