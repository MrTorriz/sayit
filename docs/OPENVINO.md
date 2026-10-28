[README](../README.md) · [Linux installation](INSTALL-LINUX.md) · [Performance](PERFORMANCE.md)

# Optional Turbo engine

This mode runs Whisper large-v3-turbo FP16 locally through OpenVINO. It has been
tested on Fedora 44 with an Intel Core Ultra 9 185H, integrated Arc graphics,
32 GB RAM and Python 3.14. The default whisper.cpp/Vulkan engine remains
available. Windows 11 can use the same server through the PowerShell adapter
described below. Its measurements are separate from the Linux results.

## Windows 11

Complete the base [Windows installation](INSTALL-WINDOWS.md) first. Use Python
3.12 or newer with compatible binary wheels; Python 3.13 was verified. The
installer keeps packages, the model and GPU cache under
`%LOCALAPPDATA%\sayit\openvino`, or `OPENVINO_HOME` when set. It verifies the
configured GPU before downloading the model, checks every model checksum,
and warms up both the model and Silero speech detector. It does not select
the engine or modify the running native server.

```powershell
.\win\install-openvino.ps1
.\win\sayit-engine.ps1 fast
.\win\sayit-engine.ps1 status
.\win\sayit-engine.ps1 accurate
```

`-Python` selects an interpreter; `-ModelSource` reuses an exact model copy
after verifying checksums. The pinned packages must have compatible Windows
wheels. The adapter loads `whisper.dll` and its dependencies from beside the
configured `WHISPER_SERVER`, or uses `WHISPER_LIB` when explicitly set.
The same supported native VAD versions listed below apply.

A successful switch saves `fast` or `accurate` in
`%APPDATA%\sayit\engine-mode`. The existing scheduled logon task starts that
engine through `sayit-daemon.ps1`. Switching is refused during recording or
transcription. Startup waits up to 120 seconds for the expected HTTP health
response. A failed switch restarts the previous engine and leaves the saved
selection unchanged. Switch to `accurate` before updating Turbo packages.

The daemon and CLI fallback retain the existing wordlist and text-injection
path. Silence returns an empty result without invoking the fallback. Requests
that fail use the original local whisper-cli. First compilation is slower
than a warm start; test the model with the installer before selecting it.

