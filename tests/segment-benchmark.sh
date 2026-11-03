#!/usr/bin/env bash
# segment-benchmark.sh — release-to-text time and word errors with and without
# SEGMENT_WHILE_RECORDING, through the real dictation path (macOS)
#
# Usage:
#   ./tests/segment-benchmark.sh
#
# Environment:
#   BENCH_DIR      working/results directory (default $XDG_DATA_HOME/sayit-bench-segments)
#   BENCH_PORT     private whisper-server port            (default 19877)
#   BENCH_MODELS   directory with the models              (default the repository's models/)
#   BENCH_MODEL    GGML model (default: the scripts' own, large on Apple Silicon)
#   BENCH_LENGTHS  clip lengths in seconds                (default "5 10 15 20 30")
#   BENCH_CLIPS    clips per length                       (default 6)
#   BENCH_VOICE    a Swedish system voice for say         (default Alva)
#   BENCH_RELEASE  seconds from the last word to the stop (default 0.3)
#   BENCH_SENTENCES  a TSV of recorded sentences instead of say: a 16 kHz
#                  mono WAV path, a tab and its transcript per line (FLEURS,
#                  for one). No noise is added to them
#   BEAM, AUDIO_CTX_ADAPTIVE, INITIAL_PROMPT   passed on to the scripts
#                                             (default 5, 0, empty)
#
# What it measures: each clip is played into a real sayit-rec through its
# --replay mode, at the speed it was spoken, while bin/sayit start/stop run as
# Sayit.app runs them. The stop comes BENCH_RELEASE seconds (default 0.3)
# after the last word: before a 0.4 s pause could cut the last piece off, so
# that piece is always left for after the release. Measured is
# the time from that stop to the text reaching sayit-paste, and the word
# errors against the script the clip was spoken from, once with the setting
# off and once on, alternating clip by clip.
#
# The clips: neutral Swedish sentences from `say`, joined with pauses of
# 0.2-1.2 s, under a low hum of noise at 35 or 20 dB below the speech.
#
# Privacy/safety by construction:
#   - its own whisper-server (bin/sayit-daemon) on BENCH_PORT, its own run,
#     data, config and state directories (so the daemon's private path file
#     is its own too); never the running daemon, the user's .env, wordlist or
#     history
#   - sayit-paste is a stub that writes to BENCH_DIR: nothing is pasted, and
#     no microphone is opened
#   - everything stays under BENCH_DIR (never inside the repo)
#
# Requirements: macOS, say, afconvert, swiftc, python3, curl, whisper.cpp.
#
# Exit codes:
#   0  Benchmark completed
#   1  Not macOS, a missing requirement, or the server failed to start

set -euo pipefail
export LC_NUMERIC=C

