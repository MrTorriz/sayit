# Security Policy

## Supported versions

sayit is distributed as a rolling `main` branch. Only the latest commit on
`main` is supported; please reproduce issues there before reporting.

## Reporting a vulnerability

Please report security issues privately through GitHub's private vulnerability
reporting: the repository's [Security tab](https://github.com/MrTorriz/sayit/security)
then "Report a vulnerability". If that button is not available, open a minimal
public issue asking for a private contact channel — do not include exploit
details in the issue.

## Security model, in brief

### Both platforms

- All speech recognition runs locally, always. Audio never leaves the machine,
  and sayit has no telemetry and no account.
- **One optional feature sends text off the machine**: with `LLM_CLEANUP=1`
  (Linux only), the transcribed text is POSTed to `LLM_URL` for a
  post-transcription cleanup pass. It is off by default and `LLM_URL` defaults
  to a local Ollama on `127.0.0.1`, so nothing leaves the machine unless you
  point `LLM_URL` somewhere else — which the setting lets you do. Treat any
  non-loopback `LLM_URL` as sending your dictated text to that host in plain
  HTTP. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md#settings).
- The optional warm daemon (`whisper-server`) listens on `127.0.0.1` only and
  has no authentication — any local process can reach it. Do not bind it to a
  non-loopback address.
- **Daemon logs are `whisper-server`'s own output and can contain transcribed
  text.** Never paste them into a public issue.
- **The doctor output is the safer artefact, but it is not sanitised.** Neither
  doctor dumps `.env`, the wordlist or any dictated text, and neither prints the
  *values* of `INITIAL_PROMPT` or `SUPPRESS_REGEX` — only whether they are set,
  because both hold text you wrote. Both do print resolved local paths, capture
  device names and endpoint IDs, and most other setting values. On Windows those
  paths normally contain your user name. Read the output and mask what you do
  not want published.
- Both installers build whisper.cpp from a pinned upstream release. `install.sh`
  additionally verifies model downloads against pinned sha256 checksums;
  `win\install.ps1` prints the sha256 of the models you supplied so you can
  check them yourself.
- Dictated text is stored in plain text in `history.jsonl` and kept until you
  clear it. See the [README's privacy section](README.md#privacy) for the paths
  and the cleanup commands.
- Diagnostics record error *classes* only — never dictated text, never audio.
  Profiling records stage names and timings, never text.

### Linux

- `.env` is **sourced as shell**, so a value in it executes as code. That
  includes when `bin/sayit-doctor` reads it. Treat `.env` as executable
  configuration.
- Text injection uses `ydotoold` (uinput). Its socket grants any process of
  your user system-wide synthetic input — an inherent property of that approach
  on KWin/Wayland, documented in
  [docs/INSTALL-LINUX.md](docs/INSTALL-LINUX.md#text-injection-on-kwinwayland-ydotool).
- Dictated text transits the clipboard on every injection, so clipboard
  managers may record it. The previous clipboard is restored about a second
  later, and only if you have not copied something new meanwhile. The primary
  selection is cleared after the paste window, so a dictation is not
  middle-click pastable indefinitely. A non-text clipboard, or one tagged by a
  password manager with `x-kde-passwordManagerHint`, is never read, saved or
  re-offered — restoring one stripped of its hint would strip its protection
  with it.
- Notifications quote the first 60 characters of a dictation and are sent
  `--transient`, so a compliant notification server does not retain them.
- Transient audio lives in `$XDG_RUNTIME_DIR`, a RAM-backed tmpfs that does not
  survive a reboot, and is deleted right after transcription. So does
  `sayit-last-error.log`.

### Windows

- `.env` is **parsed as plain `KEY=VALUE` data and never executed**, a
  deliberate divergence from the Linux side. `%VAR%` is expanded in values;
  shell syntax is not.
- Text injection uses `SendInput`, so the clipboard is involved only above
  `INJECT_CLIPBOARD_THRESHOLD` or when typing is impossible. When it is used,
  the text is marked `ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory=0` and `CanUploadToCloudClipboard=0`, so a
  dictation stays out of Win+V history and out of cloud sync. The previous
  clipboard contents are not restored.
- **Injection into a higher-integrity window is impossible and fails
  silently at the OS level.** sayit detects the case before injecting, leaves
  the text on the clipboard and says so, rather than appearing to succeed.
- Transient audio lives in `%LOCALAPPDATA%\sayit\run`, which is **on disk** —
  Windows has no tmpfs equivalent. It is deleted after transcription, and WAV
  files older than an hour are swept when the next recording starts, but a
  crash can leave one behind until then. `sayit-doctor.ps1` reports any that
  are left. `sayit-last-error.log` in the same directory is **not** cleared at
  logout; delete it yourself if you want it gone.
- The trigger holds a global low-level input hook while it runs. It observes
  every key and button transition in order to detect one of them, and with
  `TRIGGER_SUPPRESS=1` it swallows that one. In its normal mode it stores
  nothing and forwards everything else untouched.
- **The two diagnostic probes do write what they observe to disk**, and neither
  cleans up after itself:
  - `win\sayit-trigger.ps1 -Probe` appends every key and button transition it
    sees — including keys you press in other applications while it runs — to
    `%LOCALAPPDATA%\sayit\run\trigger-probe.log`.
  - `win\sayit-rawprobe.ps1` appends device IDs and raw HID bytes to
    `%LOCALAPPDATA%\sayit\run\rawprobe.log`.

  Both files stay after the probe exits and have no retention policy. Delete
  them yourself when you are done, and read them before attaching either to an
  issue.
- Nothing requires administrator rights, and the logon task deliberately runs
  as the logged-in user. An elevated trigger could not type into the
  non-elevated windows you actually work in.