See the [Windows comparison](PERFORMANCE.md#windows-openvinoturbo-comparison-2026-09-17).

## Linux installation

First complete the base [Linux installation](INSTALL-LINUX.md), including
microphone access, the trigger and text injection. The optional installer
reuses its Silero model and libwhisper, and the native CLI is the fallback.

You need Python 3.12 or newer with `venv` and `pip`, and the Intel userspace compute driver.
On Fedora the driver package is `intel-compute-runtime`; install it through
dnf. For other distributions, follow the
[Intel compute runtime installation instructions](https://github.com/intel/compute-runtime#installation-options).
Vulkan alone is not enough for this backend. The installer verifies that
OpenVINO can see the configured device before downloading the model.

```bash
./install-openvino.sh
./bin/sayit-engine fast
./bin/sayit-engine status
```

The installer creates a virtual environment under
`${XDG_DATA_HOME:-$HOME/.local/share}/sayit/openvino`, installs pinned packages,
downloads about 1.6 GB of model files and verifies every file's SHA-256. Allow
additional space for packages and the GPU compilation cache. It loads and
warms up the model as a final check, without changing the running service.
The first compilation takes longer than a warm start.

Use `--python /path/to/python3` to select an interpreter. An existing copy of
the exact model can avoid downloads:

```bash
./install-openvino.sh --model-source /path/to/model
```

Copied and cached files receive the same checksum checks as downloads. The
[manifest](../engines/openvino/model-provenance.json) pins the upstream model
revision; Python versions are pinned in
[requirements.txt](../engines/openvino/requirements.txt). Python package
availability depends on the interpreter/platform; a missing compatible wheel
is an installation failure, not a reason to substitute untested versions.

## Select an engine

```bash
./bin/sayit-engine fast       # Whisper large-v3-turbo / OpenVINO
./bin/sayit-engine accurate   # configured GGML model / whisper.cpp
./bin/sayit-engine status     # configured mode and responding engine
```

`accurate` is the compatibility name for the original engine; model errors
differ and the name does not promise it wins on every sentence. `MODEL_PATH`
still selects that engine's model (KB-Whisper-medium by default).

Selection writes only `20-openvino.conf` in the user service's override
directory. A missing base service is created from the shipped template.
Existing service settings are preserved. The selected engine must pass its
health check before the service is enabled for automatic startup after login.
A failed switch restores the previous override. Other override files are left
in place. Keep the checkout at its installed path because the service runs its
scripts directly. Rebooting keeps the selected mode; a new user session starts
the enabled service. Initial model loading still takes time after login.

Finish recording before switching. A shared lock prevents a switch during
recording or transcription. Requests that fail in OpenVINO use the existing
local `whisper-cli` fallback. An empty successful response means no speech was
detected and never starts a second transcription.

## Configuration

Settings live in the checkout's `.env`. Restart the selected service after
changing paths, device or port. Language, prompt and VAD threshold are sent with
each dictation and apply to the next request.

| Setting | Meaning in Turbo mode |
| --- | --- |
| `OPENVINO_HOME` | Runtime/model directory; empty uses the XDG data path above |
| `OPENVINO_DEVICE` | `GPU` by default; `CPU` is available for diagnostics, without a latency claim |
| `WHISPER_LIB` | Optional explicit path to libwhisper; otherwise search beside the resolved `WHISPER_SERVER` binary, then in `../src` and `../lib` |
| `VAD_MODEL` | Required Silero model; empty uses `models/ggml-silero-v5.1.2.bin` in the checkout |
| `DAEMON_PORT` | Local HTTP port, default `9876`; server and client use the same value |
| `SPEECH_LANGUAGE` | Whisper language code or `auto`; default `sv` |
| `INITIAL_PROMPT` | Optional short prompt; an empty value is omitted from the runtime call |
| `VAD_THRESHOLD` | Speech probability threshold, default `0.30` |

The adapter supports the libwhisper VAD context ABI in versions **1.8.4** and
**1.9.2**. The latter is the base installer's pin. Unknown versions fail before
the native VAD initialization call; check the struct/signatures and test
inference before extending that list. Static builds or a custom install layout
need a compatible shared library selected with `WHISPER_LIB`.

Turbo uses greedy decoding (`num_beams=1`). Higher beam counts failed in the
tested GPU runtime, so `.env`'s `BEAM` is reserved for whisper.cpp. `THREADS`,
`MODEL_PATH`, `SAYIT_MODEL` and `SUPPRESS_REGEX` also belong to the native engine
and fallback. The wordlist and optional text cleanup remain client features.

Silero acts as a speech gate: it rejects an entirely silent recording and passes
the whole recording when speech is present. It does not trim word endings.
`VAD_SPEECH_PAD_MS`, `VAD_MIN_SPEECH_MS` and `VAD_MIN_SILENCE_MS` therefore have no
effect on Turbo inference. Silence is tested, but no speech detector guarantees
that arbitrary background sound can never be interpreted as words.

## Updates and recovery

Switch to `accurate` before upgrading the optional packages, then rerun the
installer and select `fast`. After a Python minor-version upgrade, create the
runtime at a new `OPENVINO_HOME` with the new interpreter and run the installer;
do not reuse an environment whose interpreter or binary packages disappeared.
Keep the previous runtime until the replacement has passed its checks.

```bash
./bin/sayit-engine status
journalctl --user -u sayit-daemon.service -n 50
./bin/sayit-openvino --check
./bin/sayit-engine accurate
```

If device detection fails, inspect the Intel compute driver, permissions for
the GPU render device and OpenVINO's supported hardware. If an existing service
has additional overrides, inspect `systemctl --user cat sayit-daemon.service`.
The switcher cannot supersede a later override that replaces `ExecStart`.
Startup checks are bounded to 60 seconds; slow first compilation may require
running `--check` first to populate the cache.

After installation, model inference requires no internet connection. See
[security and data handling](../SECURITY.md#optional-openvino-engine)
and the [paired Swedish measurements](PERFORMANCE.md#linux-openvinoturbo-comparison-2026-09-14).
