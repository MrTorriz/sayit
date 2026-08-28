[← README](../README.md) · [Install: Linux](INSTALL-LINUX.md) · **Windows** · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md) · [Architecture](ARCHITECTURE.md)

# Installing sayit on Windows 11

- [Requirements](#requirements)
- [Installation](#installation)
- [Two things the installer leaves for you](#two-things-the-installer-leaves-for-you)
- [Push-to-talk trigger](#push-to-talk-trigger)
- [Autostart and the warm daemon](#autostart-and-the-warm-daemon)
- [Recording indicator](#recording-indicator)
- [Choosing a microphone](#choosing-a-microphone)
- [Text injection](#text-injection)
- [History and statistics](#history-and-statistics)
- [Verifying the installation](#verifying-the-installation)
- [Known platform limits](#known-platform-limits)

## Requirements

To **run** sayit, nothing needs to be installed. Windows PowerShell 5.1,
.NET Framework 4.8.1, WinForms and the in-box C# compiler all ship in
Windows 11, and the small C# helpers in `win\lib\` are compiled at runtime by
`Add-Type`. There is no third-party runtime, no NuGet package and no Python on
the Windows side.

To **build** whisper.cpp you need:

- `git`
- CMake
- Visual Studio Build Tools with the C++ workload — the `VC.Tools.x86.x64`
  component
- The LunarG Vulkan SDK. Optional, but without it the build is CPU-only, which
  is [dramatically slower](PERFORMANCE.md#windows-reference-machine)

`win\install.ps1` checks for each of these and prints the `winget` command and
the download URL for whatever is missing. It installs nothing without being
told to.

There is no official prebuilt Vulkan binary of whisper.cpp for Windows, so GPU
acceleration means building from source. Integrated-GPU support only arrived in
whisper.cpp v1.8.3, so older third-party "Vulkan" builds silently run on the
CPU. `win\install.ps1` pins v1.9.2, the same release `install.sh` builds on
Linux.

To run the **test suite** you additionally need Pester 5 or newer. Windows
ships Pester 3.4.0, which `win\tests\Invoke-Tests.ps1` refuses to run under.

## Installation

```powershell
git clone https://github.com/MrTorriz/sayit.git
cd sayit
.\win\install.ps1                        # interactive
.\win\install.ps1 -Yes                   # answer yes to every prompt
.\win\install.ps1 -Rebuild               # rebuild at the pinned tag
.\win\install.ps1 -SkipBuild -SkipModel  # only .env, wordlist and autostart
```

What `win\install.ps1` does, in order:

1. Checks `git`, CMake, the MSVC C++ build tools and the Vulkan SDK, and
   reports what is missing together with a `winget` command or a URL.
2. Clones and builds whisper.cpp at the pinned reference into
   `%LOCALAPPDATA%\sayit\whisper.cpp`, configuring `-DGGML_VULKAN=ON` when the
   Vulkan SDK is present (into `build-vulkan\`) and a CPU build otherwise
   (`build-cpu\`), recording what it built in `.sayit-build-info`.
3. Verifies that the model files are present in the repo's `models\` directory
   and prints their sha256 against the published checksums.
4. Creates `.env` from `.env.example` when there is none. An existing `.env` is
   never overwritten; the settings it lacks are listed instead.
5. Seeds the wordlist from `config\wordlist.example.tsv` when there is none.
6. Offers to register a scheduled task named `sayit` that starts
   `win\sayit-autostart.ps1` at logon and keeps it running. If a task from an
   earlier version is already there, it lists what is wrong with it and offers
   to replace it.

| Flag | Effect |
| --- | --- |
| `-Yes` | Answer yes to every prompt |
| `-Rebuild` | Fetch and rebuild whisper.cpp at the pinned reference |
| `-SkipBuild` | Do not build whisper.cpp; only report the build tools |
| `-SkipModel` | Do not check the model files |
| `-NoAutostart` | Do not offer to register the logon task |

Re-running the installer is safe: an existing build, `.env` and wordlist are
left alone, and so is a scheduled task that is already current. A task that is
not — one from a version before the supervisor, or one whose settings would
keep it from starting — is listed with its shortcomings and replaced only if
you say yes. Replacing it stops the running trigger and starts it again
straight away, and the installer reports the pid it ended up with.

To remove the task:

```powershell
Unregister-ScheduledTask -TaskName 'sayit' -Confirm:$false
```

## Two things the installer leaves for you

**The models are not downloaded.** `win\install.ps1` only checks that they are
there and prints their sha256. Put `ggml-kb-whisper-medium-q5_0.bin` and
`ggml-silero-v5.1.2.bin` in the repo's `models\` directory. They are the same
files `install.sh` fetches on Linux, from
[KBLab/kb-whisper-medium](https://huggingface.co/KBLab/kb-whisper-medium)
(`ggml-model-q5_0.bin`) and
[ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad).

Keeping the model somewhere else works at runtime — `MODEL_PATH` and
`VAD_MODEL` are honoured by everything that transcribes — but **the installer
does not read them**. Its model check looks only for those two filenames under
the repo's `models\`, and without them it ends with `Setup is incomplete` and
exit code 1. So with an external model, run the installer with `-SkipModel` and
set `MODEL_PATH` and `VAD_MODEL` in `.env` afterwards:

```powershell
.\win\install.ps1 -SkipModel
```

`.\win\sayit-doctor.ps1` is what confirms the configured paths actually
resolve.

**`WHISPER_CLI` and `WHISPER_SERVER` are rewritten for you.** Their defaults in
`.env.example` are Linux paths, so when `install.ps1` creates `.env` it
replaces both with the build it produced, as `%LOCALAPPDATA%`-relative values.
An existing `.env` is never rewritten; if yours predates this and still holds
the Linux paths, set them yourself. `.\win\sayit-doctor.ps1` tells you whether
the two paths resolve.

## Push-to-talk trigger

`win\sayit-trigger.ps1` holds a global low-level hook and runs `sayit.ps1
start` on press, `sayit.ps1 stop` on release.

```powershell
.\win\sayit-trigger.ps1                  # arm the trigger; hold to talk
.\win\sayit-trigger.ps1 -Probe           # print every button and key transition
.\win\sayit-trigger.ps1 -Probe -Seconds 20
.\win\sayit-trigger.ps1 -Button VK124    # override TRIGGER_BUTTON for this run
```

`TRIGGER_BUTTON` accepts `XBUTTON1` and `XBUTTON2` — the mouse side buttons —
`MIDDLE` for the wheel click, or `VK` followed by a virtual-key code, such as
`VK124` for F13. `-Probe` binds nothing and suppresses nothing: it only reports
what your hardware actually emits, which is the reliable way to find the code a
given mouse sends.

**Some mice never let the button reach Windows.** A thumb button that the mouse
diverts in firmware produces no event at all until the vendor utility maps it
to a real button — to a side button, or to F13. This is the Windows
counterpart of Solaar's divert on Linux, and it is a required setup step on
such hardware, not an edge case. If `-Probe` shows nothing when you press the
button, map it in the vendor utility first.

A second case has its own tool. Some devices — notably Logitech mice paired
over Bluetooth LE and driven by the in-box HID driver — report their thumb
buttons as HID consumer-control usages rather than as mouse buttons, which a
low-level mouse hook cannot see at all. `.\win\sayit-rawprobe.ps1` uses Raw
Input to show those; it accepts `-Seconds` to bound the run. Note that Raw
Input can observe such a button but cannot suppress it.

> Both probes write what they see to disk, and neither cleans up afterwards.
> `-Probe` appends every key and button transition — including keys you press
> in other applications while it runs — to
> `%LOCALAPPDATA%\sayit\run\trigger-probe.log`, and `sayit-rawprobe.ps1`
> appends device IDs and raw HID bytes to
> `%LOCALAPPDATA%\sayit\run\rawprobe.log`. Delete them yourself when you are
> done. The trigger in its normal mode writes neither.

`TRIGGER_SUPPRESS=1`, the default, swallows the trigger so the focused
application never sees it. Without it, binding a thumb button would also
navigate the app back or forward on every dictation.

## Autostart and the warm daemon

`win\install.ps1` offers a scheduled task named `sayit`. It runs one action at
logon — `win\sayit-autostart.ps1` — and that script is what keeps sayit alive
for the rest of the session:

- It starts the warm daemon **without waiting for it**, so the model loads
  while the push-to-talk button is already armed. As two task actions they ran
  strictly in sequence and the button stayed dead for as long as the model took
  to load.
- It runs `sayit-trigger.ps1` again whenever it exits, after a two-second pause
  that doubles up to a minute if the trigger keeps failing immediately.
- It also restarts a trigger that is still running but has stopped answering.
  The trigger writes a heartbeat every five seconds from the same loop that
  pumps the messages its hook rides on, and 90 seconds of silence from that
  loop is a wedge, not a slow machine. A process being alive is not the same as
  the button working.
- It refuses to run twice, and it never starts a second trigger while one
  already holds the hook. Two hooks on the same button start and stop the
  dictation twice per press, which is worse than having none.

Both guards are named mutexes rather than pid files, so Windows releases them
when the process dies however it dies, and there is no stale file to clean up.

The task carries two triggers. **At logon**, which covers a cold boot, a
restart, a fast-startup (hybrid shutdown) boot and logging off and back on,
because every one of them ends in a logon. And a **time trigger that repeats
every minute**, which is what brings the supervisor back if the supervisor
itself dies.

The task's action is not the supervisor itself but a small `wscript.exe` shim,
`win\sayit-autostart.vbs`, which starts it and exits immediately — that is what
keeps a console window from flashing on the desktop at logon. Because the
action exits at once, each minute repeat **finishes cleanly with
`LastTaskResult 0`**, whether or not it had anything to do. A repeat that finds
a live supervisor is turned away by the supervisor's own mutex, not by the
scheduler.

A task registered before that shim existed ran the supervisor directly, and
there the scheduler refused the repeats and recorded `LastTaskResult
0x800710E0`. That value is normal for the older task and not a failure either,
but on a current task it means the task predates the change — re-run
`.\win\install.ps1` and let it replace the task. `.\win\sayit-doctor.ps1`
spells out which of the two you have.

There is deliberately no at-startup trigger. It would run as `SYSTEM` in
session 0, where an input hook reaches no desktop and injected text reaches no
window, and it would need administrator rights to register. Nothing can arm the
push-to-talk button before someone logs in.

None of it needs the task or administrator rights.
`.\win\sayit-autostart.ps1` from a shell does the same job for as long as that
shell lives; `-NoDaemon` skips starting the daemon, `-Seconds` bounds the run,
and `SAYIT_KEEP_CONSOLE=1` in the environment keeps its console visible.
Elevation would make the tool worse, not better: an elevated trigger cannot
type into the non-elevated windows you spend the day in.

To drive the daemon by hand:

```powershell
.\win\sayit-daemon.ps1 start    # start it if it is not already running
.\win\sayit-daemon.ps1 status   # report whether it answers
.\win\sayit-daemon.ps1 stop     # stop it
.\win\sayit-daemon.ps1 run      # run it in the foreground
```

It serves `whisper-server` on `127.0.0.1` at `DAEMON_PORT` with no
authentication, so any local process can reach it — keep it on loopback. The
model, the VAD model, threads and beam size are fixed when the server starts;
change them in `.env` and restart it. Language, initial prompt and the four VAD
tuning settings are sent with each request, so those take effect on the next
dictation with no restart.

`win\sayit-transcribe.ps1` tries the daemon first and falls back to
`whisper-cli` **only** on a transport failure. An empty response from a healthy
daemon means "no speech" and is final. Same contract as the Linux side.

## Recording indicator

`RECORDING_INDICATOR=1`, the default, shows sayit's mark as a small pill above
your other windows while the microphone is open: the bars follow your voice
level and the lamp burns red.

```powershell
.\win\sayit-indicator.ps1 place   # drag it where you want it, Enter or Escape saves
.\win\sayit-indicator.ps1 hide    # tell a running indicator to close
```

The position is remembered in `%APPDATA%\sayit\overlay-position`. The window is
layered, click-through and never activating — `WS_EX_LAYERED`,
`WS_EX_TOOLWINDOW`, `WS_EX_TRANSPARENT`, `WS_EX_NOACTIVATE`, shown with
`SW_SHOWNOACTIVATE` — so it never steals the focus you are dictating into and
clicks pass straight through it. The level comes from the recorder, which has
already computed it, so the microphone is opened only once. The Linux meter
opens a second capture stream instead.

`INDICATOR_SCALE` resizes it; the pill and the mark inside it scale together.

By default the pill is excluded from screen captures, screen shares and
recordings (`INDICATOR_EXCLUDE_FROM_CAPTURE=1`), so a shared screen does not
show that you are dictating. You still see it; the capture does not. This needs
Windows 10 2004 or later — on an older build the request is refused and the
pill is captured as usual. Set it to `0` if you are recording a demo and want
the pill in the video.

## Choosing a microphone

```powershell
.\win\sayit-record.ps1 -List    # capture devices with their endpoint IDs
```

`AUDIO_SOURCE` is empty by default, which records from the Windows default
capture device. To pin one microphone, put its **MMDevice endpoint ID** there —
when your driver reports one. `waveInMessage` is documented to return an
endpoint ID per device, and some drivers return nothing at all; on the machine
this port was developed on, every capture device came back with an empty
endpoint ID. Then the friendly name is the only key you have, and the API
truncates it at 31 characters and it changes when the device is renamed or
reconnected. `-List` and `sayit-doctor.ps1` print what your devices actually
expose, and the doctor says which of the two selectors you are left with.

There is a case no setting can fix. A virtual capture device — a headset
vendor's audio suite, for instance — can be the only capture endpoint Windows
exposes, with the physical microphone behind it not presented as an endpoint at
all. `AUDIO_SOURCE` can then only name the virtual device, and which physical
microphone feeds it is decided in that vendor's own software, not here.

`MAX_RECORD_SECONDS`, 120 by default, bounds how long the microphone can stay
open if whatever started the recording dies before stopping it.

Windows selects the HFP profile itself when an application opens a capture
endpoint, so there is no Bluetooth profile juggling here. That stage exists
only on Linux.

## Text injection

Short text is typed with `SendInput` using `KEYEVENTF_UNICODE`, which sends the
character itself rather than a scan code. That is layout independent by
construction, so Swedish characters need no clipboard workaround here — unlike
the Linux side, where `ydotool` sends US scan codes.

Text longer than `INJECT_CLIPBOARD_THRESHOLD`, 100 characters by default, goes
through the clipboard plus `Ctrl+V` instead, for two Windows-specific reasons:
the OS caps `SendInput` near 5000 characters, and it loses its ordering
guarantee whenever another process holds a low-level keyboard hook — sayit's
own trigger always is one. `INJECT_METHOD` overrides the choice: `type` always
types, `clipboard` always pastes, `auto` decides by length.

When the clipboard is used, the text is marked with
`ExcludeClipboardContentFromMonitorProcessing`,
`CanIncludeInClipboardHistory=0` and `CanUploadToCloudClipboard=0`, so a
dictation stays out of Win+V history and out of cloud sync. The previous
clipboard contents are **not** restored.

When the focused window runs at a higher integrity level, no synthetic input
can reach it, and Windows reports no error for that — the failure would be
invisible. sayit detects the case up front, leaves the text on the clipboard
and tells you to press `Ctrl+V`.

```powershell
.\win\sayit-inject.ps1 "text"              # deliver text to the focused window
.\win\sayit-inject.ps1 -TextFile out.txt   # deliver the contents of a file
```

## History and statistics

```powershell
.\win\sayit-history.ps1                 # latest 20 transcriptions
.\win\sayit-history.ps1 50              # latest 50
.\win\sayit-history.ps1 -Stat           # words, speaking WPM, time saved vs typing
.\win\sayit-history.ps1 -Stat -Period 7d
.\win\sayit-history.ps1 -Copy 175       # copy entry 175 to the clipboard
.\win\sayit-history.ps1 -Inject 175     # re-inject entry 175 into the focused window
.\win\sayit-history.ps1 -Clear          # empty the history
```

History lives in `%LOCALAPPDATA%\sayit\history.jsonl`, in the same format as on
Linux — a history file is portable between the two. Numbering is the absolute
1-based line number, so the same N works with `-Copy` and `-Inject`. Corrupt
lines are skipped and counted; the count goes to stderr, never the content.

## Verifying the installation

```powershell
.\win\sayit-doctor.ps1              # full report
.\win\sayit-doctor.ps1 -Quiet       # only warnings, failures and the summary
.\win\sayit-transcribe.ps1 rec.wav  # transcribe a WAV to stdout
```

The doctor resolves `AUDIO_SOURCE`, reports the backend, the daemon, leftover
sessions and orphaned recorders, and reports the whole autostart chain: whether
the task is registered and enabled, what its last result was and what that
result means, whether the supervisor and the trigger are running, and whether
the daemon answers.

It opens no capture stream and executes none of the fixes it suggests. It does
create its own state directories on first run.

It never dumps `.env`, the wordlist or any dictated text, and reports only
whether `INITIAL_PROMPT` and `SUPPRESS_REGEX` are set, because both hold text
you wrote. It does print resolved paths — which normally contain your user name
— along with capture device names, endpoint IDs and the values of most other
settings. Read it before pasting it into an issue.

The main commands:

```powershell
.\win\sayit.ps1                     # toggle
.\win\sayit.ps1 start               # hold-mode: on button press
.\win\sayit.ps1 stop                # hold-mode: on button release
.\win\sayit.ps1 cancel              # discard the current recording
.\win\sayit.ps1 doctor              # same as sayit-doctor.ps1
```

`toggle` works, but there is no Windows equivalent of the Linux global-hotkey
section: bind it through whatever mechanism you prefer, or use the trigger.

If something is wrong, [Troubleshooting](TROUBLESHOOTING.md#windows) has the
symptom table.

## Known platform limits

- The indicator cannot appear over a true exclusive-fullscreen application, nor
  on the UAC secure desktop. Both are architectural; no setting changes them.
- Injection into an elevated window is impossible from a non-elevated process.
  sayit detects it and leaves the text on the clipboard rather than failing
  silently.
- Transient audio lives in `%LOCALAPPDATA%\sayit\run`, which is on disk.
  Windows has no tmpfs equivalent, so unlike the Linux side it does not vanish
  on reboot. `sayit.ps1` sweeps WAV files older than an hour when the next
  recording starts, and the doctor reports any that are left.
- The models must be fetched by hand — see above.
- There is no benchmark harness on Windows; the figures in
  [Performance](PERFORMANCE.md#windows-reference-machine) are hand
  measurements.

Next: [Configuration](CONFIGURATION.md) for every setting, or
[Architecture](ARCHITECTURE.md) for why the pipeline is built this way.
