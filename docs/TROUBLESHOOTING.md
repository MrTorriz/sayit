[← README](../README.md) · [Install: Linux](INSTALL-LINUX.md) · [Windows](INSTALL-WINDOWS.md) · [macOS](INSTALL-MACOS.md) · [Configuration](CONFIGURATION.md) · **Troubleshooting** · [Performance](PERFORMANCE.md) · [Architecture](ARCHITECTURE.md)

# Troubleshooting

Start with the doctor for your platform. It resolves the microphone sayit will
actually record from, reports the daemon and any leftover state, and prints the
command that fixes what it finds rather than running it.

```bash
./bin/sayit doctor            # Linux and macOS; or: ./bin/sayit-doctor --quiet
```

```powershell
.\win\sayit-doctor.ps1        # or: .\win\sayit-doctor.ps1 -Quiet
```

The Linux doctor changes nothing at all: it starts no recording, opens no
capture stream and writes no file. It does source `.env` as shell, which is how
the config format works on Linux. The macOS doctor is read-only in the same
way — no recording, no keystroke, no clipboard access, no `launchctl` load or
unload — and also sources `.env`. The Windows doctor opens no capture stream
and executes none of the fixes it suggests, but it does create its own state
directories on first run.

None of them dumps `.env`, the wordlist or dictated text, and none prints the
values of `INITIAL_PROMPT` or `SUPPRESS_REGEX`. All of them print resolved
local paths — on Windows and macOS normally including your user name — plus
device names, endpoint IDs and most setting values. Read the output before
posting it.

