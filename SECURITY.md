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

### All platforms

- All speech recognition runs locally, always. Audio never leaves the machine,
  and sayit has no telemetry and no account.
- **One optional feature sends text off the machine**: with `LLM_CLEANUP=1`
  (Linux and macOS, which share the transcriber), the transcribed text is
  POSTed to `LLM_URL` for a
  post-transcription cleanup pass. It is off by default and `LLM_URL` defaults
  to a local Ollama on `127.0.0.1`, so nothing leaves the machine unless you
  point `LLM_URL` somewhere else — which the setting lets you do. Treat any
  non-loopback `LLM_URL` as sending your dictated text to that host in plain
  HTTP. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md#settings).
- The optional warm daemon (`whisper-server` or OpenVINO) listens on `127.0.0.1` only and
  has no authentication — any local process can reach it. Do not bind it to a
  non-loopback address.
- **Daemon logs are `whisper-server`'s own output and can contain transcribed
  text.** Never paste them into a public issue.
- **The doctor output is the safer artefact, but it is not sanitised.** No
  doctor dumps `.env`, the wordlist or any dictated text, and none prints the
  *values* of `INITIAL_PROMPT` or `SUPPRESS_REGEX` — only whether they are set,
  because both hold text you wrote. All of them print resolved local paths,
  capture device names and endpoint IDs, and most other setting values. On
  Windows and macOS those paths normally contain your user name. Read the output
  and mask what you do not want published.
- Every installer builds whisper.cpp from a pinned upstream release.
  `install.sh`, on Linux and macOS, additionally verifies model downloads
  against pinned sha256 checksums; `win\install.ps1` prints the sha256 of the
  models you supplied so you can check them yourself.
- Dictated text is stored in plain text in `history.jsonl` and kept until you
  clear it. See the history sections in the
  [Linux guide](docs/INSTALL-LINUX.md#history-and-statistics) and
  [Windows guide](docs/INSTALL-WINDOWS.md#history-and-statistics) for usage,
  and [runtime state](docs/ARCHITECTURE.md#runtime-state) for storage paths.
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

### macOS

- `.env` is **sourced as shell** by the bash scripts, exactly as on Linux, so a
  value in it executes as code — including when the doctor reads it.
  `Sayit.app` reads its own settings from the same file as plain data and
  executes nothing.
- **`Sayit.app`'s permissions extend to the repository.** Microphone and
  Accessibility are granted to the app, and everything it starts runs under
  them: the repository's `bin/sayit`, the scripts that calls, and the `.env`
  they source. Whoever can write to your clone can therefore run code that
  records and sends keystrokes. Keep the repository writable by you alone.
- Transient state lives in the per-user temporary directory
  (`getconf DARWIN_USER_TEMP_DIR`), mode 0700 and private to your user.
  Unlike Linux's tmpfs it is **on disk** and is not wiped at logout. The WAV is
  created mode 0600 and deleted right after transcription; one that a crash
  leaves behind is swept at the next recording once it is an hour old.
  `sayit-last-error.log`, `sayit.status` and `sayit.agent` live in the same
  directory and hold no dictated text.
- Dictated text transits the clipboard on every injection, unless
  `INJECT_METHOD=type`. It is marked `org.nspasteboard.TransientType` and
  `org.nspasteboard.AutoGeneratedType`, so clipboard managers that follow the
  nspasteboard.org conventions leave it out of their history. The previous
  clipboard — every item and every type — is restored after
  `PASTE_RESTORE_DELAY` (1 s), and only if you have not copied something new
  meanwhile. A clipboard a password manager marked
  `org.nspasteboard.ConcealedType` or `TransientType` is never read, saved or
  re-offered, so the dictation stays on the clipboard instead; it also stays
  when Accessibility is missing, when Secure Input is on, and when the old
  clipboard is larger than 64 MiB.
- `sayit-paste` writes the dictation as current-host-only clipboard contents,
  so Handoff's Universal Clipboard does not offer it to your other Apple
  devices. A clipboard it restores afterwards is written back normally.
  `sayit-history --copy` uses `pbcopy`, which has neither this nor the
  markers above.
- **There are no notifications on macOS**, so Notification Center holds no copy
  of anything. The menu bar item shows the last status, and a `Done` status
  carries the word count without the text.
- `Sayit.app` holds an active, session-wide event tap. It observes key and
  extra mouse-button transitions in order to detect one of them, swallows that
  one with `TRIGGER_SUPPRESS=1` — and Escape when it cancels a recording — and
  forwards everything else untouched. In its normal mode it stores nothing.
  While Secure Input is on, keyboard events never reach it.
- **Probe Trigger writes what it sees** to `trigger-probe.log` in the run
  directory: every mouse button and modifier, and the codes only of keys that
  type no character or are pressed with `Cmd` or `Ctrl`. Every other key is
  logged as "a typing key", so the log holds no text, but it does record when
  you typed. It stays until you delete it. `Sayit --probe` in a terminal prints
  the same lines and writes no file.
- Logs live in `~/Library/Logs/sayit/`. `daemon.log` is `whisper-server`'s
  output; sayit starts the server without `--print-realtime`, so the file holds
  request and timing lines rather than transcribed text, but treat it as the
  rule above says and do not publish it. It is moved to `daemon.log.1` once it
  passes 1 MiB, when the daemon next starts. `agent.log` holds error messages
  from Sayit and the commands it starts.
- Nothing requires administrator rights. `Sayit.app` goes into
  `/Applications` when your account can write there, and into
  `~/Applications` otherwise; apart from that and Homebrew's formulae,
  everything installs into your home directory: two per-user LaunchAgents and
  `~/.local`. The app is signed ad hoc unless
  `SAYIT_SIGN_IDENTITY` names an identity of yours; macOS ties both permissions
  to that signature.

## Optional OpenVINO engine

The adapter binds only to `127.0.0.1`. Audio is decoded in memory and neither
transcripts nor prompts are logged by the adapter. Error responses contain
error classes only. The client's history, clipboard and optional cleanup
behavior above still apply, including native daemon/CLI logging on fallback.
The launcher disables the OpenVINO package's telemetry through `CI=true` and
uses an isolated Python environment. No model download occurs during dictation.

`install-openvino.sh` and `win/install-openvino.ps1` download Python packages
from PyPI and model files from
Hugging Face. Versions are pinned in `engines/openvino/requirements.txt`; the
model manifest pins a repository revision, size and SHA-256 for every file.
Existing or locally copied model files are checked too. Python packages are
version-pinned, not hash-locked. The loopback endpoint has no authentication;
other processes running on the same machine can use it.
