#!/usr/bin/env bash
# benchmark.sh — reproducible latency benchmark for the transcription path
#
# Usage:
#   BENCH_MODEL=/path/to/ggml-model.bin ./tests/benchmark.sh
#
# Environment:
#   BENCH_MODEL   (required) GGML Whisper model to benchmark
#   BENCH_VAD     (optional) Silero VAD model path; empty = VAD off
#   BENCH_PORT    test whisper-server port          (default 19876)
#   BENCH_DIR     working/results directory         (default $XDG_DATA_HOME/sayit-bench)
#   BENCH_REPS    repetitions per warm scenario     (default 25)
#   BENCH_STALL   1 = also demonstrate the deadline cap by SIGSTOPping the
#                 TEST server for a few reps        (default 0)
#   WHISPER_SERVER / WHISPER_CLI  binaries          (default install locations)
#
# What it measures (wall time around bin/sayit-transcribe, monotonic-checked):
#   warm-short/-medium/-long   warm daemon, three synthetic Swedish utterances
#   warm-silence               warm daemon, 2 s of digital silence
#   cold-short/-medium         daemon unreachable -> whisper-cli cold start
#   server-load                test-server spawn -> port accepting connections
#   profile-overhead           warm-short with SAYIT_PROFILE=1 vs unset
#
# Privacy/safety by construction:
#   - starts its OWN whisper-server on BENCH_PORT; never touches a daemon on
#     the default port
#   - synthetic espeak-ng audio only; WORDLIST is pointed at a non-existent
#     file so no personal wordlist is ever read; no .env is sourced unless
#     the repo copy has one
#   - all artifacts stay under BENCH_DIR (never inside the repo)
#
# Requirements: espeak-ng, ffmpeg, python3, curl, a built whisper.cpp.
#
# Exit codes:
#   0  Benchmark completed
#   1  Missing requirement or the test server failed to start

set -euo pipefail

# EPOCHREALTIME and printf follow LC_NUMERIC; pin it so timestamps always use
# a period decimal regardless of the host locale (e.g. sv_SE).
export LC_NUMERIC=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_MODEL="${BENCH_MODEL:?set BENCH_MODEL=/path/to/ggml-model.bin}"
BENCH_VAD="${BENCH_VAD:-}"
BENCH_PORT="${BENCH_PORT:-19876}"
BENCH_DIR="${BENCH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/sayit-bench}"
BENCH_REPS="${BENCH_REPS:-25}"
BENCH_STALL="${BENCH_STALL:-0}"
WHISPER_SERVER="${WHISPER_SERVER:-$HOME/.local/src/whisper.cpp/build/bin/whisper-server}"
WHISPER_CLI="${WHISPER_CLI:-$HOME/.local/bin/whisper-cli}"

for tool in espeak-ng ffmpeg python3 curl; do
    command -v "$tool" >/dev/null || { echo "$tool missing" >&2; exit 1; }
done
[[ -x "$WHISPER_SERVER" ]] || { echo "whisper-server missing: $WHISPER_SERVER" >&2; exit 1; }
[[ -f "$BENCH_MODEL" ]] || { echo "model missing: $BENCH_MODEL" >&2; exit 1; }

WAV_DIR="$BENCH_DIR/wav"
RES_DIR="$BENCH_DIR/results"
mkdir -p "$WAV_DIR" "$RES_DIR"

# Run the pipeline from a sandbox copy of bin/ WITHOUT any .env: the scripts
# source their repo's .env, which would otherwise override the environment
# pins below (personal wordlist, production daemon port, wrong model).
SANDBOX="$BENCH_DIR/sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cp -r "$REPO_ROOT/bin" "$SANDBOX/bin"
TRANSCRIBE="$SANDBOX/bin/sayit-transcribe"
STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="$RES_DIR/$STAMP.csv"
echo "scenario,rep,seconds" > "$RESULTS"

log() { printf '[bench] %s\n' "$*"; }

# Synthesize deterministic 16 kHz mono s16 test audio (matches sayit-record).
gen_wav() {  # gen_wav <name> <text>
    local raw="$WAV_DIR/$1.raw.wav" out="$WAV_DIR/$1.wav"
    [[ -f "$out" ]] && return 0
    espeak-ng -v sv "$2" -w "$raw" >/dev/null 2>&1
    ffmpeg -y -loglevel error -i "$raw" -ar 16000 -ac 1 -c:a pcm_s16le "$out"
    rm -f "$raw"
}

gen_wav short  "Hej, det här är ett kort test."
gen_wav medium "Jag skriver ett meddelande för att testa hur snabbt dikteringen fungerar på svenska, och hur lång tid det tar från stopp till färdig text."
gen_wav long   "Det här är en längre diktering som används för att mäta hur systemet hanterar flera meningar i följd. Vi vill se hur latensen växer med längden på ljudet, och om resultatet fortfarande blir korrekt när inspelningen pågår i ungefär tjugo sekunder utan paus. Till sist avslutar vi med en mening till, så att den totala längden blir tillräcklig."
[[ -f "$WAV_DIR/silence.wav" ]] || \
    ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 2 \
        -c:a pcm_s16le "$WAV_DIR/silence.wav"

