[← README](../README.md) · [Install: Linux](INSTALL-LINUX.md) · [Windows](INSTALL-WINDOWS.md) · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md) · **Performance** · [Architecture](ARCHITECTURE.md)

# Performance

Every number on this page was measured on one machine. Treat them as the shape
of the latency, not as a specification — and note which of them are
measurements, which are estimates, and which are arithmetic. Each is labelled.

- [Linux reference machine](#linux-reference-machine)
- [Reproducing the Linux numbers](#reproducing-the-linux-numbers)
- [Windows reference machine](#windows-reference-machine)
- [What is not measured](#what-is-not-measured)
- [Profiling your own dictations](#profiling-your-own-dictations)

## Windows OpenVINO/Turbo comparison (2026-09-17)

Eight public FLEURS Swedish test recordings (218 reference words, three
distinct reference texts) were converted from float WAV to 16 kHz mono PCM16.
Both engines were warm and received the same clips, with engine order
alternated per clip. Measured on Windows 11, Core Ultra 9 185H, Intel Arc iGPU,
driver 32.0.101.8991, Python 3.13.15 and OpenVINO 2026.3.1.

| Engine | Mean | Median | Word errors / reference words |
| --- | ---: | ---: | ---: |
| KB-Whisper-medium q5_0, whisper.cpp/Vulkan, beam 5 | 3.906 s | 4.079 s | 17 / 218 |
| Whisper large-v3-turbo FP16, OpenVINO GPU, greedy | 2.235 s | 2.266 s | 12 / 218 |

Turbo's mean HTTP transcription time was 43% lower in this run. This excludes
recording, wordlist processing and text injection. The small, repeated-text
sample does not establish a general recognition-quality ranking. Scoring
lowercases Unicode word tokens and counts insertions, deletions and
substitutions; number formatting can still count as errors. The Linux run
below used different clips and is not a direct operating-system comparison.

[Individual Windows measurements](openvino-benchmark-windows-20260917.json)
contain clip identifiers, timings and error counts, without audio or text.

## Linux OpenVINO/Turbo comparison (2026-09-14)

A paired comparison used eight Swedish FLEURS clips (142 reference words) on
Fedora 44, an Intel Core Ultra 9 185H with integrated Arc graphics and 32 GB RAM.
Both models were warm, used the same 16 kHz mono recordings, and were called
once per clip in the same comparison run. Timings cover local HTTP requests,
including VAD and inference; recording, wordlist processing and pasting are
outside the measurement.

| Engine | Mean | Median | Word errors / reference words |
| --- | ---: | ---: | ---: |
| KB-Whisper-medium q5_0, whisper.cpp/Vulkan, beam 5 | 3.887 s | 3.974 s | 17 / 142 |
| Whisper large-v3-turbo FP16, OpenVINO GPU, greedy | 2.164 s | 2.237 s | 18 / 142 |

The mean is 44% lower with Turbo in this run. Eight clips do not establish a
general accuracy ranking: strict token scoring counts number formatting and
word splits too. These timings must not be compared directly with the older
2.2-second synthetic sentence below, or described as button-release-to-paste
latency. Windows was not part of that run; its separate results appear above.

The native build reported libwhisper 1.8.4; OpenVINO was 2026.3.1 with the
2026.3.1.0 speech package and Intel compute runtime 26.22.38646.6. The Turbo model
revision and checksums are in the [model manifest](../engines/openvino/model-provenance.json).
[Individual paired measurements](openvino-benchmark-20260914.json) contain
only clip identifiers, timings and error counts, with no personal audio or text.
The model's language support does not imply equal accuracy for every language;
this comparison covers Swedish only.

## Linux reference machine

Measured with the bundled harness ([`tests/benchmark.sh`](../tests/benchmark.sh))
on an Intel Core Ultra 9 185H with Intel Arc integrated graphics via Vulkan,
Fedora 44, `kb-whisper-medium` q5_0 with Silero VAD, on 2026-08-20. The harness
times `sayit-transcribe` end to end — the HTTP round trip or the CLI, token
cleanup and wordlist replacement — against a dedicated `whisper-server`
instance, using synthetic 16 kHz Swedish speech. 25 repetitions per warm speech
scenario, 10 for silence and the cold fallback.

| Scenario (audio length) | n | median | p95 | max |
| --- | --: | --: | --: | --: |
| Warm daemon — short sentence (2.2 s) | 25 | 1.62 s | 1.64 s | 1.64 s |
| Warm daemon — medium (8.7 s) | 25 | 3.12 s | 3.28 s | 3.41 s |
| Warm daemon — long (20.8 s) | 25 | 6.41 s | 6.67 s | 6.74 s |
| Warm daemon — silence (2.0 s) | 10 | 0.06 s | 0.09 s | 0.09 s |
| Cold `whisper-cli` fallback — short | 10 | 2.65 s | 2.71 s | 2.71 s |
| Cold `whisper-cli` fallback — medium | 10 | 4.27 s | 4.37 s | 4.37 s |
| Daemon model load (service start) | 1 | 0.95 s | — | — |
| Wedged server (SIGSTOP), incl. fallback | 3 | 14.8 s | — | 14.9 s |

What the rows mean:

- **Warm versus cold.** The daemon removes the per-call model load entirely.
  The cold rows are the true cost of the `whisper-cli` fallback path, roughly a
  second more per dictation.
- **Silence is cheap.** An empty transcription from a healthy daemon is
  accepted as authoritative and never triggers a redundant cold re-run.
- **The deadline.** A daemon request times out after `audio seconds + 10 s`,
  with a 2 s connect timeout, and then falls back to the CLI. That is the
  14.8 s in the last row: a wedged server cannot stall a short dictation
  indefinitely.
- **Profiling overhead** with `SAYIT_PROFILE=1` is below 1%.

## Reproducing the Linux numbers

```bash
BENCH_MODEL=models/ggml-kb-whisper-medium-q5_0.bin \
BENCH_VAD=models/ggml-silero-v5.1.2.bin \
./tests/benchmark.sh
```

`BENCH_VAD` matters: it is empty by default, and empty means **VAD off**. The
figures above were measured with Silero VAD on, so leaving it unset measures
something else.

Add `BENCH_STALL=1` for the wedged-server row — the harness only SIGSTOPs the
server when asked to.

Other harness controls: `BENCH_PORT` (default 19876 — the harness starts its
own server and never touches a running daemon), `BENCH_DIR` and `BENCH_REPS`.
The harness needs `espeak-ng`, `ffmpeg`, `python3`, `curl`, and a built
whisper.cpp with a model.

## Windows reference machine

The bats harness is bash and does not run on Windows, so there is no
equivalent harness here. These numbers come from whisper.cpp's own
`whisper-bench` and from sayit's per-stage profiling, on an Intel Core Ultra 9
185H with Intel Arc integrated graphics, Windows 11 build 26200,
`kb-whisper-medium` q5_0 with Silero VAD, on 2026-08-22.

Encode time, three repetitions interleaved with cooldowns:

| Backend | run 1 | run 2 | run 3 | median |
| --- | --: | --: | --: | --: |
| Vulkan on the Arc integrated GPU | 723.7 ms | 676.0 ms | 957.7 ms | **723.7 ms** |
| CPU with OpenBLAS, 6 threads | 8953.0 ms | 9888.4 ms | 10340.4 ms | **9888.4 ms** |

End to end, from releasing the button to the text appearing, three dictations
with `SAYIT_PROFILE=1`:

| Dictation | 1 | 2 | 3 | median |
| --- | --: | --: | --: | --: |
| Release to text | 2.37 s | 4.81 s | 2.47 s | **2.47 s** |

Notes:

- **Vulkan is about 13.7x faster than the CPU build on encode.** Decode per
  step is 16.1-21.0 ms on Vulkan against 29.8-33.9 ms on CPU. The CPU figures
  degrade monotonically across the three runs as the laptop heats up; the
  Vulkan figures stay flat.
- **Getting Vulkan at all requires building from source**, which is why the
  Windows install is more work than the Linux one. The reasons are in
  [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md#requirements).
- **Stage breakdown across those three dictations**: the daemon round trip took
  1.18-2.90 s, wordlist replacement 0.02 s, injection 0.18 s and stopping the
  recorder about 0.2 s. Daemon model load at service start: 2.63 s.
- **Three dictations is not 25.** These are hand measurements, unlike the Linux
  table. Read them as an order of magnitude.

### Two costs removed by not spawning PowerShell

Starting a second PowerShell to deliver the text cost about a second per
dictation, roughly a quarter of the release-to-text latency, so `sayit.ps1`
dot-sources `lib\inject.ps1` and injects in-process. Spawning one to apply the
wordlist cost about 0.8 s, a fifth of the total, so the wordlist engine lives
in `lib\common.ps1` and `sayit-transcribe.ps1` calls it directly. The separate
`sayit-inject.ps1` and `sayit-wordlist.ps1` front ends remain for manual use.

## What is not measured

- **Microphone capture and the Bluetooth profile switch** are outside the
  Linux harness. On a Bluetooth headset the A2DP to HFP switch happens
  synchronously at press time and takes roughly 0.5-2.5 s before capture
  starts. That is an estimate, not a measurement — the recording indicator
  appears when the mic is actually live, which is the reliable signal.
- **End-to-end "release to text" on Linux** adds recorder shutdown, Bluetooth
  profile restore and clipboard injection on top of the warm figures —
  typically a few hundred milliseconds, of which clipboard injection is on the
  order of 0.1 s. Estimate.
- **`large` versus `medium` latency.** Not measured on either platform. See
  [Choosing a model size](CONFIGURATION.md#choosing-a-model-size) for the
  arithmetic, which is arithmetic and says so.

## Profiling your own dictations

Per-stage latency profiling of real dictations is built in on both platforms.
Set `SAYIT_PROFILE=1` and read the CSV:

- Linux: `$XDG_RUNTIME_DIR/sayit-profile.csv`
- Windows: `%LOCALAPPDATA%\sayit\run\sayit-profile.csv`

The columns are run id, wall clock, monotonic uptime, stage name and a numeric
extra. Never dictated text.
