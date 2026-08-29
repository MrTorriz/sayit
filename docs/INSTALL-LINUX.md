[← README](../README.md) · **Install: Linux** · [Windows](INSTALL-WINDOWS.md) · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md) · [Architecture](ARCHITECTURE.md)

# Installing sayit on Linux

- [Requirements](#requirements)
- [Installation](#installation)
- [Upgrading and rollback](#upgrading-and-rollback)
- [Text injection on KWin/Wayland (ydotool)](#text-injection-on-kwinwayland-ydotool)
- [Trigger: mouse button via Solaar](#trigger-mouse-button-via-solaar)
- [Trigger: global hotkey](#trigger-global-hotkey)
- [Recording indicator and live meter](#recording-indicator-and-live-meter)
- [Bluetooth headsets](#bluetooth-headsets)
- [Daemon mode](#daemon-mode)
- [History and statistics](#history-and-statistics)
- [Verifying the installation](#verifying-the-installation)

## Requirements

- Any Linux distribution with PipeWire. Developed and tested on Fedora KDE
  under Wayland; `install.sh` knows the package names for Fedora,
  Debian/Ubuntu and Arch.
- A Vulkan-capable GPU is recommended. Without one the build falls back to CPU,
  which works but is much slower — see [Performance](PERFORMANCE.md).
- Python 3 and Perl, both present on virtually every distribution.

`install.sh` checks for the rest and offers to install it: `cmake`, a C++
toolchain, `git`, `curl`, the PipeWire tools, `ydotool`, `wl-clipboard`, `jq`,
`libnotify` and the Vulkan development packages.

Optional, and worth having:

- `python3-gobject`, GTK 3 and `gtk-layer-shell` — required by the `overlay`
  meter style, which is the default. Without them the meter falls back to the
  Plasma OSD.
- `wtype` — an injection fallback on wlroots compositors.
- `espeak-ng` — used by the smoke test and the benchmark harness.

On KWin/Wayland the `ydotoold` service needs a one-time setup. That step is
below and it is not optional there: without it, text injection does not work
at all.

## Installation

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh                 # interactive
./install.sh -y              # answer yes to everything
./install.sh --model large   # best accuracy (default: medium)
./install.sh --help          # all flags
```

What `install.sh` does, in order:

1. Verifies the system packages through dnf, apt or pacman, and prints a
   manual list on anything else.
2. Clones and builds whisper.cpp at a **pinned release** into
   `~/.local/src/whisper.cpp` — with Vulkan when it is available, CPU-only
   otherwise.
3. Symlinks `whisper-cli` to `~/.local/bin/whisper-cli`.
4. Downloads the KB-Whisper model (q5_0) into `models/` and **verifies its
   sha256** against the published upstream checksum.
5. Downloads the Silero VAD model, about 1 MB, also checksum-verified.
6. Creates `.env` from `.env.example` and seeds
   `~/.config/sayit/wordlist.tsv`.
7. Installs the theme icons — the notification mark and the OSD meter levels —
   into `~/.local/share/icons/hicolor/scalable/`, then touches the theme
   directory so running desktops pick them up without a re-login. An
   incomplete `icons/` degrades to the generic icon rather than aborting the
   install.

| Flag | Effect |
| --- | --- |
| `-y`, `--yes` | Answer yes to all prompts |
| `--model SIZE` | Model size: `small`, `medium` or `large` |
| `--rebuild` | Re-fetch and rebuild whisper.cpp at the pinned release |
| `--skip-packages` | Skip the system package check |
| `--skip-build` | Skip the whisper.cpp build |
| `--skip-model` | Skip the model downloads |
| `-h`, `--help` | Show help and exit |

Re-running the installer is always safe. It never overwrites an existing
`.env` — it reports the settings yours is missing instead — never re-downloads
a model that is already there, and skips the build.

To reinstall only the theme icons:

```bash
./install.sh --skip-packages --skip-build --skip-model
```

## Upgrading and rollback

To upgrade whisper.cpp to the release pinned in the script:

```bash
./install.sh --rebuild
```

To roll back, or to pin a different revision:

```bash
WHISPER_REF=<tag-or-commit> ./install.sh --rebuild
```

The revision that was built is recorded in
`~/.local/src/whisper.cpp/.sayit-build-info`.

## Text injection on KWin/Wayland (ydotool)

KWin — Plasma 6 — does **not** expose the virtual-keyboard protocol, so
`wtype` fails there with `Compositor does not support the virtual keyboard
protocol`. Use `ydotool`, which goes through uinput instead.

The `ydotoold` daemon must be running with its socket accessible to your user.
Set up a systemd override:

```bash
sudo mkdir -p /etc/systemd/system/ydotool.service.d
sudo tee /etc/systemd/system/ydotool.service.d/override.conf >/dev/null <<UNIT
[Service]
ExecStart=
ExecStart=/usr/bin/ydotoold --socket-path=/run/.ydotool_socket --socket-perm=0660 --socket-own=$(id -u):$(id -g)
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now ydotool.service
```

`bin/sayit-inject` reads `YDOTOOL_SOCKET`, defaulting to
`/run/.ydotool_socket`, and falls back automatically to `wtype` on wlroots or
`xdotool` on X11 depending on your session.

Be aware of the trade-off: a user-accessible uinput socket lets **any** process
running as your user synthesize input system-wide. That is inherent to this
approach on KWin, not something sayit adds. See [SECURITY.md](../SECURITY.md).

Why sayit pastes rather than types on Linux: synthetic typing tools send
US-layout keycodes, which drops or mangles non-ASCII characters on other
layouts. sayit copies the text to the clipboard and sends a single
`Shift+Insert`, which is exact for every language and toolkit, then restores
your previous clipboard. The reasoning is in
[ARCHITECTURE.md](ARCHITECTURE.md); the exact clipboard rules are in the
README's privacy section.

## Trigger: mouse button via Solaar

Turn a Logitech mouse thumb button into push-to-talk with
[Solaar](https://github.com/pwr-Solaar/Solaar): hold to record, release to
transcribe and paste. There is an example in
[`config/solaar-rules.example.yaml`](../config/solaar-rules.example.yaml).

1. Divert the button. In the Solaar GUI: device, then button, then
   "Diverted" — or set the control ID to `1` under `divert-keys` in
   `~/.config/solaar/config.yaml`. On the MX Master 3S, the large thumb plate
   ("Mouse Gesture Button") is control ID `195`.
2. Copy the example to `~/.config/solaar/rules.yaml`, fix the paths, and
   restart Solaar. It reads that file only at startup.
3. The rules run `sayit start` on press and `sayit stop` on release.

On a Bluetooth microphone such as AirPods, the profile switch takes around a
second, up to about 2.5 s, before the mic is live. Wait for the recording
indicator before you start speaking — recording begins only once the
microphone is actually capturing.

## Trigger: global hotkey

Bind `bin/sayit` to any free key. On KDE: System Settings, Shortcuts, Custom
Shortcuts — see [`config/kglobalshortcuts.example`](../config/kglobalshortcuts.example)
and the [`config/sayit.desktop`](../config/sayit.desktop) template. On other
desktops, any mechanism that runs a command on a keypress works.

Press once to start, speak, press again to stop, transcribe and paste.

## Recording indicator and live meter

While the microphone is live, sayit shows two independent pieces of feedback.
`RECORDING_METER=0` turns off the meter, `RECORDING_INDICATOR=0` the
notification.

**A live voice meter.** By default it is a small pill above your other windows,
showing the `sayit` wordmark, a row of bars and a recording lamp. The bars follow
your voice level and the lamp burns red while the microphone is open, so you can
see that dictation hears you. It exists only while a recording does, and clicks
pass straight through it, so it can never be in the way.

```bash
./bin/sayit-overlay --place            # drag the pill, Enter or Escape saves
./bin/sayit-overlay --print-position   # report where it is
./bin/sayit-overlay --check            # can the overlay style run here?
```

The position is remembered in `~/.config/sayit/overlay-position`.

**Keeping the pill on screen between dictations.** By default it exists only
while a recording does. To have it there for the whole session instead, enable
the user service:

```bash
mkdir -p ~/.config/systemd/user
sed "s|%h/path/to/sayit|$PWD|g" config/systemd/sayit-overlay.service \
    > ~/.config/systemd/user/sayit-overlay.service
systemctl --user daemon-reload
systemctl --user enable --now sayit-overlay.service
```

At rest it looks exactly as it does while recording — same size, same colours,
same place — except that the bars are still and the lamp is dark. It holds no
microphone stream at all. It stays above other windows in both states, a
fullscreen video included, so that a pill parked in a desktop panel's strip
cannot end up behind the panel. `systemctl --user disable --now sayit-overlay`
goes back to the default.

**A resident pill is draggable at any time.** There is no mode to enter and
nothing to remember: point at it and drag, at rest or mid-dictation, and the new
position is saved when you let go. `--place` has nothing left to do in that case
and will tell you so rather than drawing a second pill on top of the first.

Nothing on the pill moves for any reason other than the two it means: the bars
are the level meter, and the lamp is lit when the microphone is open and dark
when it is not. Dragging changes neither.

The meter opens its own low-rate PipeWire stream — the recording itself is
unaffected — and uses the audio only to compute a level. Nothing is stored. The
two OSD styles stop by themselves after 120 s as a safety cap; the `overlay`
style has no such cap and ends when its capture stream does. With the resident
service running, the meter feeds that pill through a FIFO instead of starting
one of its own.

Three styles, each falling back to the next when its requirements are missing,
so it degrades instead of disappearing:

| `RECORDING_METER_STYLE` | What you get | Needs |
| --- | --- | --- |
| `overlay` (default) | sayit's own pill, freely positionable, click-through | Wayland with layer-shell, plus the GTK bindings listed as optional above |
| `mark` | the animated mark in Plasma's on-screen display | Plasma OSD and the theme icons `install.sh` installs |
| `wave` | a scrolling bar waveform in the same OSD | Plasma OSD |

**A persistent notification** as the recording indicator. It appears when
capture actually starts — after any Bluetooth profile switch — and is removed
on stop, cancel and failure. `./bin/sayit-indicator hide` removes a stuck one.

The notification and the OSD styles use the sayit theme icons, in light and
dark variants following the desktop colour scheme, and fall back to a generic
microphone icon without them.

## Bluetooth headsets

Bluetooth headphones normally sit in the A2DP profile for high-quality
playback, which exposes **no microphone**. sayit therefore switches the
connected headset to its headset profile (HSP/HFP) when recording starts,
records from its mic, and switches back on stop. `bin/sayit-bt` handles it and
there are no manual steps.

```bash
./bin/sayit-bt up     # headset profile; prints the source name
./bin/sayit-bt down   # restore the previous profile
```

- The headset is picked dynamically from the default output, so several
  headsets work without configuration.
- The headset profile degrades **playback** to phone quality — mSBC, 16 kHz
  mono — while recording, restored immediately on stop.
- With no Bluetooth headset connected, `sayit-bt` is a no-op and recording uses
  `AUDIO_SOURCE` or the PipeWire default microphone.
- The switch is synchronous and takes around a second, up to about 2.5 s.
  Recording and the indicator start once the mic is actually live.
- **With a dedicated microphone, set `AUDIO_SOURCE`.** sayit then records
  straight from it and never touches the headset, so playback stays in A2DP
  throughout: no switch, no delay, no quality drop. `./bin/sayit doctor`
  confirms which of the two paths your configuration selects.

Use the PipeWire *node name*, never the numeric id from `wpctl status` —
PipeWire reassigns ids on every reboot and re-plug:

```bash
pactl list sources short     # second column is the node name
```

This whole stage exists only on Linux. Windows selects HFP itself when an
application opens a capture endpoint.

## Daemon mode

The daemon keeps the model warm in RAM through `whisper-server`, on
`127.0.0.1` at `DAEMON_PORT`. It removes the per-dictation model load — see
[Performance](PERFORMANCE.md#linux-reference-machine) for what that is worth.

```bash
cp config/systemd/sayit-daemon.service ~/.config/systemd/user/
# edit the two paths in the service file to your clone location, then:
systemctl --user daemon-reload
systemctl --user enable --now sayit-daemon.service
```

The service runs `bin/sayit-daemon`, which sources `.env` and starts
`whisper-server` with the right model, VAD, flash attention and beam settings.
Change the model or VAD in `.env` and restart the service — no service-file
editing needed.

```bash
systemctl --user restart sayit-daemon.service
```

`bin/sayit-transcribe` uses the server automatically when it responds — a POST
to `http://127.0.0.1:9876/inference` at the configured port — and falls back to
`whisper-cli` **only** on a transport failure. An empty response from a
healthy daemon means "no speech" and is final. `whisper-cli` and the model file
are needed only for that fallback path; a healthy daemon serves on its own.

The server has no authentication, so any local process can reach it. Keep it on
loopback.

## History and statistics

```bash
./bin/sayit-history              # latest 20 transcriptions
./bin/sayit-history 50           # latest 50
./bin/sayit-history --stat       # words, speaking WPM, time saved vs typing
./bin/sayit-history --stat 7d    # same, limited to a period (Nd/Nh/Nm)
./bin/sayit-history --copy 175   # copy entry 175 to the clipboard
./bin/sayit-history --inject 175 # re-inject entry 175 into the focused window
./bin/sayit-history --clear      # empty the history
```

<p align="center">
  <img src="history_list.png" alt="sayit-history terminal output showing a numbered list of transcriptions" width="720">
</p>

History lives in `~/.local/share/sayit/history.jsonl`, one JSON object per
line. The listing shows each entry's **absolute line number**, so the same N
works directly with `--copy` and `--inject`. Long entries are shortened to an
80-character budget in the list view and the cut is marked; `--copy` gives you
the full text. Corrupt lines, from a crash mid-write, are skipped with a
warning — they never take the rest of the history down.

`--stat` estimates **time saved** by comparing your speaking time against how
long the same number of words would take to type at `TYPING_WPM` words per
minute, 40 by default.

<p align="center">
  <img src="history_stat.png" alt="sayit-history statistics output comparing speaking speed with typing speed" width="720">
</p>

## Verifying the installation

```bash
./bin/test-pipeline     # synthetic voice through the whole pipeline
./bin/sayit doctor      # read-only check of the recording path
```

`test-pipeline` needs `espeak-ng`. It opens no microphone: it synthesises the
test sentence and feeds the WAV straight to the transcriber, so a pass means
the model, the daemon or CLI, and the wordlist all work.

If something is wrong, [Troubleshooting](TROUBLESHOOTING.md#linux) has the
symptom table.

Next: [Configuration](CONFIGURATION.md) for every setting, or
[Architecture](ARCHITECTURE.md) for why the pipeline is built this way.
