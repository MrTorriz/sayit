# Changelog

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
