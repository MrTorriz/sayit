# Architecture

sayit is a pipeline of small, single-purpose bash scripts. Each stage can be
run and tested on its own; `bin/sayit` is the orchestrator that wires them
together and manages per-session recording state.

## The pipeline

```mermaid
sequenceDiagram
    autonumber
    participant U as User (button/hotkey)
    participant S as sayit
    participant BT as sayit-bt
    participant R as sayit-record
    participant T as sayit-transcribe
    participant D as whisper-server (daemon)
    participant W as sayit-wordlist
    participant I as sayit-inject

    U->>S: press (sayit start)
    Note over S: claim intent marker (atomic)
    S->>BT: up — switch headset A2DP to HFP mic profile
    S->>R: pw-record, 16 kHz mono WAV (unique per session)
    Note over S: session file: pid + wav + start time
    Note over S: recording indicator shown (mic is live)
    U->>S: release (sayit stop)
    Note over S: claim the session (atomic — one stop wins)
    S->>R: SIGINT, poll until the recorder has exited
    S->>BT: down — restore previous audio profile
    S->>T: WAV file
    T->>D: POST /inference (warm model)
    alt transport failure (daemon down/unreachable)
        T->>T: whisper-cli fallback (cold start)
    end
    T->>W: raw text on stdin
    W-->>T: text with wordlist replacements
    S->>I: final text
    I->>I: save clipboard (text only), wl-copy text, ydotool Shift+Insert, guarded restore
    S->>S: append {time, seconds, words, text} to history.jsonl
```

## Components

| Script | Single responsibility |
|---|---|
| `sayit` | Session state machine: toggle/hold/cancel, atomic session claiming, PID identity checks, notifications, history |
| `sayit-bt` | Bluetooth headset profile switching (A2DP has no mic channel) |
| `sayit-record` | Audio capture only — PipeWire to 16 kHz mono WAV |
| `sayit-daemon` | Starts `whisper-server` from `.env` so the model stays warm in RAM |
| `sayit-transcribe` | Model I/O: daemon first, CLI fallback on transport errors, token cleanup, optional LLM pass |
| `sayit-wordlist` | Pure text transform: stdin to stdout, TSV rules (unit-tested) |
| `sayit-inject` | Text delivery with a fallback chain per compositor, clipboard hygiene |
| `sayit-indicator` | Persistent recording indicator (notification-based, safe fallbacks) |
| `sayit-history` | Read side of `history.jsonl`: listing, stats, re-inject; corrupt-line tolerant |
| `sayit-learn` | Write side of the wordlist: add/undo/list with dedup |

## Runtime state

All transient state lives in `$XDG_RUNTIME_DIR` (RAM-backed tmpfs, wiped at
logout); only history and the wordlist persist.

| Path | Purpose |
|---|---|
| `$XDG_RUNTIME_DIR/sayit.session` | One line: `pid<TAB>wav<TAB>start`. Presence means "recording". Claimed atomically (mv) by stop/cancel, so concurrent invocations cannot double-process a session |
| `$XDG_RUNTIME_DIR/sayit.starting` | Intent marker while `start` is still switching the Bluetooth profile; lets a quick release wait instead of giving up |
| `$XDG_RUNTIME_DIR/sayit-<pid>.wav` | The recording in progress — unique per session, so back-to-back dictations never overwrite each other |
| `$XDG_RUNTIME_DIR/sayit.bt` | Card name + previous audio profile, written by `sayit-bt up`, consumed by `down` (explains the "stuck in phone-quality audio" failure mode) |
| `$XDG_RUNTIME_DIR/sayit.indicator` | Notification ID of the visible recording indicator |
| `$XDG_RUNTIME_DIR/sayit-last-error.log` | Error classes from failed stages (never dictated text) |
| `$XDG_RUNTIME_DIR/sayit-profile.csv` | Per-stage timestamps when `SAYIT_PROFILE=1` (timing data only) |
| `$XDG_DATA_HOME/sayit/history.jsonl` | One JSON object per dictation |
| `$XDG_CONFIG_HOME/sayit/wordlist.tsv` | User vocabulary, grown by `sayit-learn` |

PIDs read back from state files are trusted only after an identity check:
the process's command line must name the session's own (unique) WAV path,
so a recycled PID — even another recorder — is never signalled.

## Performance and latency

Measured with `tests/benchmark.sh` on the reference machine — Intel Core
Ultra 9 185H, Intel Arc iGPU (Vulkan), Fedora 44, `kb-whisper-medium` q5_0
with Silero VAD, 2026-08-20. The harness times `sayit-transcribe` end to end
(HTTP round trip or CLI, token cleanup, wordlist) against a dedicated
`whisper-server` instance, using synthetic 16 kHz Swedish speech:

| Scenario (audio length)                    |  n | median |   p95 |   max |
| ------------------------------------------ | -: | -----: | ----: | ----: |
| Warm daemon — short sentence (2.2 s)       | 25 | 1.62 s | 1.64 s | 1.64 s |
| Warm daemon — medium (8.7 s)               | 25 | 3.12 s | 3.28 s | 3.41 s |
| Warm daemon — long (20.8 s)                | 25 | 6.41 s | 6.67 s | 6.74 s |
| Warm daemon — silence (2.0 s)              | 10 | 0.06 s | 0.09 s | 0.09 s |
| Cold `whisper-cli` fallback — short        | 10 | 2.65 s | 2.71 s | 2.71 s |
| Cold `whisper-cli` fallback — medium       | 10 | 4.27 s | 4.37 s | 4.37 s |
| Daemon model load (service start)          |  1 | 0.95 s |     — |     — |
| Wedged server (SIGSTOP), incl. fallback    |  3 | 14.8 s |     — | 14.9 s |

