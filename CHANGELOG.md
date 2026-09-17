# Changelog

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