- [Linux](#linux)
- [Windows](#windows)
- [macOS](#macos)
- [All platforms](#all-platforms)

## Linux

| Problem | Fix |
| --- | --- |
| `pw-record: command not found` | Install your distribution's PipeWire tools (`pipewire-utils`, `pipewire-bin` or `pipewire`) |
| Vulkan errors during the build | Install the Vulkan headers, loader and `glslc`, or accept the CPU-only build |
| "Transcription failed: ..." notification | The error class is in the notification; details are in `$XDG_RUNTIME_DIR/sayit-last-error.log` |
| Empty result | Verify the microphone directly: `pw-record --rate 16000 -c 1 -F s16 test.wav`, Ctrl+C, then `paplay test.wav` |
| High latency | Switch to the `small` model, or enable the daemon |
| Text does not appear | On KWin, `wtype` fails because there is no virtual-keyboard protocol. Set up `ydotool.service` — see [Text injection](INSTALL-LINUX.md#text-injection-on-kwinwayland-ydotool) |
| `Compositor does not support the virtual keyboard protocol` | You are on KWin/Wayland. Use the ydotool injection path |
| "Injection failed" notification | `systemctl status ydotool` and `ls -l /run/.ydotool_socket` — the socket must be owned by your user. The text is recoverable with `sayit-history --inject` |
| `Model missing` from `sayit-transcribe` | Run `./install.sh`, or `./install.sh --skip-packages --skip-build` if only the model is missing |
| whisper.cpp broken after an OS upgrade | `./install.sh --rebuild` |
| No notifications | Install `libnotify`, which provides `notify-send` |
| Recording indicator never disappears | `./bin/sayit-indicator hide` removes it manually |
| No meter at all while recording | Check `RECORDING_METER` in `.env`. `./bin/sayit-overlay --check` reports whether the overlay style can run here |
| The meter falls back to the Plasma OSD instead of the pill | The overlay needs a Wayland session with layer-shell plus `python3-gobject`, GTK 3 and `gtk-layer-shell` — the optional packages `install.sh` lists |
| The meter shows a waveform or a generic icon instead of the mark | Install the theme icons: `./install.sh --skip-packages --skip-build --skip-model` |
| The pill sits in the wrong place | `./bin/sayit-overlay --place`, drag it, press Enter. `--print-position` reports where it is |
| Recording starts but never stops | Check `$XDG_RUNTIME_DIR/sayit.session` — it must name a live `pw-record` process |
| `AUDIO_SOURCE` stopped working after a reboot | You configured a numeric PipeWire id. Use the node name from `pactl list sources short`; the doctor says so explicitly |
| The USB mic is plugged in but has no source | Its card is in an output-only profile. The doctor prints the `pactl set-card-profile` line that fixes it, whether the source is named by `AUDIO_SOURCE` or reached as the PipeWire default |
| The Bluetooth headset records from the wrong mic | Verify the headset is connected, then try `./bin/sayit-bt up` — it should print a `bluez_input....` name |
| The headset is stuck in phone-quality audio | `./bin/sayit-bt down` forces A2DP back after an abnormally aborted recording |
| The Solaar button does not trigger dictation | `systemctl --user status solaar.service` — Solaar must be running in your graphical session |
| Anything else in the recording path | `./bin/sayit doctor` |

`./bin/test-pipeline` is the end-to-end check: it synthesises a sentence with
`espeak-ng` and runs it through the real transcription path. No microphone
involved.

## Windows

| Problem | Fix |
| --- | --- |
| `whisper-cli missing` or `whisper-server missing`, naming a `$HOME/...` path | Your `.env` still holds the Linux defaults. Set `WHISPER_CLI` and `WHISPER_SERVER` to the built binaries, or remove the two lines |
| The trigger button does nothing | `.\win\sayit-trigger.ps1 -Probe`. No event at all usually means the mouse diverts the button in firmware — map it in the vendor utility. On a Bluetooth LE Logitech mouse, try `.\win\sayit-rawprobe.ps1`. Both probes log everything they see to `%LOCALAPPDATA%\sayit\run\` and do not clean up — delete `trigger-probe.log` and `rawprobe.log` when you are done |
| The trigger stops working after a while | The OS silently removes a hook that runs too slowly; the trigger re-arms itself every 30 s. If it stays dead, restart `sayit-trigger.ps1` |
| Text does not appear, and nothing reported a failure | The focused window runs elevated. The text is on the clipboard — press `Ctrl+V` |
| Nothing is transcribed even though `-List` shows the mic | `.\win\sayit-doctor.ps1`. A digitally silent capture is reported distinctly, as exit code 2 from `sayit-record.ps1` |
| Transcription is slow | Look for `ggml-vulkan.dll` beside the binaries. Without it the build is CPU-only: install the Vulkan SDK and re-run `.\win\install.ps1 -Rebuild` |
| Every dictation reloads the model | Nothing answers on `127.0.0.1:DAEMON_PORT`. Run `.\win\sayit-daemon.ps1 start` |
| The indicator is invisible in a game | It cannot appear over a true exclusive-fullscreen application, nor on the UAC secure desktop. No setting changes this |
| The indicator sits in the wrong place | `.\win\sayit-indicator.ps1 place`, drag it, press Enter |
| Recording starts but never stops | `.\win\sayit-doctor.ps1` reports stale sessions and orphaned recorders and prints the command to clear them. A recorder also stops by itself at `MAX_RECORD_SECONDS` |
| Non-ASCII characters come out mangled | Use the scripts as they are; each entry point sets UTF-8 output itself. A wrapper that re-encodes stdout will corrupt them |
| `Should -Be` behaves strangely when running the tests | You are on the in-box Pester 3.4.0. `Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck` |
| The scheduled task shows `LastTaskResult 0` | Normal. The task's action is a shim that starts the supervisor and exits, so every minute repeat finishes cleanly |
| The scheduled task shows `LastTaskResult 0x800710E0` | Not a failure, but it means the task predates the `wscript` shim and runs the supervisor directly. Re-run `.\win\install.ps1` and let it replace the task |
| Anything else in the recording path | `.\win\sayit-doctor.ps1` |

## macOS

The menu bar item is the first place to look: its first line is the last
status `bin/sayit` reported, and its second says what Sayit is listening for —
or what is stopping it. The error log is in the run directory:

```bash
cat "$(getconf DARWIN_USER_TEMP_DIR)/sayit-last-error.log"    # error classes, never text
```

| Problem | Fix |
| --- | --- |
| Pressing the trigger does nothing, and the menu bar icon is an outlined triangle | Sayit has no Accessibility permission, so its event tap is not installed; the menu's second line says `Waiting for the Accessibility permission`. Turn Sayit on under System Settings > Privacy & Security > Accessibility, or use **Allow Accessibility…** in the menu. The trigger arms within two seconds, without a restart |
| The trigger does nothing, and the icon looks normal | Read the menu's second line: it names the button Sayit is listening for, or says `TRIGGER_BUTTON="…" is not understood`. A `.env` made from the template carries `XBUTTON2`, the forward mouse button. Choose **Probe Trigger** and press your button. No line at all means Logi Options+ or another utility still keeps the button to itself: Options+'s Back, Forward and gesture presets are macOS gestures that never reach Sayit. Give the button the generic mouse-button action (see [Logi Options+](INSTALL-MACOS.md#a-logitech-mouse-logi-options)), or a keystroke. After editing `.env`, choose **Reload Settings** |
| A keyboard trigger works everywhere except in password fields, or in Terminal | Secure Input: while it is on — a password field, Terminal > Secure Keyboard Entry — keyboard events reach no event tap. `./bin/sayit doctor` warns when it is on. A mouse-button trigger is unaffected |
| The probe shows `modifier KEY61`, but `TRIGGER_BUTTON="KEY61"` never fires | A modifier key is named, not numbered: `RIGHTOPTION`, `LEFTCOMMAND` and so on. See [the trigger table](INSTALL-MACOS.md#choosing-the-trigger) |
| A short press starts a recording that does not stop on release | `TRIGGER_MODE=auto` latches a press shorter than 0.4 s; the next press stops it. Hold a little longer, or set `TRIGGER_MODE=hold` |
| The button also does its usual job — the browser goes forward | `TRIGGER_SUPPRESS=0` is set; make it `1` and choose **Reload Settings**. A modifier key used on its own as the trigger is never swallowed, by design |
| No text appears, and the status line says `Not pasted: Sayit needs the Accessibility permission` | No `Cmd+V` could be sent. The text is on the clipboard: press `Cmd+V`, then grant Accessibility as above. `./bin/sayit-history --inject N` re-sends any entry |
| The status line says `Secure Input is on, so the paste may have been blocked` | A password field or Terminal's Secure Keyboard Entry was active. The text stays on the clipboard: press `Cmd+V` |
| Dictation works from the trigger but not from Terminal, or the other way round | They hold different permissions: the trigger runs under `Sayit.app`'s grants, a command typed in Terminal under Terminal's. Grant the one that is missing |
| Every result is empty, or the error log says `digitally silent capture (peak 0)` | The recording was digital silence. Most often the Microphone permission is denied — for Sayit, or for Terminal on a manual run; `./bin/sayit doctor` reports Sayit's. Otherwise the input is muted or turned down under System Settings > Sound > Input, or `AUDIO_SOURCE` selects the wrong device: `~/Applications/Sayit.app/Contents/MacOS/sayit-rec --list` |
| `Recording failed to start: …` | `sayit-rec` exited at once and the status line carries its reason: `AUDIO_SOURCE` matches no input device (the available ones are listed — a USB microphone that is unplugged, or a headset that is not connected), microphone access is denied, or `sayit-rec missing — run ./install.sh`. An empty `AUDIO_SOURCE` follows the input chosen under System Settings > Sound |
| A Bluetooth headset sounds like a phone call while you dictate | macOS moves the headset to its call profile when its microphone is opened, and back afterwards. Name a USB microphone in `AUDIO_SOURCE` and the headset is left alone |
| Every dictation is slow, or the doctor says the daemon does not answer | `launchctl print gui/$(id -u)/io.github.mrtorriz.sayit.daemon` and `tail ~/Library/Logs/sayit/daemon.log`. Right after login the large model takes a few seconds to load, and the first transcription after a whisper.cpp build waits while Metal compiles its pipelines. A missing model or binary is reported in the same log. Restart it with `launchctl kickstart -k gui/$(id -u)/io.github.mrtorriz.sayit.daemon` |
| Sayit asks for its permissions again after an upgrade, or the trigger and the paste stop working after one | The signature's requirement changed — an ad-hoc build (`SAYIT_SIGN_IDENTITY=-`), or the first build with the local signing identity — and the grants belonged to the old one. `mac/install.sh` resets the old entries so macOS asks again; allow both. If a switch is on but does not take, remove Sayit there (−) and let it ask afresh. See [Upgrading](INSTALL-MACOS.md#upgrading) |
| The pill never appears | Check `RECORDING_INDICATOR` in `.env`. The transient pill shows only while recording, from about 0.3 s after the press; `INDICATOR_RESIDENT=1` keeps it up. **Place Indicator** in the menu shows it wherever it is and lets you move it. After editing `.env`, choose **Reload Settings**. Missing from a screenshot or a screen share is `INDICATOR_EXCLUDE_FROM_CAPTURE=1` doing its job |
| A long dictation was pasted before you let go, and the status says `the recording had already stopped` | The recording reached `MAX_RECORD_SECONDS` (120 s by default), or the microphone went away. Sayit stops such a recording within a second and transcribes what was captured, rather than waiting for the next press. Raise `MAX_RECORD_SECONDS` for longer dictations, or `0` for no cap |
| Sayit is missing from the menu bar | After **Quit Sayit** it stays stopped until the next login: `launchctl kickstart gui/$(id -u)/io.github.mrtorriz.sayit.agent`. Otherwise see `./bin/sayit doctor` and `~/Library/Logs/sayit/agent.log`; `cannot find the sayit repository` means the clone has moved — run `./install.sh` from its new place |
| The doctor says bash is too old, or Homebrew bash is missing | `brew install bash`. The LaunchAgents and Sayit run the scripts under Homebrew's bash; `/bin/bash` is 3.2 and not supported |
| `test-pipeline` says `No system voice for sv` | Add a voice for the language under System Settings > Accessibility > Spoken Content |
| Anything else in the recording path | `./bin/sayit doctor` |

## All platforms

| Problem | Fix |
| --- | --- |
| A history entry looks cut off | The list view shortens long entries to an 80-character budget and marks the cut. `--copy N` / `-Copy N` gives you the full text |
| A dictation is missing from the history entirely | An empty transcription is not recorded. If VAD discarded every segment the run still succeeds with no output — see `VAD_MIN_SPEECH_MS` in [Configuration](CONFIGURATION.md#accuracy-vad-beam-search-initial-prompt-suppression) |
| The end of a sentence is clipped | Raise `VAD_SPEECH_PAD_MS`. It is the only one of the four VAD settings that lengthens the tail |
| The `mark` or `wave` meter stops after two minutes (Linux) | Those two OSD styles have a 120 s safety cap. The default `overlay` style has none and ends with its capture stream |
| A corrupt line in `history.jsonl` | Corrupt lines are skipped and counted; the rest of the history is unaffected. The count goes to stderr, never the content |

Still stuck? Open an issue with the doctor output for your platform. Please do
not paste daemon logs — they are `whisper-server`'s own output and can contain
transcribed text.
