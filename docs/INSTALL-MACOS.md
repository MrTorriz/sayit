[← README](../README.md) · [Install: Linux](INSTALL-LINUX.md) · [Windows](INSTALL-WINDOWS.md) · **macOS** · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md) · [Architecture](ARCHITECTURE.md)

# Installing sayit on macOS

- [Requirements](#requirements)
- [Installation](#installation)
- [Granting Microphone and Accessibility](#granting-microphone-and-accessibility)
- [Choosing the trigger](#choosing-the-trigger)
- [Choosing a microphone](#choosing-a-microphone)
- [Recording indicator](#recording-indicator)
- [The menu bar item](#the-menu-bar-item)
- [The daemon and the LaunchAgents](#the-daemon-and-the-launchagents)
- [Text injection](#text-injection)
- [History and statistics](#history-and-statistics)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Verifying the installation](#verifying-the-installation)
- [Known platform limits](#known-platform-limits)

On a Mac, sayit is the Linux bash scripts in `bin/` plus three small Swift
programs for the parts where macOS demands its own API:

- **`Sayit.app`**, a menu bar agent that holds the push-to-talk trigger, draws
  the recording pill and shows the last status. It records and pastes nothing
  itself: it runs `bin/sayit start`, `stop` and `cancel`, exactly as Solaar or
  a desktop shortcut does on Linux.
- **`sayit-rec`**, which records 16 kHz mono WAV from a Core Audio input.
- **`sayit-paste`**, which delivers the text to the focused window.

The session state machine, transcription, wordlist, history and statistics are
the same code that runs on Linux, with a few branches for Darwin.

## Requirements

- **An Apple Silicon Mac is recommended.** sayit was developed and tested on an
  Apple M6 Mac mini under macOS 27.2. An Intel Mac has not been tried; there the
  scripts default to the medium model rather than large.
- **macOS 14 or later**, the minimum the app is built for.
- **[Homebrew](https://brew.sh).** `install.sh` installs `cmake` and `bash`
  from it.
- **The Xcode Command Line Tools** (`xcode-select --install`): the compilers
  for whisper.cpp, `swiftc` for the app, `git` and `python3`. Homebrew needs
  them as well. Xcode itself is not needed, and there is no Xcode project.

Homebrew's bash is not optional. macOS ships bash 3.2 and the scripts need 4 or
newer, yet `#!/usr/bin/env bash` resolves to `/bin/bash` wherever `PATH` starts
with the system directories — which is exactly the minimal `PATH` launchd gives
a service. Both LaunchAgents, and every command `Sayit.app` starts, therefore
put `/opt/homebrew/bin` and `/usr/local/bin` first on `PATH`. `install.sh`
itself runs under the system's bash 3.2, so it works on a fresh Mac before
Homebrew's bash is there.

whisper.cpp v1.9.2, the release `install.sh` pins on every platform, builds its
Metal backend (with Accelerate for BLAS) by default on Apple Silicon. No GPU
SDK is needed.

## Installation

```bash
git clone https://github.com/MrTorriz/sayit.git
cd sayit
./install.sh                  # interactive
./install.sh -y               # answer yes to everything
./install.sh --model medium   # the smaller model (Apple Silicon default: large)
./install.sh --skip-agent     # everything except Sayit.app and the LaunchAgents
./install.sh --help           # all flags
```

What `install.sh` does on macOS, in order:

1. Checks for Homebrew and the Command Line Tools and stops with the command to
   run if either is missing, then offers to `brew install` whichever of `cmake`
   and `bash` is missing.
2. Clones and builds whisper.cpp at the **pinned release** into
   `~/.local/src/whisper.cpp` with Metal, and records `backend=metal` in its
   `.sayit-build-info`.
3. Symlinks `whisper-cli` to `~/.local/bin/whisper-cli`.
4. Downloads the KB-Whisper model (q5_0) into `models/` and **verifies its
   sha256** — the large model on Apple Silicon, medium elsewhere.
5. Downloads the Silero VAD model, about 1 MB, also checksum-verified.
6. Creates `.env` from `.env.example` and seeds
   `~/.config/sayit/wordlist.tsv`.
7. Runs `mac/install.sh`, which compiles `Sayit`, `sayit-rec` and `sayit-paste`
   with `swiftc`, bundles them into `~/Applications/Sayit.app`, signs the
   bundle, and writes and loads the two LaunchAgents described
   [below](#the-daemon-and-the-launchagents).

| Flag | Effect |
| --- | --- |
| `-y`, `--yes` | Answer yes to all prompts |
| `--model SIZE` | Model size: `small`, `medium` or `large` (default `large` on Apple Silicon, `medium` elsewhere) |
| `--rebuild` | Re-fetch and rebuild whisper.cpp at the pinned release |
| `--skip-packages` | Skip the Homebrew check |
| `--skip-build` | Skip the whisper.cpp build |
| `--skip-model` | Skip the model downloads |
| `--skip-agent` | Skip building `Sayit.app` and loading the LaunchAgents |
| `-h`, `--help` | Show help and exit |

Re-running the installer is safe, with one property worth knowing: the app is
rebuilt only when its sources change, but **every run rewrites and reloads both
LaunchAgents**, which restarts the daemon and `Sayit.app`.

`mac/install.sh` can also be run on its own:

```bash
mac/install.sh                # build when the sources changed, install, (re)load
mac/install.sh --rebuild      # build even when nothing changed
mac/install.sh --no-launchd   # build and install the app only
mac/install.sh --uninstall    # see Uninstalling
```

**Why large is the default here.** On the
[macOS reference machine](PERFORMANCE.md#macos-reference-machine) the large
model made fewer errors than medium and still answered an ordinary dictation in
about a second, so an Apple Silicon Mac downloads it, and the scripts prefer
`models/ggml-kb-whisper-large-q5_0.bin` whenever that file is present. Any
other `--model` writes `MODEL_PATH` into a new `.env`, or prints the line to
add to an existing one, because without it the scripts would keep loading
large:

```bash
./install.sh --model medium
launchctl kickstart -k gui/$(id -u)/io.github.mrtorriz.sayit.daemon   # after editing an existing .env
```

## Granting Microphone and Accessibility

When the LaunchAgent starts `Sayit.app` for the first time, it asks for both
permissions it needs:

- **Microphone.** The system dialog comes up at launch rather than in the middle
  of your first dictation.
- **Accessibility.** Sayit opens the system prompt; turn Sayit on under
  System Settings > Privacy & Security > Accessibility. Sayit retries every two
  seconds, so the trigger arms as soon as the switch is on — no restart.

Accessibility is what both halves of the job need: an event tap that can
swallow the trigger, and the `Cmd+V` that `sayit-paste` posts. Sayit does not
need Input Monitoring; only a terminal running `Sayit --probe` does (see
[below](#finding-out-what-a-button-sends)).

**The grants belong to `Sayit.app`.** `sayit-rec` and `sayit-paste` live inside
its bundle and are started by Sayit through `bin/sayit`, so macOS attributes
them to Sayit — the responsible process — and they run under its grants. A
command you start in Terminal is attributed to Terminal instead: `./bin/sayit`,
`./bin/sayit-inject` or `./bin/sayit-history --inject` run from a shell need
Terminal to hold Microphone or Accessibility of its own, and macOS asks for it
on first use.

**A denied microphone does not fail on macOS; it records silence.** `sayit-rec`
checks the authorization before it opens anything and exits with code 2 when
it is denied. If a capture nonetheless comes back with a loudest sample of
zero, it writes `digitally silent capture (peak 0)` to the error log rather
than letting the empty transcription look like quiet speech.

If either permission is missing, Sayit's menu shows **Allow Accessibility…** or
**Allow Microphone…**, which open the right pane of System Settings.
`./bin/sayit doctor` reports the permissions as Sayit itself last saw them —
the app's grants, not those of the terminal you run the doctor in.

## Choosing the trigger

`Sayit.app` listens for one key, modifier key or mouse button through a
session-wide event tap, and runs `bin/sayit start` and `stop` around it.
`TRIGGER_BUTTON` in `.env` names it, using the same setting name as Windows.

**The macOS default is `F18`**: Sayit uses it when `TRIGGER_BUTTON` is empty
or absent, and `install.sh` writes it into a `.env` it creates on a Mac (the
template's `XBUTTON2` is the Windows default, which a Mac would read as mouse
button 5, the forward button). A `.env` copied from another machine keeps
whatever it says. Set the value you want, then choose **Reload Settings** in
Sayit's menu. The menu's second line names the button Sayit is listening for.

| `TRIGGER_BUTTON` | Meaning |
| --- | --- |
| `F1` … `F20` | A function key. F13–F20 are missing from most keyboards, which leaves them free to assign in a mouse utility |
| `MIDDLE`, `XBUTTON1`, `XBUTTON2` | The middle button, mouse button 4 (back) and mouse button 5 (forward) — the Windows names, accepted as they are |
| `MOUSE2` … `MOUSE31` (or `BUTTON<n>`) | A mouse button by macOS's own number, as the probe prints it: `MOUSE2` is the middle button, `MOUSE3` back, `MOUSE4` forward |
| `KEY0` … `KEY127` | A key by its virtual key code, as the probe prints it |
| `VK124` … `VK131` | The Windows codes for F13–F20, accepted so that a Windows `.env` works unchanged |
| `ESCAPE`, `SPACE`, `TAB`, `RETURN`, `HOME`, `END`, `PAGEUP`, `PAGEDOWN`, `HELP`, `A`–`Z`, `0`–`9` | Named keys. Letters and digits are key positions on an ANSI keyboard, not characters |
| `CTRL+OPTION+F12` | A key with modifiers that must be held: `CMD`/`COMMAND`, `OPT`/`OPTION`/`ALT`, `CTRL`/`CONTROL`, `SHIFT`. Exactly those: an extra modifier held means no match |
| `RIGHTOPTION`, `LEFTOPTION`, `RIGHTCOMMAND`, `LEFTCOMMAND`, `RIGHTCONTROL`, `LEFTCONTROL`, `RIGHTSHIFT`, `LEFTSHIFT`, `FN` | A modifier key on its own, left and right told apart |

Values are case-insensitive. A value Sayit cannot parse binds nothing; the menu
says `TRIGGER_BUTTON="…" is not understood` and the doctor reports it as a
failure.

`TRIGGER_SUPPRESS=1`, the default, swallows the trigger so the focused
application never sees it — without it, a forward button would also navigate
the browser forward on every dictation. Two exceptions: **a modifier key used
on its own is never swallowed**, because the system's idea of which keys are
held must stay intact; and with such a trigger, **any other key pressed while
it is held cancels the recording**, since that is a shortcut, not a dictation.
Pick a key you never type: a suppressed `SPACE` swallows every space.

### Hold, tap or toggle

| `TRIGGER_MODE` | Held 0.4 s or longer | Tapped |
| --- | --- | --- |
| `auto` (default) | Release stops: push-to-talk | Latches; the next press stops |
| `hold` | Release stops | Release stops, so a tap is a very short recording |
| `toggle` | Release does nothing; the next press stops | The same |

`auto` exists for buttons whose vendor utility turns a hold into a tap: either
way the button works, held or tapped. If a latched recording has already ended
— a start that failed, or a stop from the terminal — Sayit notices within a
second and the next press starts a new one instead of stopping nothing. A
recording whose recorder ended on its own — `MAX_RECORD_SECONDS`, or a device
that went away — is stopped within a second and what was captured is
transcribed then, not at the next press, which could come hours later in
another window.

**Escape discards a recording the trigger started**, in every mode, like
`./bin/sayit cancel`. It acts only with no modifier held, and is swallowed
when it does.

### A Logitech mouse: Logi Options+

On macOS a Logitech mouse's buttons are diverted by Logi Options+; Solaar does
not exist there. **Most Options+ assignments never reach Sayit.** Its Back and
Forward presets are macOS swipe gestures (`OSX_GESTURE_BACK`,
`OSX_GESTURE_FORWARD`), and the gesture button sends gestures or shortcuts, so
the probe shows nothing for them, or a keyboard shortcut of the utility's own.

What works is Options+'s generic mouse-button action, the one its **Middle
button** preset uses (`"mouse": {"action": "BUTTON", "hidUsage": 3}`). With
`hidUsage` 5 the button sends a real mouse button 5, held for as long as you
hold it, which is `TRIGGER_BUTTON="XBUTTON2"` — push-to-talk, and unaffected
by Secure Input. Options+ offers no preset for button 5 (verified with an
MX Master 3S, October 2026), so the assignment has to be written into its
settings database while its agent is stopped. This is an advanced step; back
the file up first:

```bash
S="$HOME/Library/Application Support/LogiOptionsPlus"
cp -p "$S"/settings.db* ~/somewhere-safe/
launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr   # stops Options+'s agent
# settings.db is SQLite; table "data" holds one JSON document. In every
# "profile-…" object, find the assignment whose "slotId" ends in the button's
# control id (_c195 = MX Master gesture button, _c86 = forward, _c83 = back)
# and give it this card (keep "applicationId" in per-app profiles):
#   {"id": "card_custom_sayit_mouse_button_5", "attribute": "MACRO_PLAYBACK",
#    "name": "Mouse button 5", "readOnly": true,
#    "macro": {"type": "MOUSE", "actionName": "MB5",
#              "mouse": {"action": "BUTTON", "hidUsage": 5}}}
# and set "cardId" to the same id.
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.logi.optionsplus.plist
```

Change every profile that assigns the button — Options+ keeps per-app
profiles (Safari has one by default) that override the default one. Resetting
the button in Options+, or an Options+ update, can put the preset back; the
probe then shows nothing again and the step has to be repeated.

A **keystroke** assignment that matches `TRIGGER_BUTTON`, such as `F18`, works
without touching the database, but Options+ sends it as a tap: `TRIGGER_MODE=auto`
latches it, so tap once to start and once to stop. Keyboard triggers are also
blind while Secure Input is on.

Prefer a mouse-button assignment when you have the choice. Keyboard events are
invisible to every event tap while **Secure Input** is on — a password field,
or Terminal's Secure Keyboard Entry — and mouse buttons are not.

### Finding out what a button sends

Choose **Probe Trigger** in Sayit's menu and press the button. The last three
transitions appear in the menu's second line, and all of them are appended to
`trigger-probe.log` in the run directory, the per-user temporary directory
that `getconf DARWIN_USER_TEMP_DIR` names. The trigger keeps working
while the probe runs. Choose the item again to stop.

From a terminal, the same for 30 seconds, swallowing nothing:

```bash
~/Applications/Sayit.app/Contents/MacOS/Sayit --probe
```

That terminal needs Input Monitoring (or Accessibility) of its own; the menu
item needs nothing extra. Translating what the probe prints:

| Probe line | `TRIGGER_BUTTON` |
| --- | --- |
| `mouse down MOUSE3` | `MOUSE3` (the same as `XBUTTON1`) |
| `key down KEY79` | `KEY79`, which is `F18` |
| `key down KEY111 [CTRL+OPTION]` | `CTRL+OPTION+KEY111`. An `FN` in the brackets is ignored by matching; leave it out |
| `modifier KEY61` | The modifier's name, here `RIGHTOPTION`. `KEY61` would be read as an ordinary key and never fire |
| `key down (a typing key - not recorded)` | A key that types a character is never named, so that a probe left running records no text. Hold `Cmd` or `Ctrl` with it to see its code, or use its name from the table above |

> The probe names every mouse button and modifier, the keys that type no
> character — function keys, Escape, the arrows and navigation keys — and any
> key pressed with `Cmd` or `Ctrl` held. Other keys appear only as "a typing
> key". It also sees keys pressed in other applications while it runs, so turn
> it off when you have your answer; `trigger-probe.log` stays until you delete
> it. Sayit in its normal mode writes no such log.

## Choosing a microphone

```bash
./bin/sayit doctor                                                  # inputs, and what AUDIO_SOURCE resolves to
~/Applications/Sayit.app/Contents/MacOS/sayit-rec --list            # * marks the default; UID, name
~/Applications/Sayit.app/Contents/MacOS/sayit-rec --resolve "Alias" # what one value would select
```

`AUDIO_SOURCE` is empty by default, which records from the system default
input — the one chosen under System Settings > Sound > Input. Otherwise the
value is matched against the input devices in this order:

1. a device **UID**, exactly;
2. a device **name**, ignoring case;
3. **part of** a device name;
4. a device whose name, letters and digits only, is **embedded in the value** —
   the longest such name wins.

The last step means a PipeWire node name copied from a Linux `.env`, such as
`alsa_input.usb-Acme_USB_Microphone-00.mono-fallback`, still finds
"Acme USB Microphone". A value that matches nothing makes the recording fail to
start, and the error log lists the devices that were available.

**Bluetooth headsets switch themselves.** When capture opens a headset's
microphone — AirPods, for instance — macOS moves the headset to its call
profile on its own, as Windows does, and playback drops to call quality for the
length of the recording. There is nothing for sayit to switch and nothing to
restore, so `bin/sayit-bt` exits at once on macOS. A dedicated USB microphone
named in `AUDIO_SOURCE` avoids the switch entirely: the headset's microphone is
never opened.

`MAX_RECORD_SECONDS`, 120 by default, caps one recording. `sayit-rec` enforces
it itself, so it bounds how long the microphone stays open even if whatever
started the recording dies before stopping it. A device that disappears
mid-recording ends the recording with what was captured so far. Either way
Sayit transcribes it straight away, and the status line adds `the recording
had already stopped`.

## Recording indicator

`RECORDING_INDICATOR=1`, the default, shows sayit's pill above your other
windows. It is the pill the Linux overlay draws, with the same two lifetimes:

| | Transient (default) | Resident (`INDICATOR_RESIDENT=1`) |
| --- | --- | --- |
| On screen | Only while recording | The whole session |
| Contents | A meter across the whole pill | Lamp, meter and wordmark |
| Clicks | Pass straight through | Drag it to move it, unless `INDICATOR_LOCKED=1` |
| Lamp | — | Lit while audio is arriving, and by nothing else |

The pill is 160x40 points, scaled by `INDICATOR_SCALE` (0.5 to 4.0). It never
takes focus and never activates, and it is set to join every Space, full-screen
ones included. The bars rest as a row of dots and move only with your voice;
the level comes from `sayit-rec`, which has already computed it, so the
microphone is opened exactly once. The Linux meter opens a second capture
stream for the same job.

The transient pill goes as soon as you release the trigger. While the
transcription runs, the menu bar icon shows an ellipsis.

The transient pill appears once `bin/sayit` has confirmed the recorder is
running, about 0.3 s after the press. Its bars move once audio actually
arrives, which, with a Bluetooth headset that macOS is still switching, can be
a moment later — speak when the bars respond.

**Placing it.** A resident, unlocked pill can be dragged at any time and saves
its position when you drag it. Otherwise choose **Place Indicator** in Sayit's menu,
drag the pill, and choose **Done Placing**. The position is kept in
`~/.config/sayit/overlay-position`, the same file and format as on Linux:
points from the top-left corner of the main screen. A position on a screen that
is no longer attached falls back to the default, bottom centre, 48 points above
the bottom of the visible area.

`INDICATOR_EXCLUDE_FROM_CAPTURE=1`, the default, asks macOS to leave the pill
out of screenshots, recordings and screen shares. On recent macOS versions that
request is **best effort**: a capture may show the pill anyway. You always see
it yourself.

## The menu bar item

The icon is the state at a glance:

| Icon | Meaning |
| --- | --- |
| Waveform | Ready |
| Red filled waveform | Recording |
| Ellipsis | Transcribing; the text is pasted when it ends |
| Warning triangle, outline | The trigger is not armed (no Accessibility yet), or the microphone is denied |
| Orange filled triangle | A problem was reported in the last eight seconds |

The menu itself:

- **The status line** — the last thing `bin/sayit` reported: `Recording`,
  `Transcribing...`, `Done (12 words)`, `Empty result`,
  `Recording failed to start: no input device matches …`,
  `Not pasted: … press Cmd+V`, `Transcription failed: …`, and so on. An outcome
  older than a minute says how old it is (`· 5 min ago`). `bin/sayit` marks
  problems with a second line in `sayit.status` (`warn` or `error`), which is
  what turns the icon orange.
- **The hint line** — how to dictate, such as `Hold or tap F18 to dictate · Esc
  cancels`, or what is stopping you: `Waiting for the Accessibility
  permission`, an unparsable `TRIGGER_BUTTON`. While probing, the last three
  transitions.
- **Allow Accessibility…** and **Allow Microphone…**, shown only when needed.
- **Place Indicator** / **Done Placing**.
- **Probe Trigger**, checked while the probe runs.
- **Reload Settings** — re-reads `.env`: the trigger, its mode and
  suppression, and the indicator settings. The `bin/` scripts read `.env` on
  every run and need no reload.
- **Quit Sayit** — a clean exit, after which launchd leaves Sayit stopped until
  your next login. Start it again with
  `launchctl kickstart gui/$(id -u)/io.github.mrtorriz.sayit.agent`.

**There are no notifications on macOS.** Notification Center keeps every
notification, and a "Done" message carrying the start of the dictation would
leave a snippet of each one there. The status line is the replacement, and it
shows `Done (12 words)` without the text.

## The daemon and the LaunchAgents

`mac/install.sh` writes two LaunchAgents into `~/Library/LaunchAgents`, the
counterparts of the Linux systemd user units:

| Label | Runs | Kept alive |
| --- | --- | --- |
| `io.github.mrtorriz.sayit.daemon` | `bin/sayit-daemon`, which starts `whisper-server` on `127.0.0.1` at `DAEMON_PORT` | Always restarted, at most once every 10 s |
| `io.github.mrtorriz.sayit.agent` | `Sayit.app` | Restarted after a crash, not after Quit |

Both start at login and run only in the graphical session — not in an SSH
login. Both run as `ProcessType` `Interactive`, because the default lets macOS
throttle a background job, and a dictation tool feels that as latency. Both put
Homebrew's bash first on `PATH`.

```bash
./bin/sayit doctor                                                      # both agents' state, and whether the daemon answers
launchctl print gui/$(id -u)/io.github.mrtorriz.sayit.daemon            # everything launchd knows; look for "state = running"
launchctl kickstart -k gui/$(id -u)/io.github.mrtorriz.sayit.daemon     # restart the daemon
launchctl kickstart -k gui/$(id -u)/io.github.mrtorriz.sayit.agent      # restart Sayit
launchctl bootout gui/$(id -u)/io.github.mrtorriz.sayit.daemon          # stop it until the next login or ./install.sh
```

The model, VAD model, threads, beam size and port are fixed when the server
starts: after changing `MODEL_PATH`, `VAD_MODEL`, `THREADS`, `BEAM`,
`DAEMON_PORT` or `WHISPER_SERVER`, restart the daemon. Language, initial prompt
and the four VAD tuning settings travel with each request and need no restart.

**The daemon listens under a private path.** `whisper-server` answers any web
page (`Access-Control-Allow-Origin: *`) and has an unauthenticated `/load` that
swaps the model, or exits when handed a file that is not one. A page in your
browser can reach `127.0.0.1`, so `bin/sayit-daemon` starts the server under a
random path prefix, new at every start, and writes it, readable only by you, to
`sayit-daemon.path` in the per-user temporary directory, where
`bin/sayit-transcribe` and the doctor read it.

`bin/sayit-transcribe` tries the daemon first and falls back to `whisper-cli`
**only** on a transport failure, the same contract as everywhere else. A
fallback says so in the status line, since it takes seconds longer. Expect
two delays that are not faults: the large model takes a few seconds to load
after login, during which dictation uses the slower cold path; and the very
first transcription after a whisper.cpp build takes several seconds longer
(8 s on the reference machine) while Metal compiles its pipelines, once.

**Logs** live in `~/Library/Logs/sayit/`:

- `daemon.log` — `whisper-server`'s output: request and timing lines. sayit
  starts it without `--print-realtime`, the option that would print transcribed
  text. `bin/sayit-daemon`'s own errors — a missing model or binary — land
  there too. A file past 1 MiB is moved to `daemon.log.1` when the daemon
  starts, and only then; launchd itself rotates nothing.
- `agent.log` — error messages from Sayit and from the `bin/` commands it
  starts.

## Text injection

`sayit-paste` puts the text on the clipboard and posts `Cmd+V`. That is what
`INJECT_METHOD=auto`, the default, means on macOS: `Cmd+V` works in every
application, terminals included, while Unicode key events are not honoured by
all of them. Around the paste:

- The previous clipboard is saved with **every item and every type** — rich
  text, images, file references — and restored after `PASTE_RESTORE_DELAY`
  seconds (1.0 by default), but only if the clipboard still holds the
  dictation. Anything you copy in the meantime is never overwritten.
- The dictation is marked with the nspasteboard.org types
  `org.nspasteboard.TransientType` and
  `org.nspasteboard.AutoGeneratedType`, so clipboard managers that follow that
  convention leave it out of their history.
- A clipboard that a password manager marked `org.nspasteboard.ConcealedType`
  or `TransientType` is never read and never put back; the dictation then stays
  on the clipboard. So does a clipboard larger than 64 MiB, which is not worth
  a round trip.
- The paste chord is `Cmd` plus whichever key types "v" with `Cmd` held in the
  current keyboard layout, so Dvorak, Workman and "Dvorak - QWERTY Cmd" work;
  the ANSI V position is the fallback. It carries `Cmd` and nothing else, so a
  modifier still held from the trigger cannot turn it into another shortcut,
  and it is stamped with sayit's own signature, so the trigger never mistakes
  it for you.
- Pastes take turns through a lock file in the run directory, so a second
  dictation inside the first one's restore window cannot mistake the first
  dictation for your clipboard and lose the real one.
- While Secure Input is on, the keystroke may be swallowed, so the dictation
  stays on the clipboard instead of being restored away.
- Without the Accessibility permission no keystroke can be sent at all. The
  text is left on the clipboard, the status line says `Injection failed`, and
  `Cmd+V` pastes it.

`INJECT_METHOD=type` sends the characters themselves as Unicode key events,
20 UTF-16 units at a time and never splitting a surrogate pair, and never
touches the clipboard. Some applications ignore such events; `clipboard` is the
same as `auto`. `INJECT_CLIPBOARD_THRESHOLD` is not used on macOS.

```bash
./bin/sayit-inject "text"    # deliver text to the focused window (Terminal's Accessibility)
```

## History and statistics

The commands are the Linux ones:

```bash
./bin/sayit-history              # latest 20 transcriptions
./bin/sayit-history --stat 7d    # words, speaking WPM, time saved vs typing
./bin/sayit-history --copy 175   # copy entry 175 to the clipboard (pbcopy)
./bin/sayit-history --inject 175 # re-inject entry 175 into the focused window
```

History lives in `~/.local/share/sayit/history.jsonl` and the wordlist in
`~/.config/sayit/wordlist.tsv` — the XDG paths, as on Linux, not `~/Library`.
The format is the same on all three platforms, so a history file is portable.
`--copy` goes through `pbcopy` without the transient markers above, and
`--inject` runs under Terminal's Accessibility permission.

## Upgrading

```bash
git pull
./install.sh              # rebuilds Sayit.app only if its sources changed
./install.sh --rebuild    # also rebuild whisper.cpp at the pinned release
```

`mac/install.sh` rebuilds the app only when a hash over the Swift sources, the
repository path, the signing identity and the script's own build recipe — the
compile, bundle and sign steps — has changed; `mac/install.sh --rebuild` forces it.

**Upgrades keep the permissions.** macOS ties the Microphone and Accessibility
grants to the app's designated requirement. On the first install
`mac/install.sh` creates a self-signed code-signing identity, `Sayit Local
Signing`, in a keychain of its own (`~/Library/Keychains/sayit-signing.keychain-db`,
no password, kept out of the keychain search list), and signs every build with
it. The requirement is then "this identifier and this certificate" — the same
for every build. The key signs only Sayit, but like any developer's signing key
on their own Mac, anything running as you could use it too.

`SAYIT_SIGN_IDENTITY` names another identity from
`security find-identity -v -p codesigning`, or `-` for an ad-hoc signature,
whose requirement is the build's own hash: every rebuild then needs both grants
again. Whenever the requirement changes — an ad-hoc build, or the first build
with a new identity — `mac/install.sh` resets Sayit's old entries with
`tccutil`, so macOS asks afresh instead of showing a switch that is on but no
longer applies.

The repository path is recorded in the app and in both LaunchAgents. After
moving your clone, run `./install.sh` again from the new place.
`SAYIT_APP_DIR` installs the app somewhere other than `~/Applications`. Set it
for `./bin/sayit doctor` as well, which otherwise looks only in
`~/Applications` and `/Applications`.

## Uninstalling

```bash
mac/install.sh --uninstall
```

This unloads both LaunchAgents, removes their plists, and removes
`~/Applications/Sayit.app` — only if its bundle identifier is Sayit's. It
leaves alone the models, `.env`, your history and the wordlist, and also:

- the whisper.cpp build in `~/.local/src/whisper.cpp` and the
  `~/.local/bin/whisper-cli` link;
- the logs in `~/Library/Logs/sayit/`;
- the Homebrew formulae;
- Sayit's entries under Privacy & Security. Remove them there, or with
  `tccutil reset Accessibility io.github.mrtorriz.sayit` and
  `tccutil reset Microphone io.github.mrtorriz.sayit`.

## Verifying the installation

```bash
./bin/test-pipeline     # synthetic voice through the whole transcription path
./bin/sayit doctor      # read-only check of everything around it
```

On macOS `test-pipeline` synthesises its sentence with the system's `say`,
using the first installed voice for `SPEECH_LANGUAGE` (Alva, for Swedish), and
converts it with `afconvert` to the 16 kHz mono format the recorder produces.
It opens no microphone and needs neither `Sayit.app` nor any permission, so a
pass means the model, the daemon or CLI, and the wordlist all work. Without a
voice for the language it says so; add one under System Settings >
Accessibility > Spoken Content.

The doctor never changes anything: no recording, no keystroke, no clipboard
access, no `launchctl` load or unload. It reports the bash version, the
whisper.cpp build and its backend, the model the daemon and the fallback will
load, both LaunchAgents and whether the daemon answers, `Sayit.app`'s helpers,
the permissions Sayit reported, the input devices and what `AUDIO_SOURCE`
resolves to, whether Secure Input is on, and leftover state. It never prints
`.env`, the wordlist or dictated text, and reports `INITIAL_PROMPT` and
`SUPPRESS_REGEX` only as set or empty. It does print resolved paths, which
contain your user name, and device names. Read it before pasting it anywhere.

The real test comes last: hold the trigger, speak, release.

If something is wrong, [Troubleshooting](TROUBLESHOOTING.md#macos) has the
symptom table.

## Known platform limits

- Keyboard triggers are invisible while Secure Input is on, and a paste may be
  blocked then; the text stays on the clipboard. Mouse-button triggers are
  unaffected.
- Keeping the pill out of screen captures is best effort on recent macOS.
- Transient audio lives in the per-user temporary directory, which is on disk,
  not in RAM. The WAV is deleted after transcription, and files a crash left
  behind are swept, once they are an hour old, when the next recording starts.
- Permissions belong to the app's signature. With the local signing identity
  they survive rebuilds; with `SAYIT_SIGN_IDENTITY=-` (ad hoc) every rebuild
  costs both grants.
- Only Apple Silicon has been tested.

Next: [Configuration](CONFIGURATION.md) for every setting, or
[Architecture](ARCHITECTURE.md) for why the pipeline is built this way.
