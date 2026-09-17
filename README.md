# sayit

Push-to-talk dictation for Linux and Windows 11. Hold a button, speak, then
release to insert your words into the focused text field.

[![ci](https://github.com/MrTorriz/sayit/actions/workflows/ci.yml/badge.svg)](https://github.com/MrTorriz/sayit/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform: Linux and Windows 11](https://img.shields.io/badge/platform-Linux%20%7C%20Windows%2011-informational)](#installation)

<p align="center">
  <img src="docs/demo.gif" alt="Linux demo: a waveform appears during recording, then the transcribed sentence is pasted into the focused window" width="760">
</p>

Speech recognition runs locally through [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
with Vulkan acceleration and [KB-Whisper](https://huggingface.co/KBLab/kb-whisper-medium)
as the default Swedish model. Both platforms also support an optional
**Whisper large-v3-turbo / OpenVINO** engine for compatible Intel graphics.
No account or subscription is required.

- Hold-to-talk with a waveform indicator; toggle mode is also available.
- Text entry in terminals, editors and browsers, subject to platform permissions.
- A custom wordlist for recurring recognition errors, plus dictation history.
- A warm model for repeated use and automatic startup after login.

## Installation

Setup requires a terminal, native build tools and model files. This is a
source installation, not a packaged desktop installer. Read the requirements
for your platform before running the commands.

### Linux

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh
./bin/test-pipeline
```

The installer builds whisper.cpp, downloads the models and creates `.env`.
Then configure a mouse button or keyboard shortcut. KWin/Plasma also requires
`ydotoold` for text injection.

[Linux installation guide](docs/INSTALL-LINUX.md) — requirements, triggers,
Wayland setup, Bluetooth and automatic startup.

### Windows 11

```powershell
git clone https://github.com/MrTorriz/sayit.git
cd sayit
.\win\install.ps1
.\win\sayit-doctor.ps1
```

The installer checks build tools, builds whisper.cpp and offers to register
an automatic logon task. **Download the two base model files separately** as
explained in the guide. Some mice also need their thumb button mapped in the
vendor's utility before Windows can see it.

After setup, Mouse 5 is the default hold-to-talk button. A black waveform with
no border, lamp or label appears while recording. The trigger and text worker
stay ready between recordings; the microphone is closed while idle. The
selected model loads automatically at login, including after a reboot.

[Windows installation guide](docs/INSTALL-WINDOWS.md) — prerequisites, model
links, microphone selection, autostart and platform limits. GitHub CLI is not
required.

### Optional Turbo engine

Complete the base installation first, then follow the
[OpenVINO setup guide](docs/OPENVINO.md). It covers the isolated Python runtime,
compatible hardware, model verification and switching back to the native engine.

| Select the installed Turbo engine | Command |
| --- | --- |
| Linux | `./bin/sayit-engine fast` |
| Windows | `.\win\sayit-engine.ps1 fast` |

Use `accurate` instead of `fast` to return to the configured whisper.cpp model.
The selection persists across logins. These names select engines; they do not
guarantee which one will recognize a particular sentence best.

## Everyday commands

| Task | Linux | Windows |
| --- | --- | --- |
| Toggle recording | `./bin/sayit` | `.\win\sayit.ps1` |
| Discard recording | `./bin/sayit cancel` | `.\win\sayit.ps1 cancel` |
| Check installation | `./bin/sayit doctor` | `.\win\sayit-doctor.ps1` |
| Show history | `./bin/sayit-history` | `.\win\sayit-history.ps1` |
| Show statistics | `./bin/sayit-history --stat` | `.\win\sayit-history.ps1 -Stat` |
| Teach a replacement | `./bin/sayit-learn "get hub" "GitHub"` | `.\win\sayit-learn.ps1 "get hub" "GitHub"` |

See the installation guides for manual start/stop commands and indicator
placement, and [Configuration](docs/CONFIGURATION.md#custom-wordlist) for
wordlist rules.

## Limits and performance

Text injection depends on the desktop and application. Windows cannot inject
into an elevated window from the normal user process; its indicator cannot
appear over exclusive fullscreen or the UAC secure desktop. Linux Wayland
requires the injection tools described in its installation guide.

The model and supporting processes remain running between dictations, using
memory and some background resources. Recognition speed depends on the model,
hardware and recording length; transcription still takes time after release.

[Performance measurements](docs/PERFORMANCE.md) document the Linux and Windows
tests, hardware and methods. Engine timings are distinguished from the full
button-to-text delay, and small samples are not general accuracy rankings.

## Privacy

Audio processing runs locally, with the model server bound to `127.0.0.1`.
There is no telemetry. Installation downloads dependencies and models;
subsequent speech recognition works offline.

Dictated text is saved in local history, and recordings are temporary files
removed after processing. Text delivery can use the clipboard. The
[security guide](SECURITY.md) explains storage paths, retention, clipboard
handling and what diagnostics may reveal.

An optional Linux text-cleanup step (`LLM_CLEANUP=1`, off by default) sends
transcribed text to `LLM_URL`. Its default is local Ollama; configuring a remote
HTTP address sends text to that host without transport encryption.

## Documentation

| Guide | Contents |
| --- | --- |
| [Linux installation](docs/INSTALL-LINUX.md) | Setup and everyday use on Linux |
| [Windows installation](docs/INSTALL-WINDOWS.md) | Setup and everyday use on Windows 11 |
| [Optional Turbo engine](docs/OPENVINO.md) | OpenVINO installation, switching and recovery |
| [Configuration](docs/CONFIGURATION.md) | Settings, models and wordlists |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Symptoms, checks and fixes |
| [Performance](docs/PERFORMANCE.md) | Measurements and their limits |
| [Architecture](docs/ARCHITECTURE.md) | Pipelines, components and design decisions |
| [Security](SECURITY.md) | Data handling and private vulnerability reports |

## Development

Linux commands live in `bin/`, Windows scripts and C# helpers in `win/`, and
the shared optional server in `engines/openvino/`. Tests live in `tests/`,
`win/tests/` and alongside that server. Shared code and settings can affect
both platforms.

CI checks syntax, shell scripts, Windows helpers and the automated test suites.
Hardware-dependent capture, inference and desktop interaction also need manual
testing. See [Contributing](CONTRIBUTING.md) for checks and contribution guidance,
and the [changelog](CHANGELOG.md) for updates.

## License

[MIT](LICENSE).
