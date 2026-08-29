[← README](../README.md) · [Install: Linux](INSTALL-LINUX.md) · [Windows](INSTALL-WINDOWS.md) · **Configuration** · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md) · [Architecture](ARCHITECTURE.md)

# Configuration

Everything lives in `.env`, created from [`.env.example`](../.env.example) by
whichever installer you ran. Both platforms read the same file; a setting that
exists on only one of them is ignored by the other.

- [Settings](#settings)
- [When a change takes effect](#when-a-change-takes-effect)
- [Environment overrides that are not in .env](#environment-overrides-that-are-not-in-env)
- [Accuracy: VAD, beam search, initial prompt, suppression](#accuracy-vad-beam-search-initial-prompt-suppression)
- [Choosing a model size](#choosing-a-model-size)
- [Custom wordlist](#custom-wordlist)
- [How .env is read](#how-env-is-read)

## Settings

The Default column is the value the code falls back to when the setting is
absent or empty — not the literal text in `.env.example`, which leaves several
of them empty on purpose so the code can resolve a repo-relative path.

| Variable | Default | Platform | Purpose |
| --- | --- | --- | --- |
| `MODEL_PATH` | `models/ggml-kb-whisper-medium-q5_0.bin` | both | GGML model file. Empty resolves to the repo default |
| `WHISPER_CLI` | Linux path in the template | both | `whisper-cli` binary. `win\install.ps1` rewrites it to the build it produced when it creates `.env` |
| `WHISPER_SERVER` | Linux path in the template | both | `whisper-server` binary. Same rewrite as above |
| `SPEECH_LANGUAGE` | `sv` | both | ISO 639-1 language code passed to whisper |
| `AUDIO_SOURCE` | empty | both | Recording device. Linux: a PipeWire node name; empty means the headset mic, else the PipeWire default. Windows: the MMDevice endpoint ID when the driver reports one, otherwise the device name; empty means the Windows default capture device |
| `THREADS` | `8` on Linux, `6` on Windows | both | CPU threads for whisper.cpp, passed to both the daemon at start and the CLI fallback. The two platforms genuinely differ in default |
| `BEAM` | `5` | both | Beam search size; `-1` is greedy |
| `VAD_MODEL` | `models/ggml-silero-v5.1.2.bin` | both | Silero VAD. Point it at a missing file to disable VAD |
| `VAD_SPEECH_PAD_MS` | `250` | both | Audio kept after the detected end of speech, in ms. The only one of the four that lengthens the tail |
| `VAD_THRESHOLD` | `0.30` | both | Speech probability above which Silero calls a 32 ms frame speech. whisper.cpp's own default is `0.5` |
| `VAD_MIN_SPEECH_MS` | `0` | both | Segments shorter than this are discarded. `0` discards nothing |
| `VAD_MIN_SILENCE_MS` | `300` | both | Silence needed before a segment is closed. Does **not** lengthen the tail, however high it is set |
| `INITIAL_PROMPT` | empty | both | One short natural sentence of context, not a term list. See [Accuracy](#accuracy-vad-beam-search-initial-prompt-suppression) |
| `SUPPRESS_REGEX` | empty | both | Regex for stubborn hallucinated phrases. Never passed to `whisper-server` on Windows, which has no such option |
| `DAEMON_PORT` | `9876` | both | Port for the warm whisper-server, on `127.0.0.1` |
| `TYPING_WPM` | `40` | both | Assumed typing speed for the time-saved statistic |
| `WORDLIST` | platform default | both | Replacement wordlist. `~/.config/sayit/wordlist.tsv` on Linux, `%APPDATA%\sayit\wordlist.tsv` on Windows |
| `RECORDING_INDICATOR` | `1` | both | Linux: the persistent notification. Windows: the on-screen pill. `0` turns it off |
| `LLM_CLEANUP` | `0` | Linux | `1` runs an LLM cleanup pass after transcription. **It sends the transcribed text to `LLM_URL`** |
| `LLM_URL` | `http://127.0.0.1:11434/api/generate` | Linux | Endpoint for that pass. Loopback keeps the text on the machine; any other host does not |
| `LLM_MODEL` | `gemma2:2b` | Linux | Model name passed to that endpoint |
| `RECORDING_METER` | `1` | Linux | Live microphone meter; `0` turns it off |
| `RECORDING_METER_STYLE` | `overlay` | Linux | `overlay` is sayit's own pill, `mark` the animated mark in the Plasma OSD, `wave` a waveform in the same OSD |
| `TRIGGER_BUTTON` | `XBUTTON2` | Windows | Push-to-talk button: `XBUTTON1`, `XBUTTON2`, `MIDDLE`, or `VK` plus a virtual-key code such as `VK124` for F13 |
| `TRIGGER_SUPPRESS` | `1` | Windows | Swallow the trigger so the focused application never sees it; `0` lets it through |
| `INJECT_METHOD` | `auto` | Windows | `auto` types short text and pastes longer text; `type` always types; `clipboard` always pastes |
| `INJECT_CLIPBOARD_THRESHOLD` | `100` | Windows | Length in characters above which `auto` switches from typing to pasting |
| `MAX_RECORD_SECONDS` | `120` | Windows | Hard cap on a single recording |
| `INDICATOR_SCALE` | `1.0` | Windows | Starting size of the on-screen pill; `1.0` is 160x40 px. Values outside `0.5`-`4.0` fall back to `1.0`. A size dragged out on screen is saved and takes precedence over this |
| `INDICATOR_LOCKED` | `0` | Windows | `0` lets you drag the pill to move it and drag either end to resize it, saving where you leave it; the pill then catches clicks on its own area. `1` makes it click-through and immovable, placeable only with `.\win\sayit-indicator.ps1 place`. It never takes focus either way |
| `INDICATOR_EXCLUDE_FROM_CAPTURE` | `1` | Windows | Keep the pill out of screen captures and screen shares. Needs Windows 10 2004 or later; older builds capture it anyway |

The five Linux-only settings sit above the Windows section in
`.env.example` because they were there first, not because Windows reads them.
No file under `win\` reads `LLM_CLEANUP`, `LLM_URL`, `LLM_MODEL`,
`RECORDING_METER` or `RECORDING_METER_STYLE`.

## When a change takes effect

| Setting | Effect |
| --- | --- |
| `SPEECH_LANGUAGE`, `INITIAL_PROMPT`, the four `VAD_*` tuning settings | Next dictation. They are sent with each request |
| `THREADS`, `BEAM`, `VAD_MODEL` | Immediately for the CLI fallback, but fixed at server start for the daemon — restart it |
| `MODEL_PATH`, `DAEMON_PORT` | Immediately for the CLI fallback and for which port the client dials, but fixed at server start for the daemon — restart it |
| `WHISPER_SERVER` | Restart the daemon |
| Everything else | Next invocation of the command that reads it |

Restarting the daemon:

```bash
systemctl --user restart sayit-daemon.service      # Linux
```

```powershell
.\win\sayit-daemon.ps1 stop; .\win\sayit-daemon.ps1 start
```

`SUPPRESS_REGEX` is the one setting whose handling differs per platform. On
Linux it always applies to the CLI fallback, and it is forwarded to the daemon
only when the installed `whisper-server` build supports the flag. On Windows
it is never passed to the server at all — that binary has no
`--suppress-regex` option, and answers an unknown option by printing its usage
and exiting with status 0, so passing one made the warm daemon quit at startup
while looking like a clean shutdown. It is applied to the text of whichever
path served the dictation instead.

## Environment overrides that are not in .env

These are read from the environment, never from `.env`. They exist for
development and diagnostics.

| Variable | Read by | Effect |
| --- | --- | --- |
| `SAYIT_MODEL` | `bin/sayit-daemon`, `bin/sayit-transcribe` | Overrides `MODEL_PATH` for one invocation. For the daemon: `systemctl --user set-environment SAYIT_MODEL=...` |
| `SAYIT_PROFILE` | both platforms | `1` writes per-stage timings to `sayit-profile.csv` in the run directory. Run id, timestamps and stage names only — never dictated text |
| `SAYIT_PROFILE_RUN` | both platforms | Run id written into that CSV |
| `YDOTOOL_SOCKET` | `bin/sayit-inject` | Path to the ydotool socket. Defaults to `/run/.ydotool_socket` |
| `WHISPER_REF` | `install.sh` | Tag or commit to build instead of the pinned release |
| `SAYIT_KEEP_CONSOLE` | `win\sayit-autostart.ps1` | `1` keeps the supervisor's console window visible |
| `BENCH_MODEL`, `BENCH_VAD`, `BENCH_PORT`, `BENCH_DIR`, `BENCH_REPS`, `BENCH_STALL` | `tests/benchmark.sh` | See [Performance](PERFORMANCE.md#reproducing-the-linux-numbers) |

## Accuracy: VAD, beam search, initial prompt, suppression

Several settings raise quality, and all of them are on by default.

**VAD (`VAD_MODEL`)** — Silero Voice Activity Detection filters out non-speech
before the model sees the audio. Whisper hallucinates on silence — ghost text,
repeated phrases — and VAD removes that risk at the edges of every recording.

Four further settings decide where it cuts, and only one of them does what
people expect. `VAD_SPEECH_PAD_MS` is the only setting that lengthens the tail
of a phrase: whisper.cpp ends a segment at the first 32 ms frame whose speech
probability falls below `VAD_THRESHOLD` minus 0.15, and adds back only that
padding. Swedish unvoiced finals (-t, -s, -st, -rt) run 80-150 ms and score
low, which is why whisper.cpp's own default of 30 clips them off.
`VAD_MIN_SILENCE_MS` does not extend the tail however high it is set.
`VAD_MIN_SPEECH_MS` is a correctness setting rather than a quality one:
anything shorter is discarded, and when every segment is discarded the
transcription still succeeds — with an empty result and no error, so a
one-word answer can vanish without a trace. That is why sayit defaults it to
`0` where whisper.cpp defaults to 250.

**Beam search (`BEAM`)** — `5` decodes more accurately than greedy (`-1`).

**Suppress non-speech** — the daemon and the CLI always suppress non-speech
tokens (`[music]`, brackets, noise). An optional `SUPPRESS_REGEX` additionally
removes specific recurring junk strings; see the note above for how it is
applied per platform. On Windows a regex that does not compile is recorded as
an error and ignored, so it never costs you the dictation. On Linux the value
is handed to `whisper-cli` and `whisper-server` unvalidated, and how a bad
pattern fails is up to them.

**Initial prompt (`INITIAL_PROMPT`)** — empty by default, and a term list is
the wrong thing to put in it. Whisper treats the slot as the transcript of the
preceding segment, not as a vocabulary. Measured across 11 datasets,
biasing-word prompts cut rare-word errors from 23.7% to 18.0% but made overall
word error rate **worse** on 6 of the 11, and worse still as the list grew
from 35 to 70 to 150 words ([arXiv:2502.11572](https://arxiv.org/abs/2502.11572)).
A dictation is a handful of words, so a long prompt leaves the decoder holding
far more prior text than audio — the regime where the model is reported to
emit the prompt itself as the transcript.

If you use it, use one short natural sentence in your dictation language,
around 25 tokens, carrying a few domain nouns in context, and leave rare-term
correction to the wordlist, which is deterministic. Two hard limits from
whisper.cpp: the prompt is truncated to 224 tokens (`n_text_ctx / 2`) from the
tail, and a `max_context` of 0 disables the initial prompt entirely — the two
sit behind the same guard.

**Flash attention** — always on; it speeds up inference on GPU.

**LLM cleanup (`LLM_CLEANUP=1`, Linux only)** — fixes spelling, split words and
obvious errors with context. It POSTs the transcribed text to `LLM_URL`, which
defaults to a local Ollama; that is the only configuration in which the text
stays on your machine. Worth the latency only with a GPU-accelerated Ollama:
on CPU it is too slow (~15 s) and a small model can make technical terms
worse, so it is off by default. See [SECURITY.md](../SECURITY.md) before
pointing `LLM_URL` anywhere else.

## Choosing a model size

WER (lower is better) from
[KBLab's benchmarks](https://huggingface.co/KBLab/kb-whisper-medium) for
Swedish, compared with OpenAI whisper-large-v3:

| Size | File (q5_0) | RAM | Speed | WER (FLEURS / CommonVoice / NST) |
| --- | --- | --- | --- | --- |
| `kb-whisper-small` | 175 MB | low | fastest | 7.3 / 6.4 / 6.6 |
| `kb-whisper-medium` (default) | 539 MB | medium | fast | 6.6 / 5.4 / 5.8 |
| `kb-whisper-large` | 1.1 GB | high | slower | **5.4 / 4.1 / 5.2** |
| OpenAI whisper-large-v3 | — | high | slower | 7.8 / 9.5 / 11.3 |

`large` makes roughly 10-24% fewer errors than `medium` depending on the test
set, mean around 18%. What it costs in latency **has not been measured**, and
by architecture it should be a real cost rather than a rounding error: `large`
runs 32 layers at 1280 state against `medium`'s 24 at 1024, roughly 2.1x the
encoder compute, and an integrated GPU sharing system memory is bandwidth
bound, which lands near the same ratio. Treat that figure as arithmetic, not
as a benchmark, and time it on your own machine before switching.

Switching, on Linux:

```bash
./install.sh --model large     # or small
# point MODEL_PATH in .env at the new file, then:
systemctl --user restart sayit-daemon.service
```

On Windows, put the model file in `models\` yourself, point `MODEL_PATH` at it
and restart the daemon.

For languages other than Swedish, download any GGML Whisper model — for
example from [ggml-org](https://huggingface.co/ggerganov/whisper.cpp) — then
set `MODEL_PATH` and `SPEECH_LANGUAGE`.

## Custom wordlist

Fix recurring mistranscriptions with a TSV of replacements. The file, the
format and the matching rules are identical on both platforms; only the path
differs (`~/.config/sayit/wordlist.tsv` on Linux,
`%APPDATA%\sayit\wordlist.tsv` on Windows, or `WORDLIST` in `.env`).

```text
get hub	GitHub
docker komposse	docker-compose
```

Format is `original<TAB>replacement`. The rules:

- Applied after transcription, case-insensitively, on word boundaries.
- Longer originals are tried first, so a multi-word rule wins over a substring
  regardless of line order.
- Applied sequentially, so a replacement can itself be matched by a later,
  shorter rule.
- Originals are literal strings, never regexes.
- Lines starting with `#` are comments; blank lines are ignored.

Faster than editing the file: teach sayit directly from a mistake. The list is
deduplicated as it grows.

```bash
./bin/sayit-learn "gitting nore" "gitignore"   # add
./bin/sayit-learn --list                       # show all
./bin/sayit-learn --undo "gitting nore"        # remove
```

```powershell
.\win\sayit-learn.ps1 "gitting nore" "gitignore"
.\win\sayit-learn.ps1 -List
.\win\sayit-learn.ps1 -Undo "gitting nore"
```

## How .env is read

The two platforms read the same file differently, and the difference matters.

On Linux, `.env` is sourced as shell. `$HOME` and other shell syntax expand,
and a value there runs as code — including when `bin/sayit-doctor` reads it.

On Windows, `.env` is parsed as plain `KEY=VALUE` data and never executed, so
a value there cannot run as code. `%VAR%` is expanded in values; `$HOME` is
not.

Adding a setting takes all three: a default in `.env.example`, a row in the
table above, and the code that reads it. See
[CONTRIBUTING.md](../CONTRIBUTING.md).
