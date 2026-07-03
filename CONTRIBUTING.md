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

- Bash only. Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, and a
  header comment describing usage, arguments and exit codes.
- All code, comments and documentation in English. No emojis.
- Errors go to stderr: `echo "error: ..." >&2; exit 1`.
- Configuration is read from `.env` — new settings get a default there, a row
  in the README table, and an entry in `.env.example`.

## Before opening a PR

1. `shellcheck bin/* install.sh` — must be clean (CI enforces this).
2. `bash -n` on every changed script.
3. `./bin/test-pipeline` still passes.
4. `bats tests/` passes successfully (requires `bats` installed, verified in CI).
5. README, docs/ARCHITECTURE.md, and script header comments are updated if behavior or flags changed.

Keep PRs focused on one change. Describe what changed and why in the
description — reviewers should not have to reverse-engineer intent from the
diff.

## Scope

Deliberate non-goals (PRs for these will be declined): cloud STT backends,
wake-word activation, and GUI frontends. Everything stays local and
terminal-based.
