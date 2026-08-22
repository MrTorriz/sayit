# Contributing

Thanks for your interest in improving sayit. Bug reports, fixes and focused
features are all welcome.

## Getting started

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh            # builds whisper.cpp, downloads models, creates .env
./bin/test-pipeline     # end-to-end smoke test (no microphone needed)
```

## Code style

- Bash by default. Every shell script: `#!/usr/bin/env bash`, `set -euo pipefail`,
  and a header comment describing usage, arguments and exit codes.
- Another language only where bash genuinely cannot do the job. Today that is
  one file: `bin/sayit-overlay` is Python because the pill is drawn through
  GTK and layer-shell bindings. `bin/sayit-wordlist` shells out to perl for its
  regex engine but is itself a bash script. CI type-checks each file by its
  shebang, so a new Python file is compiled with `py_compile` and a new shell
  file goes through `shellcheck` — neither needs a change to the workflow.
- All code, comments and documentation in English. No emojis.
- Errors go to stderr: `echo "error: ..." >&2; exit 1`.
- Configuration is read from `.env` — new settings get a default there, a row
  in the README table, and an entry in `.env.example`.

## Before opening a PR

1. `shellcheck bin/* install.sh tests/*.sh` — must be clean (CI enforces this).
2. `bash -n` on every changed script.
3. `./bin/test-pipeline` still passes.
4. `bats tests/` passes (requires bats-core >= 1.5; the suite
   relies on `BATS_TEST_TMPDIR` and PATH-stubbed system tools — no microphone,
   clipboard, daemon or Bluetooth device is touched).
5. README, docs/ARCHITECTURE.md, and script header comments are updated if
   behavior or flags changed. A new `.env` setting needs all three: a default
   in `.env.example`, a row in the README's configuration table, and the code
   that reads it.
6. `./bin/sayit doctor` still reports cleanly on your machine — it is read-only
   and catches a recording path broken by the change.

Keep PRs focused on one change. Describe what changed and why in the
description — reviewers should not have to reverse-engineer intent from the
diff.

## Scope

Deliberate non-goals (PRs for these will be declined): cloud STT backends,
wake-word activation, and GUI frontends. Everything stays local and
terminal-based.
