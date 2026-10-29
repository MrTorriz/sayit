# Changelog

## Unreleased

- Rework the README: the logo, highlights, a pipeline diagram, a platform
  overview and measured macOS performance come first, the installation steps
  stay short and link to the full guides.
- Replace the terminal-only demo with one dark, animated illustration of a
  dictation: a text field, the thumb button and the pill, through the meter,
  the transcribing sweep and the paste. `docs/make-demo.swift` draws it with
  Sayit's own `PillView`, so it shows exactly what the app shows.
- Head the README with the SAYIT wordmark and tagline alone
  (`docs/logo-wordmark.svg`, written by `docs/build-logo.py`), without the pill.
  The social preview card shows the same wordmark.
- Add `docs/social-preview.png`, the repository's link card, and
  `docs/make-social-preview.py`, which renders it from the lockup.
- macOS: the pill stays up with a sweep while the transcription runs, and the
  menu bar icon shows an ellipsis.
- macOS: every outcome reaches the menu. A failed start keeps its reason (the
  missing device, the denied permission) instead of being replaced by "No
  recording in progress"; a paste without Accessibility or under Secure Input
  says the text is on the clipboard; a fallback to the cold CLI is announced;
  problems carry a level that turns the icon orange; old outcomes show their
  age.
- macOS: a recording whose recorder ended on its own (`MAX_RECORD_SECONDS`, a
  device that went away) is transcribed straight away, not at the next press.
- macOS: the daemon serves under a random path prefix, readable only by the
  user, so a web page cannot reach `whisper-server`'s `/load`.
- macOS: `mac/install.sh` signs with a local self-signed identity, so rebuilds
  keep the Microphone and Accessibility grants, and resets stale grants when
  the signature's requirement changes.
- macOS: Sayit checks Accessibility every 10 s instead of every second and
  polls once a second when idle, for fewer idle wakeups.
- The dictated text reaches `sayit-inject` on stdin, never in argv.
- Add `AUDIO_CTX_ADAPTIVE` (off by default): the daemon encodes a window sized
  to the clip, in multiples of 256 frames, with a full-window retry when a
  result looks wrong. About 0.3 s faster per dictation on Apple Silicon.
- Document how to give a Logitech button a real mouse-button action in Logi
  Options+; its Back, Forward and gesture presets never reach Sayit.

## 2026-10-28 (v1.0.0)

- Add macOS support. The bash scripts in `bin/` now run on macOS too, with
  Darwin branches for the run directory, process identity, profiling and
  status reporting. `install.sh` installs `cmake` and `bash` from Homebrew,
  builds whisper.cpp with Metal and downloads the large model on Apple Silicon,
  where the scripts prefer it.
- Add `Sayit.app`, a menu bar agent built with `swiftc`: a push-to-talk event
  tap with `auto`, `hold` and `toggle` modes, Escape to cancel and a trigger
  probe; the recording pill in its transient and resident forms; the last
  status in the menu instead of notifications. It runs `bin/sayit` like any
  other trigger.
- Add `sayit-rec` (AVCaptureSession capture with level publishing, a recording
  cap and a silent-capture report) and `sayit-paste` (clipboard and `Cmd+V`
  with the whole previous clipboard restored and nspasteboard.org markers, or
  Unicode typing).
- Add `mac/install.sh`, which builds, signs and installs the app and loads
  LaunchAgents for it and the warm daemon, and `mac/sayit-doctor`, the
  read-only macOS diagnostics behind `./bin/sayit doctor`.
- New settings: `TRIGGER_MODE`, `INDICATOR_RESIDENT` and
  `PASTE_RESTORE_DELAY`. `TRIGGER_BUTTON`, `TRIGGER_SUPPRESS`, `INJECT_METHOD`,
  `MAX_RECORD_SECONDS` and the `INDICATOR_*` settings now also apply on macOS.
- Document installation, configuration, troubleshooting, architecture and the
  security model for macOS.

## 2026-09-17

- Simplify the project overview, put platform setup first and clarify runtime
  resource use, installation requirements and text-injection limits.

- Keep capture compiled in the Windows trigger host, opening the microphone
  on a native thread per press. Signal the waveform only after capture starts,
  and stop capture immediately on release.
- Retain the CLI recording path and native transcription fallback.
- Keep transcription and text delivery loaded in a reusable STA worker. Queue
  completed recordings in order while the input hook continues pumping.
- Verify a full application restart through the existing Windows logon task:
  trigger and fast engine ready after 14.3 seconds, with no diagnostic failures.
  Dictation and automatic startup were also confirmed after a Windows reboot.

- Add optional OpenVINO/Turbo support on Windows with an isolated installer,
  verified model files, engine selection, health checks, rollback and logon
  startup. Keep the original native engine as a local fallback.
- Match the Windows recording indicator to the Linux transient waveform:
  26 bars, no lamp or wordmark, hidden between recordings without losing focus.
  Use a plain black background without an outline on Windows.
- Record a paired Windows HTTP benchmark: 3.906 s to 2.235 s mean across eight
  public Swedish clips; a small sample, not a general accuracy claim.

## 2026-09-15

- Add an optional Linux Whisper large-v3-turbo engine using OpenVINO on Intel
  graphics, with an isolated installer and a checksummed model manifest.
- Add persistent engine selection, startup health checks, dictation locking
  and restoration of the previous configuration if a switch fails.
- Document platform limits, configuration, privacy and a paired Swedish
  benchmark; add protocol, model integrity and service rollback tests.
- Refresh the Linux demo to show the transient waveform used during recording.
- Require the whisper.cpp source directory to be its own Git checkout during
  installation, so an enclosing home-directory repository cannot be mistaken
  for a valid source tree.

- Disable token timestamps on Linux daemon requests, matching the CLI fallback.
  This prevents the server's default line wrapping from splitting words and
  inserting spaces inside them during text normalization.

- Remove the red lamp and wordmark from Linux's transient recording pill.
  Let its voice meter span the available width, while retaining the window
  size and position. Resident and placement windows retain their microphone
  status lamp and wordmark.