[[ "$(uname -s)" == Darwin ]] || { echo "segment-benchmark.sh needs macOS" >&2; exit 1; }
for tool in say afconvert swiftc python3 curl; do
    command -v "$tool" >/dev/null || { echo "$tool missing" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="${BENCH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/sayit-bench-segments}"
BENCH_PORT="${BENCH_PORT:-19877}"
BENCH_LENGTHS="${BENCH_LENGTHS:-5 10 15 20 30}"
BENCH_CLIPS="${BENCH_CLIPS:-6}"
BENCH_VOICE="${BENCH_VOICE:-Alva}"
BENCH_RELEASE="${BENCH_RELEASE:-0.3}"
export BEAM="${BEAM:-5}" AUDIO_CTX_ADAPTIVE="${AUDIO_CTX_ADAPTIVE:-0}" INITIAL_PROMPT="${INITIAL_PROMPT:-}"

log() { printf '[bench] %s\n' "$*"; }

SANDBOX="$BENCH_DIR/sandbox"
CLIPS="$BENCH_DIR/clips"
OUT="$BENCH_DIR/out"
rm -rf "$SANDBOX" "$OUT"
mkdir -p "$SANDBOX/run" "$SANDBOX/data" "$SANDBOX/config" "$SANDBOX/state" "$SANDBOX/helpers" "$CLIPS" "$OUT"
chmod 700 "$SANDBOX/run"
# bin/ without any .env: the scripts would otherwise source the repository's.
cp -r "$REPO_ROOT/bin" "$SANDBOX/bin"
ln -s "${BENCH_MODELS:-$REPO_ROOT/models}" "$SANDBOX/models"

log "building sayit-rec"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$REPO_ROOT"/mac/Sources/Common/*.swift "$REPO_ROOT"/mac/Sources/Rec/*.swift \
    -o "$SANDBOX/sayit-rec-real"
cat > "$SANDBOX/helpers/sayit-rec" <<'EOF'
#!/usr/bin/env bash
exec "$BENCH_SANDBOX/sayit-rec-real" --replay "$BENCH_CLIP" "$@"
EOF
cat > "$SANDBOX/helpers/sayit-paste" <<'EOF'
#!/usr/bin/env bash
t=$EPOCHREALTIME
cat > "$BENCH_OUT/paste.txt"
printf '%s\n' "$t" > "$BENCH_OUT/paste.time"
EOF
chmod +x "$SANDBOX/helpers/"*

# --- clips -------------------------------------------------------------------

SENTENCES=(
    "Jag har läst igenom förslaget och tycker att det ser bra ut."
    "Kan du skicka över den senaste versionen av rapporten innan lunch?"
    "Mötet i morgon börjar en halvtimme senare än vanligt."
    "Vi behöver bestämma oss för vilket alternativ vi ska välja."
    "Det var länge sedan vi pratade, hur har du haft det?"
    "Glöm inte att ta med regnjackan, det ska regna hela eftermiddagen."
    "Jag tror att problemet ligger i hur inställningarna sparas."
    "Tåget var försenat igen, så jag kommer lite senare."
    "Kan vi flytta samtalet till nästa vecka i stället?"
    "Hon skrev ett långt brev om resan genom norra Sverige."
    "Det viktigaste är att alla får samma information samtidigt."
    "Vi åt middag på en liten restaurang nere vid hamnen."
    "Jag skickar en sammanfattning så snart jag är klar med anteckningarna."
    "Barnen ville gå till badhuset efter skolan."
    "Det finns fortfarande några frågor som vi inte har svar på."
    "Priset har gått upp ganska mycket sedan förra året."
    "Han cyklar till jobbet varje dag, även på vintern."
    "Kontrollera att alla dokument är underskrivna innan du lämnar in dem."
    "Biblioteket har öppet längre på torsdagar."
    "Jag har bokat ett bord på restaurangen till i kväll."
    "Det blev en lugn helg med promenader och god mat."
    "Svara gärna på mejlet när du har tid."
    "Vi måste beställa mer papper till skrivaren."
    "Skogen var tyst och snön låg orörd mellan träden."
    "Förslaget röstades igenom utan några större invändningar."
    "Jag letar efter en lägenhet nära centrum."
    "Kom ihåg att vattna blommorna medan jag är borta."
    "Det nya kaféet på hörnet har jättegoda kanelbullar."
    "Projektet ligger lite efter tidsplanen, men vi kommer ikapp."
    "Kan du påminna mig om att ringa tandläkaren?"
    "Vi ses vid entrén strax innan föreställningen börjar."
    "Han har alltid velat lära sig spela piano."
    "Jag skriver färdigt texten i kväll och skickar den i morgon bitti."
    "Det är bättre att fråga en gång för mycket än en gång för lite."
    "Sommaren var varm och torr, och skörden blev mindre än väntat."
    "Kolla gärna om det finns biljetter kvar till lördagens match."
    "När vi kom fram till stugan, som låg längst in i skogen, hade det redan börjat skymma."
    "Om du har möjlighet, kan du titta på avtalet och säga vad du tycker innan fredag?"
    "Jag har funderat en del på det vi pratade om, och jag tror att du har rätt."
    "Efter flera veckors arbete är den nya hemsidan äntligen klar för publicering."
)

if [[ -n "${BENCH_SENTENCES:-}" ]]; then
    log "recorded sentences from $BENCH_SENTENCES"
    cp "$BENCH_SENTENCES" "$CLIPS/sentences.tsv"
    SENTENCES=()
    NOISE=0
else
    log "synthesizing ${#SENTENCES[@]} sentences at two speaking rates ($BENCH_VOICE)"
    : > "$CLIPS/sentences.tsv"
    NOISE=1
fi
for i in "${!SENTENCES[@]}"; do
    for rate in 150 180; do
        wav="$CLIPS/s$i-r$rate.wav"
        if [[ ! -f "$wav" ]]; then
            say -v "$BENCH_VOICE" -r "$rate" -o "$CLIPS/tmp.aiff" "${SENTENCES[$i]}"
            afconvert -f WAVE -d LEI16@16000 -c 1 "$CLIPS/tmp.aiff" "$wav"
            rm -f "$CLIPS/tmp.aiff"
        fi
        printf '%s\t%s\n' "$wav" "${SENTENCES[$i]}" >> "$CLIPS/sentences.tsv"
    done
done

log "building clips: lengths $BENCH_LENGTHS s, $BENCH_CLIPS each"
rm -f "$CLIPS"/clip-*.wav
python3 - "$CLIPS" "$BENCH_CLIPS" "$BENCH_LENGTHS" "$NOISE" <<'PYEOF'
import array, math, random, sys, wave
clips, per, lengths = sys.argv[1], int(sys.argv[2]), [float(x) for x in sys.argv[3].split()]
noise = sys.argv[4] == "1"

def read(path):
    with wave.open(path) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        return array.array("h", w.readframes(w.getnframes()))

def trim(a):
    """The sentence from its first to its last 20 ms of speech, 0.1 s either
    side: say and recordings both pad with silence, and the pauses here are
    ours. Speech is within 35 dB of the loudest frame and 10 dB over the
    quietest."""
    rms = [math.sqrt(sum(v * v for v in a[i:i + 320]) / 320) for i in range(0, len(a) - 320, 320)]
    if not rms:
        return a
    floor = max(min(rms), 1.0)
    level = max(floor * 3.16, max(rms) / 56)
    loud = [i for i, r in enumerate(rms) if r > level]
    return a[max(0, loud[0] * 320 - 1600):(loud[-1] + 1) * 320 + 1600] if loud else a

sentences = []
with open(f"{clips}/sentences.tsv", encoding="utf-8") as f:
    for line in f:
        path, text = line.rstrip("\n").split("\t")
        sentences.append((trim(read(path)), text))

rnd = random.Random(20261103)
index = open(f"{clips}/clips.tsv", "w", encoding="utf-8")
for length in lengths:
    for c in range(per):
        # The pauses: digital silence under the synthetic hum added below, or
        # for recorded sentences their own noise floor (the quietest 100 ms).
        floor = 0.0
        def pause(seconds):
            if floor == 0:
                return array.array("h", [0] * int(seconds * 16000))
            return array.array("h", (int(rnd.gauss(0, floor)) for _ in range(int(seconds * 16000))))
        audio, words = array.array("h"), []
        pool = list(range(len(sentences)))
        rnd.shuffle(pool)
        for k in pool:
            s, text = sentences[k]
            if words and (len(audio) + len(s)) / 16000 > length + 1.0:
                continue
            if not noise:
                floor = min(math.sqrt(sum(v * v for v in s[i:i + 1600]) / 1600)
                            for i in range(0, max(1, len(s) - 1600), 800))
            audio.extend(pause(0.4) if not words else
                         pause(rnd.uniform(0.2, 0.35) if rnd.random() < 0.3 else rnd.uniform(0.5, 1.2)))
            audio.extend(s)
            words.append(text)
            if len(audio) / 16000 >= length - 0.5:
                break
        audio.extend(pause(0.1))                               # with trim's 0.1 s
        snr = "-"
        if noise:
            speech = math.sqrt(sum(v * v for v in audio) / max(1, sum(1 for v in audio if v)))
            snr = 35 if c % 2 == 0 else 20
            sigma, hum = speech / (10 ** (snr / 20)), 0.0
            for i in range(len(audio)):
                hum = 0.9 * hum + 0.1 * rnd.gauss(0, sigma * 3.2)  # low, room-like noise
                audio[i] = max(-32768, min(32767, int(audio[i] + hum)))
        name = f"{clips}/clip-{int(length):02d}s-{c + 1}.wav"
        with wave.open(name, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(audio.tobytes())
        index.write(f"{name}\t{len(audio) / 16000:.3f}\t{snr}\t{' '.join(words)}\n")
PYEOF

# --- server ------------------------------------------------------------------

export XDG_RUNTIME_DIR="$SANDBOX/run" XDG_DATA_HOME="$SANDBOX/data" XDG_CONFIG_HOME="$SANDBOX/config" \
       XDG_STATE_HOME="$SANDBOX/state"
export SAYIT_MAC_HELPERS="$SANDBOX/helpers" BENCH_SANDBOX="$SANDBOX" BENCH_OUT="$OUT"
export DAEMON_PORT="$BENCH_PORT" WORDLIST="$SANDBOX/no-wordlist.tsv" AUDIO_SOURCE=""
export SAYIT_PROFILE=1 RECORDING_INDICATOR=1 MAX_RECORD_SECONDS=120 LLM_CLEANUP=0
[[ -n "${BENCH_MODEL:-}" ]] && export MODEL_PATH="$BENCH_MODEL"
unset SAYIT_MODEL SAYIT_DAEMON_LOG 2>/dev/null || true

log "starting a private whisper-server on 127.0.0.1:$BENCH_PORT (beam $BEAM)"
"$SANDBOX/bin/sayit-daemon" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; pkill -f "$SANDBOX/sayit-rec-real" 2>/dev/null || true' EXIT INT TERM
ready=0
for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$BENCH_PORT") 2>/dev/null; then ready=1; break; fi
    sleep 0.1
done
if (( ! ready )) || ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "test server did not start" >&2
    exit 1
fi

first=$(head -n 1 "$CLIPS/clips.tsv" | cut -f1)
for _ in 1 2 3; do "$SANDBOX/bin/sayit-transcribe" "$first" >/dev/null; done

# --- runs --------------------------------------------------------------------

RESULTS="$BENCH_DIR/results-$(date +%Y%m%d-%H%M%S).tsv"
printf 'clip\tseconds\tsnr\tsegments\trun\tlatency\tpieces\n' > "$RESULTS"
run=0
total=$(( $(wc -l < "$CLIPS/clips.tsv") ))
while IFS=$'\t' read -r clip seconds snr _; do
    for segments in 0 1; do
        run=$(( run + 1 ))
        rm -f "$OUT/paste.txt" "$OUT/paste.time"
        export BENCH_CLIP="$clip" SEGMENT_WHILE_RECORDING="$segments" SAYIT_PROFILE_RUN="$run"
        t_start=$EPOCHREALTIME
        "$SANDBOX/bin/sayit" start
        # The clip ends 0.2 s after its last word (trim's margin and the tail),
        # and plays from about when the recorder was spawned.
        t_rec=$(awk -F, -v r="$run" '$1 == r && $4 == "record.spawned" { print $2 }' \
            "$XDG_RUNTIME_DIR/sayit-profile.csv")
        release=$(python3 -c "import time; print(max(0.0, ${t_rec:-$t_start} + $seconds - 0.2 + $BENCH_RELEASE - time.time()))")
        sleep "$release"
        t_stop=$EPOCHREALTIME
        "$SANDBOX/bin/sayit" stop
        latency=$(python3 -c "print(f'{float(open(\"$OUT/paste.time\").read()) - $t_stop:.3f}')" 2>/dev/null || echo NA)
        pieces=$(awk -F, -v r="$run" '$1 == r && $4 == "segments.ready" { print $5 }' "$XDG_RUNTIME_DIR/sayit-profile.csv")
        cp "$OUT/paste.txt" "$OUT/run-$run.txt" 2>/dev/null || : > "$OUT/run-$run.txt"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$clip")" "$seconds" "$snr" "$segments" \
            "$run" "$latency" "${pieces:-0}" >> "$RESULTS"
        log "$(( (run + 1) / 2 ))/$total $(basename "$clip") segments=$segments: ${latency} s, pieces ${pieces:-0}"
        sleep 0.5
    done
done < "$CLIPS/clips.tsv"

leftover=$(find "$XDG_RUNTIME_DIR" -name 'sayit-*' \( -name '*.wav' -o -name '*-part-*' -o -name '*.segments*' \) | wc -l)
log "files left in the run directory: $(( leftover ))"

# --- report ------------------------------------------------------------------

python3 - "$RESULTS" "$CLIPS/clips.tsv" "$OUT" <<'PYEOF'
import re, statistics, sys
results, clips, out = sys.argv[1:]
ref = {}
for line in open(clips, encoding="utf-8"):
    path, seconds, snr, text = line.rstrip("\n").split("\t")
    ref[path.rsplit("/", 1)[1]] = text

# Spellings that are both right count as the same word.
VARIANTS = [(r"\bi (kväll|morgon|stället|dag|går|natt)\b", r"i\1"), (r"\bmail", "mejl"),
            (r"\bcafé", "kafé")]

def words(t):
    t = re.sub(r"[^\w\s]", " ", t.lower())
    for pattern, repl in VARIANTS:
        t = re.sub(pattern, repl, t)
    return t.split()

def errors(r, h):
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hw in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
    return d[len(h)]

rows = [l.rstrip("\n").split("\t") for l in open(results, encoding="utf-8")][1:]
table = {}
for clip, seconds, snr, seg, run, lat, pieces in rows:
    hyp = open(f"{out}/run-{run}.txt", encoding="utf-8").read()
    r = words(ref[clip])
    length = int(clip.split("-")[1][:-1])
    t = table.setdefault((length, seg), {"lat": [], "err": 0, "ref": 0, "pieces": []})
    if lat != "NA":
        t["lat"].append(float(lat))
    t["err"] += errors(r, words(hyp))
    t["ref"] += len(r)
    t["pieces"].append(int(pieces))

def p90(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(0.9 * (len(v) - 1))))]

print()
print("| Clip | Off: median | Off: p90 | Off: WER | On: median | On: p90 | On: WER | Pieces |")
print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
lengths = sorted({k[0] for k in table})
allv = {"0": {"lat": [], "err": 0, "ref": 0}, "1": {"lat": [], "err": 0, "ref": 0}}
for length in lengths:
    cells = []
    for seg in ("0", "1"):
        t = table[(length, seg)]
        allv[seg]["lat"] += t["lat"]; allv[seg]["err"] += t["err"]; allv[seg]["ref"] += t["ref"]
        cells += [f"{statistics.median(t['lat']):.2f} s", f"{p90(t['lat']):.2f} s",
                  f"{100 * t['err'] / t['ref']:.1f}%"]
    pieces = table[(length, "1")]["pieces"]
    print(f"| {length} s | " + " | ".join(cells) + f" | {statistics.mean(pieces):.1f} |")
cells = []
for seg in ("0", "1"):
    a = allv[seg]
    cells += [f"{statistics.median(a['lat']):.2f} s", f"{p90(a['lat']):.2f} s",
              f"{100 * a['err'] / a['ref']:.1f}%"]
print("| all | " + " | ".join(cells) + " | |")
print(f"\nresults: {results}")
PYEOF
