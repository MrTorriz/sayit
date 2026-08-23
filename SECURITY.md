# Security Policy

## Supported versions

sayit is distributed as a rolling `main` branch. Only the latest commit on
`main` is supported; please reproduce issues there before reporting.

## Reporting a vulnerability

Please report security issues privately through GitHub's private vulnerability
reporting: the repository's [Security tab](https://github.com/MrTorriz/sayit/security)
→ "Report a vulnerability". If that button is not available, open a minimal
public issue asking for a private contact channel — do not include exploit
details in the issue.

## Security model, in brief

- All speech recognition runs locally, always. Audio never leaves the machine,
  and sayit has no telemetry and no account.
- **One optional feature sends text off the process**: with `LLM_CLEANUP=1`,
  the transcribed text is POSTed to `LLM_URL` for a post-transcription cleanup
  pass. It is off by default and `LLM_URL` defaults to a local Ollama on
  `127.0.0.1`, so nothing leaves the machine unless you point `LLM_URL`
  somewhere else — which the setting lets you do. Treat any non-loopback
  `LLM_URL` as sending your dictated text to that host in plain HTTP.
- The optional warm daemon (`whisper-server`) listens on `127.0.0.1` only and
  has no authentication — any local process can reach it. Do not bind it to a
  non-loopback address.
- `install.sh` builds whisper.cpp from a pinned upstream release and verifies
  model downloads against pinned sha256 checksums.
- Text injection uses `ydotoold` (uinput). Its socket grants any process of
  your user system-wide synthetic input — an inherent property of that
  approach on KWin/Wayland, documented in the README.
- Dictated text is stored in plain text in
  `~/.local/share/sayit/history.jsonl`, and transits the clipboard during
  injection (clipboard managers may record it). See the README's privacy
  section for details and cleanup commands.