Notes:

- **Warm vs cold**: the daemon removes the per-call model load entirely; the
  cold rows show the true cost of the `whisper-cli` fallback path.
- **Silence is cheap**: an empty transcription from a healthy daemon is
  accepted as authoritative — it never triggers a redundant cold re-run.
- **Deadline**: the daemon request times out after `audio seconds + 10 s`
  (with a 2 s connect timeout), so a wedged server cannot stall a short
  dictation for long; the request then falls back to the CLI.
- **Not covered by the harness**: microphone capture and the Bluetooth
  profile switch. On a BT headset, the A2DP→HFP switch happens synchronously
  at press time and takes roughly 0.5–2.5 s before capture starts (estimate,
  unmeasured) — the recording indicator appears when the mic is actually
  live. Clipboard injection adds on the order of 0.1 s after transcription.
- Per-stage timings of real dictations: run with `SAYIT_PROFILE=1` and read
  `$XDG_RUNTIME_DIR/sayit-profile.csv` (run id, wall clock, monotonic uptime,
  stage, numeric extra — never text).

## Design decisions

### Clipboard injection instead of synthetic typing

Typing tools (`ydotool type`) send US-layout keycodes: any non-ASCII character
— `å`, `ä`, `ö`, and even `?` on some layouts — is dropped or wrong. sayit
instead puts the text on the clipboard with `wl-copy` and sends a single
Shift+Insert. That is exact for every language and toolkit. Clipboard hygiene
rules: only a plain-text clipboard is saved and restored (~1 s after pasting,
and only if the clipboard still holds the dictation — a copy the user made in
the meantime is never overwritten); non-text clipboards and clipboards tagged
with a password-manager hint are never read or re-offered; the primary
selection is cleared after the paste window. On compositors where native
typing works, `wtype` (wlroots) and `xdotool` (X11 sessions only) remain as
fallbacks — KWin/Plasma notably does not expose the virtual-keyboard
protocol, which is why the clipboard path is the default.

### Per-session state with atomic claiming

Hold-to-talk generates racy event pairs: a release can arrive while start is
still switching the Bluetooth profile, buttons bounce, and users re-press
while the previous dictation is still transcribing. Every recording therefore
gets a unique WAV and a single session file written atomically; stop/cancel
*claim* the session with an atomic rename, so exactly one consumer wins.
An intent marker covers the pre-session window (a quick release waits for it
instead of giving up), stopping polls until the recorder has actually exited
(so the WAV header is finalized before it is read), and every signal is
preceded by a process-identity check. A start that cannot spawn its recorder
cleans up, restores the audio profile and reports — it never leaves state
behind.

### Warm daemon with cold-start fallback

whisper.cpp spends noticeable time per invocation just loading the model. The
systemd user service keeps a `whisper-server` running so that cost disappears
(see the measured table above). `sayit-transcribe` tries the server first and
falls back to `whisper-cli` **only on transport failures** — an empty answer
from a healthy daemon means "no speech" and is final. The daemon is optional;
but note the inverse dependency too: `whisper-cli` and the local model file
are only required when the fallback actually runs.

### Bluetooth profile juggling

A2DP (the high-quality playback profile) has no microphone channel, so a
Bluetooth headset is silent as an input device until it is switched to its
headset profile (HSP/HFP, mSBC 16 kHz). `sayit-bt` does this switch on record
start and restores the previous profile on stop. The switch is synchronous —
capture begins only after the mic is live, which is why the recording
indicator (rather than the button press) is the "start speaking" cue.
Playback quality dips for exactly the duration of the recording. The headset
is discovered from the default output at runtime, so nothing is hardcoded.

### VAD plus token suppression

Whisper hallucinates on silence — ghost sentences, repeated phrases, `[music]`
markers. Two layers remove that: Silero VAD filters non-speech audio before
the model sees it, and `-sns` (suppress non-speech tokens) removes bracketed
noise tokens at decode time.

### Sequential wordlist, longest rule first

Wordlist rules are applied one substitution per rule, sorted by original
length descending, so a multi-word rule ("get hub" -> "GitHub") always beats a
substring rule ("hub" -> ...), regardless of file order. Matching is
case-insensitive on word boundaries and UTF-8 aware — `på` never matches
inside `påse`. Rules are literal strings, not regexes, so `sayit-learn`
input can never break the pipeline. Because rules run sequentially, a
replacement can itself be matched by a later, shorter rule — keep originals
specific. See `tests/wordlist.bats` for the exact contract.

### A recording indicator that can never break recording

The indicator is a persistent desktop notification (`notify-send --print-id`,
closed via the standard Notifications D-Bus interface). It appears only once
the microphone is actually capturing — not during the Bluetooth switch — and
is removed on stop, cancel and every failure path. Missing tools or an old
libnotify degrade it to a transient notification or a no-op; it never takes
focus, never blocks injection, and can be disabled with
`RECORDING_INDICATOR=0`.

### Deliberate non-goals

- **No cloud STT** — the value proposition is that audio never leaves the
  machine.
- **No wake word** — push-to-talk is more reliable, more private, and costs
  zero CPU when idle.
- **No GUI** — everything is scriptable and composable; notifications are the
  only UI.