for f in short medium long silence; do
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV_DIR/$f.wav" \
        | xargs printf '[bench] %s.wav: %ss\n' "$f"
done

# Start the private test server (never the production daemon/port).
SERVER_ARGS=( --model "$BENCH_MODEL" --language sv --threads 8 --beam-size 5
              --flash-attn --suppress-nst --host 127.0.0.1 --port "$BENCH_PORT" )
[[ -n "$BENCH_VAD" && -f "$BENCH_VAD" ]] && SERVER_ARGS+=( --vad --vad-model "$BENCH_VAD" )

log "starting test whisper-server on 127.0.0.1:$BENCH_PORT"
t0=$EPOCHREALTIME
"$WHISPER_SERVER" "${SERVER_ARGS[@]}" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

ready=0
for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$BENCH_PORT") 2>/dev/null; then
        exec 3>&- 3<&-
        ready=1
        break
    fi
    sleep 0.1
done
if [[ $ready -ne 1 ]] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "test server did not become ready within 30 s" >&2
    exit 1
fi
LOAD_S=$(python3 -c "print(f'{$EPOCHREALTIME - $t0:.2f}')")
echo "server-load,1,$LOAD_S" >> "$RESULTS"
log "server ready after ${LOAD_S}s (model load + init)"

# One timed transcription. Environment pins every input: the test daemon
# port, the benchmarked model for the CLI path, and a non-existent wordlist.
run_one() {  # run_one <scenario> <rep> <wav> <daemon_port> [extra env...]
    local scenario="$1" rep="$2" wav="$3" port="$4"; shift 4
    local t_start t_end
    t_start=$EPOCHREALTIME
    env "$@" DAEMON_PORT="$port" MODEL_PATH="$BENCH_MODEL" \
        WHISPER_CLI="$WHISPER_CLI" WORDLIST="$BENCH_DIR/no-wordlist.tsv" \
        VAD_MODEL="${BENCH_VAD:-/nonexistent}" \
        "$TRANSCRIBE" "$wav" >/dev/null 2>&1 || true
    t_end=$EPOCHREALTIME
    python3 -c "print(f'$scenario,$rep,{$t_end - $t_start:.3f}')" >> "$RESULTS"
}

# Warm-up (not recorded): first requests page the model through the backend.
for _ in 1 2 3; do run_one warmup 0 "$WAV_DIR/short.wav" "$BENCH_PORT"; done
sed -i '/^warmup,/d' "$RESULTS"

for len in short medium long; do
    log "warm daemon: $len x$BENCH_REPS"
    for rep in $(seq 1 "$BENCH_REPS"); do
        run_one "warm-$len" "$rep" "$WAV_DIR/$len.wav" "$BENCH_PORT"
    done
done

log "warm daemon: silence x10"
for rep in $(seq 1 10); do
    run_one warm-silence "$rep" "$WAV_DIR/silence.wav" "$BENCH_PORT"
done

log "cold CLI fallback (daemon port closed): short/medium x10"
for len in short medium; do
    for rep in $(seq 1 10); do
        run_one "cold-$len" "$rep" "$WAV_DIR/$len.wav" 1
    done
done

log "profiling overhead: warm-short x10 with SAYIT_PROFILE=1"
for rep in $(seq 1 10); do
    run_one profile-short "$rep" "$WAV_DIR/short.wav" "$BENCH_PORT" \
        SAYIT_PROFILE=1 XDG_RUNTIME_DIR="$BENCH_DIR"
done

if [[ "$BENCH_STALL" == "1" ]]; then
    log "stalled-server demonstration (SIGSTOP on the TEST server) x3"
    kill -STOP "$SERVER_PID"
    for rep in 1 2 3; do
        run_one stalled-short "$rep" "$WAV_DIR/short.wav" "$BENCH_PORT"
    done
    kill -CONT "$SERVER_PID"
fi

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT INT TERM

log "results: $RESULTS"
python3 - "$RESULTS" <<'PYEOF'
import csv, statistics, sys
rows = {}
for r in csv.DictReader(open(sys.argv[1])):
    rows.setdefault(r["scenario"], []).append(float(r["seconds"]))
print(f"{'scenario':<16}{'n':>4}{'median':>9}{'p95':>9}{'max':>9}")
for sc, xs in rows.items():
    xs.sort()
    p95 = xs[min(len(xs) - 1, int(round(0.95 * len(xs))) - 1)] if len(xs) > 1 else xs[0]
    print(f"{sc:<16}{len(xs):>4}{statistics.median(xs):>9.3f}{p95:>9.3f}{xs[-1]:>9.3f}")
PYEOF
