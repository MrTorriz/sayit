<p align="center">
  <img src="docs/logo-wordmark.svg" alt="SAYIT: don't type it. Say it." width="320">
</p>

<p align="center">
  <b>Local push-to-talk dictation for macOS, Linux and Windows 11.</b><br>
  Hold a button, speak, release. Your words land in whichever text field has focus.
</p>

<p align="center">
  <a href="https://github.com/MrTorriz/sayit/actions/workflows/ci.yml"><img src="https://github.com/MrTorriz/sayit/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="https://github.com/MrTorriz/sayit/releases/latest"><img src="https://img.shields.io/github/v/release/MrTorriz/sayit?label=release&color=da4453" alt="latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
  <a href="#installation"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%2011-informational" alt="platform: macOS, Linux and Windows 11"></a>
</p>

<p align="center">
  <img src="docs/sayit-demo.gif" alt="Demo: the thumb button of a mouse is held, a black pill with a voice wave follows the voice, and after release the sentence lands in a note in one paste; then a Swedish sentence, the Statistics window, the history and the Settings window" width="800">
</p>

Speech is recognised on your own machine by [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
on the GPU through Vulkan or Metal. The default model is
[KB-Whisper](https://huggingface.co/KBLab), the National Library of Sweden's
Swedish Whisper, medium or large on Apple Silicon; any GGML Whisper model and
language can be configured instead. No account, no subscription, no telemetry.

macOS is where sayit is developed most actively: it has a menu bar app with a
Settings window and a Statistics window, and new features land there first.
Linux and Windows 11 remain fully supported for dictation.

## Highlights

- **Private by design.** Audio never leaves the machine. The model server
  listens on `127.0.0.1` only, and after installation recognition works offline.
- **Works where you type.** Terminals, editors, browsers and chat windows. The
  text arrives in one paste, not as a stream of synthetic keystrokes.
- **Ready when you are.** The model stays loaded between dictations while the
  microphone stays closed. On an Apple M6, KB-Whisper large returns a typical
  sentence in about a second.
- **Clear feedback.** A small pill shows a live waveform while the microphone
  is open, and only then. A microphone that hears nothing at all, muted or the
  wrong one, is named in the pill while you still hold the button. All three
  platforms draw it from the same geometry.
- **Learns your vocabulary.** A wordlist fixes recurring mistakes
  (`sayit-learn "get hub" "GitHub"`), and a local history keeps what you
  dictated. On macOS, correct the text where it landed, select it and choose
  **Learn From Selection…**: sayit finds the dictation and proposes the rules.
- **Shortcuts by voice.** Say a snippet's cue, "my signature", and its saved
  text is pasted, line breaks included. Say "frågetecken" or "slash" and get
  `?` or `/` in place. Linux and macOS.
- **See how much you talk.** Words, speaking time, pace against typing, the
  time saved and a year of days at a glance: in a Statistics window on macOS,
  and from `sayit-history --stat` everywhere.
- **A real Mac app.** Settings for everything, in English or Swedish: record
  any mouse button, key or combination as the trigger, add a second one (a
  mouse button and a key, say), give each app its own language and words,
  turn Music and Spotify down while you speak, download models, and choose
  the text size, accent colour and layout.
- **Optional Turbo engine.** On Intel graphics, Linux and Windows can switch to
  Whisper large-v3-turbo on OpenVINO with one command, and back again.

## How it works

<p align="center">
  <img src="docs/pipeline.svg" alt="Hold the trigger and the microphone opens; speak while a live waveform shows; release and the recording is transcribed locally by whisper.cpp or OpenVINO; the wordlist applies your corrections; the text is pasted into the focused window" width="880">
</p>

Every stage is a small program that can be run and tested on its own: bash
scripts on Linux and macOS, PowerShell with compiled C# helpers on Windows,
and three small Swift programs for the parts macOS insists on doing natively.
A warm local server answers each dictation, and a one-shot `whisper-cli` run
takes over if it ever stops responding. The [architecture guide](docs/ARCHITECTURE.md)
covers the design decisions in depth.

## The Mac app

<p align="center">
  <img src="docs/statistics-window.png" alt="The Statistics window with example data: the SAYIT lockup above the words of the last 30 days and the speed of speaking against typing; words per day as bars; a year of days as a red calendar across the window; a row of tiles for the streak, peak hour, best day, words per dictation, time from release to text and the apps you dictate in" width="880">
</p>

**Statistics and History…** in the menu bar opens the Statistics window. Today,
7 days, 30 days or all time: the words and how long they took to say, your
pace against typing, words per hour or day, a year of days as a calendar, how
long the text takes to arrive after release, and where you dictate. It reads
the local history and writes nothing. The pictures show example data.

<p align="center">
  <img src="docs/settings-window.png" alt="Three tabs of the Settings window side by side. General: the trigger with a Record button, the mode Hold or Tap, and a second trigger, right Command. Dictation: microphone, music while recording, model, language, search width, spoken punctuation and the words to expect. Appearance: text size, accent colour, light or dark, glass or solid cards, and the layout of the Statistics window" width="880">
</p>

**Settings…** (⌘,) holds every setting in six tabs: General, Dictation, Text,
Apps, Appearance and Advanced. Changes apply at once; they are written to
`.env`, which stays the one place every setting lives, so editing it by hand
works too.

<p align="center">
  <img src="docs/statistics-history.png" alt="The history with example data: every dictation with its time, words and length, searchable, with a Copy button" width="880">
</p>

## Installation

sayit installs from source: you need a terminal, native build tools and room
for the model files. Each platform has a full guide; the short version follows.

### macOS

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh
./bin/test-pipeline
```

The installer uses Homebrew, builds whisper.cpp with Metal, downloads the
large model on Apple Silicon, builds the `Sayit.app` menu bar agent and loads
its LaunchAgents. Allow Microphone and Accessibility when macOS asks. F18 is
the default trigger: hold it to talk, or tap to start and tap again to stop.
Pick another in **Settings… > General > Record…** by pressing it; **Probe
Trigger** under Advanced shows what any key or mouse button sends. A Logitech
button needs a plain mouse-button action in Logi Options+, which the guide
explains. Requires macOS 14 or later; Apple Silicon is recommended.
**[macOS guide](docs/INSTALL-MACOS.md)**: permissions, triggers, the
indicator, the LaunchAgents and platform limits.

### Linux

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh
./bin/test-pipeline
```

The installer builds whisper.cpp, downloads the models and creates `.env`.
Then set up a trigger: a mouse button through Solaar, or a global shortcut.
KWin/Plasma also needs `ydotoold` for text injection.
**[Linux guide](docs/INSTALL-LINUX.md)**: requirements, triggers, Wayland,
Bluetooth headsets and automatic startup.

### Windows 11

```powershell
git clone https://github.com/MrTorriz/sayit.git
cd sayit
.\win\install.ps1
.\win\sayit-doctor.ps1
```

The installer checks the build tools, builds whisper.cpp and offers to
register a logon task. **Download the two base model files separately**, as
the guide explains. Mouse 5 is the default hold-to-talk button; some mice need
their thumb button mapped in the vendor's utility before Windows can see it.
**[Windows guide](docs/INSTALL-WINDOWS.md)**: prerequisites, model links,
microphone selection, autostart and platform limits.

### Optional Turbo engine

Linux and Windows only. Complete the base installation first, then follow the
[OpenVINO guide](docs/OPENVINO.md): an isolated Python runtime, compatible
hardware, model verification and the way back.

| Platform | Switch to Turbo | Back to whisper.cpp |
| --- | --- | --- |
| Linux | `./bin/sayit-engine fast` | `./bin/sayit-engine accurate` |
| Windows | `.\win\sayit-engine.ps1 fast` | `.\win\sayit-engine.ps1 accurate` |

The choice persists across logins. The names select engines; they do not
promise which one recognises a given sentence best.

## Platform overview

| | macOS | Linux | Windows 11 |
| --- | --- | --- | --- |
| Engine | whisper.cpp, Metal | whisper.cpp, Vulkan | whisper.cpp, Vulkan |
| Default model | KB-Whisper large on Apple Silicon | KB-Whisper medium | KB-Whisper medium |
| Optional Turbo | Not offered; large is fast on Metal | OpenVINO on Intel graphics | OpenVINO on Intel graphics |
| Trigger | F18, or any key, mouse button or combination; a second one too | A mouse button via Solaar, or a global shortcut | Mouse 5, or another button or key |
| Text delivery | `Cmd+V`, previous clipboard restored | `ydotool`, `wtype` or `xdotool` | Typing for short text, paste for long |
| Snippets, spoken punctuation | Yes | Yes | Not yet |
| Settings | Settings window, or `.env` | `.env` | `.env` |
| Per-app language and words | Yes | No | No |
| Statistics | Statistics window, and `sayit-history --stat` | `sayit-history --stat` | `sayit-history.ps1 -Stat` |
| Starts at login | LaunchAgents | systemd user services | Logon task |

## Everyday commands

| Task | Linux and macOS | Windows |
| --- | --- | --- |
| Toggle recording | `./bin/sayit` | `.\win\sayit.ps1` |
| Discard recording | `./bin/sayit cancel` (Escape on macOS) | `.\win\sayit.ps1 cancel` |
| Check installation | `./bin/sayit doctor` | `.\win\sayit-doctor.ps1` |
| Show history | `./bin/sayit-history` | `.\win\sayit-history.ps1` |
| Show statistics | `./bin/sayit-history --stat` | `.\win\sayit-history.ps1 -Stat` |
| Teach a replacement | `./bin/sayit-learn "get hub" "GitHub"` | `.\win\sayit-learn.ps1 "get hub" "GitHub"` |
| Save a snippet | a line in `~/.config/sayit/snippets.tsv` | — |

The installation guides cover manual start and stop and indicator placement;
[Configuration](docs/CONFIGURATION.md#custom-wordlist) explains the wordlist,
[snippets](docs/CONFIGURATION.md#snippets),
[spoken punctuation](docs/CONFIGURATION.md#spoken-punctuation), models,
languages and accuracy settings.

## Performance

Measured, not estimated. On a Mac mini with an Apple M6, thirty Swedish FLEURS
sentences went through the same warm server and flags that sayit uses:

| Model | Mean per sentence | Word error rate |
| --- | ---: | ---: |
| KB-Whisper large q5_0 (the macOS default) | 1.05 s | 5.2% |
| KB-Whisper medium q5_0 | 0.64 s | 6.4% |
| Whisper large-v3-turbo q5_0 | 0.52 s | 8.4% |

Two optional settings trade a little accuracy for speed. On 423 FLEURS clips
greedy decoding (`BEAM=1`) took the median from 0.92 to 0.77 s and an encoder
window sized to the clip (`AUDIO_CTX_ADAPTIVE=1`) on top to 0.49 s, for a word
error rate of 5.73% instead of 5.38%. With `SEGMENT_WHILE_RECORDING=1` a long
dictation is transcribed piece by piece while you speak: the median from
release to text stayed between 0.6 and 0.8 s from 5 to 30 s of speech, against
up to 2.8 s without it.

[Performance](docs/PERFORMANCE.md) has the Linux and Windows measurements, the
hardware, the method and the limits of each number. Engine timings are kept
apart from the full button-to-text delay, and small samples are not presented
as general accuracy rankings.

## Limits

Text injection depends on the desktop and the application. Windows cannot
inject into an elevated window from a normal user process, and its indicator
cannot appear over exclusive fullscreen or the UAC secure desktop. Linux
Wayland needs the injection tools described in its guide. On macOS, Secure
Input (a password field, for example) hides keyboard triggers, and a blocked
paste leaves the text on the clipboard.

The model and its helpers stay running between dictations, which costs memory.
Transcription still takes a moment after release, longer for long recordings
unless `SEGMENT_WHILE_RECORDING=1` (macOS) transcribes them while you speak.

## Privacy

Audio is processed locally and recordings are temporary files, removed after
processing. Dictated text is kept in a local history file, and delivery can
pass through the clipboard. The [security guide](SECURITY.md) lists storage
paths, retention, clipboard handling and what diagnostics may reveal.

An optional text-cleanup step on Linux and macOS (`LLM_CLEANUP=1`, off by
default) sends the transcribed text to `LLM_URL`, a local Ollama by default.
Pointing it at a remote HTTP address sends text to that host unencrypted.

## Documentation

| Guide | Contents |
| --- | --- |
| [macOS installation](docs/INSTALL-MACOS.md) | Setup, permissions and everyday use on macOS |
| [Linux installation](docs/INSTALL-LINUX.md) | Setup and everyday use on Linux |
| [Windows installation](docs/INSTALL-WINDOWS.md) | Setup and everyday use on Windows 11 |
| [Optional Turbo engine](docs/OPENVINO.md) | OpenVINO installation, switching and recovery |
| [Configuration](docs/CONFIGURATION.md) | Settings, models, languages, wordlists and snippets |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Symptoms, checks and fixes |
| [Performance](docs/PERFORMANCE.md) | Measurements and their limits |
| [Architecture](docs/ARCHITECTURE.md) | Pipelines, components and design decisions |
| [Security](SECURITY.md) | Data handling and private vulnerability reports |

## Contributing

Bug reports, measurements from other hardware and pull requests are welcome.
CI runs shellcheck and syntax checks, the bats suites on Linux and macOS, the
Swift and Pester tests and the OpenVINO server tests; capture, inference and
desktop interaction still need a human with a microphone.
[Contributing](CONTRIBUTING.md) explains the layout, the checks and how to
send a change, and the [changelog](CHANGELOG.md) lists what changed when.

## Acknowledgements

sayit stands on [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[KBLab's KB-Whisper](https://huggingface.co/KBLab), the original
[Whisper](https://github.com/openai/whisper) models,
[OpenVINO](https://github.com/openvinotoolkit/openvino),
[Silero VAD](https://github.com/snakers4/silero-vad) and
[Solaar](https://github.com/pwr-Solaar/Solaar).

## License

[MIT](LICENSE).
