#!/usr/bin/env bats
# Tests for bin/sayit — the orchestrator/state machine. Runs against a
# sandboxed copy of bin/ where every side-effectful helper (sayit-bt,
# sayit-record, sayit-transcribe, sayit-inject, sayit-indicator) is replaced
# by a stub, and all state lives in temporary XDG directories. No real
# microphone, Bluetooth, clipboard, daemon or user data is ever touched.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$HOME"

    # Control dir: stubs read flags from and append logs to it.
    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"
    export STUB_LOG="$STUB_CTL/stub.log"
    : > "$STUB_LOG"

    # notify-send stub on PATH (sayit resolves it with command -v).
    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_CTL/notify.log"\n' > "$STUBBIN/notify-send"
    chmod +x "$STUBBIN/notify-send"
    export PATH="$STUBBIN:$PATH"

    # Stub: sayit-bt — logs up/down, prints a source name on up.
    cat > "$SANDBOX/bin/sayit-bt" <<'EOF'
#!/usr/bin/env bash
echo "bt $1" >> "$STUB_LOG"
if [[ "$1" == up ]]; then
    [[ -f "$STUB_CTL/bt.sleep" ]] && sleep "$(cat "$STUB_CTL/bt.sleep")"
    echo "stub-source"
fi
exit 0
EOF

    # Stub: sayit-record — writes START, then FINAL on SIGINT after a short
    # flush delay (models pw-record finalizing the WAV header).
    cat > "$SANDBOX/bin/sayit-record" <<'EOF'
#!/usr/bin/env bash
OUT="$1"
trap 'sleep 0.2; printf "FINAL" >> "$OUT"; exit 0' INT TERM
printf 'START ' > "$OUT"
echo "record start $OUT" >> "$STUB_LOG"
if [[ -f "$STUB_CTL/record.die" ]]; then exit 1; fi
while :; do sleep 0.05; done
EOF

    # Stub: sayit-transcribe — by default echoes the WAV content (so a test
    # can prove stop waited for FINAL); overridable via control files.
    cat > "$SANDBOX/bin/sayit-transcribe" <<'EOF'
#!/usr/bin/env bash
echo "transcribe $1" >> "$STUB_LOG"
[[ -f "$STUB_CTL/transcribe.sleep" ]] && sleep "$(cat "$STUB_CTL/transcribe.sleep")"
if [[ -f "$STUB_CTL/transcribe.fail" ]]; then echo "stub transcription error" >&2; exit 1; fi
if [[ -f "$STUB_CTL/transcribe.empty" ]]; then exit 0; fi
if [[ -f "$STUB_CTL/transcribe.text" ]]; then cat "$STUB_CTL/transcribe.text"; exit 0; fi
tr '\n' ' ' < "$1"
EOF

    # Stub: sayit-inject — logs the injected text, exit code controllable.
    cat > "$SANDBOX/bin/sayit-inject" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_CTL/inject.log"
echo "inject" >> "$STUB_LOG"
[[ -f "$STUB_CTL/inject.fail" ]] && exit 1
exit 0
EOF

    # Stub: sayit-indicator — logs show/hide.
    cat > "$SANDBOX/bin/sayit-indicator" <<'EOF'
#!/usr/bin/env bash
echo "indicator $1" >> "$STUB_LOG"
exit 0
EOF

    chmod +x "$SANDBOX/bin/"sayit-{bt,record,transcribe,inject,indicator}

    SAYIT="$SANDBOX/bin/sayit"
    SESSION="$XDG_RUNTIME_DIR/sayit.session"
    INTENT="$XDG_RUNTIME_DIR/sayit.starting"
    HIST_FILE="$XDG_DATA_HOME/sayit/history.jsonl"
}

teardown() {
    pkill -f "$SANDBOX/bin/sayit-record" 2>/dev/null || true
    sleep 0.3
}

session_pid() { cut -f1 "$SESSION"; }
session_wav() { cut -f2 "$SESSION"; }

@test "start creates a session with a live recorder and a unique WAV" {
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ -f "$SESSION" ]
    pid=$(session_pid); wav=$(session_wav)
    kill -0 "$pid"
    [[ "$wav" == "$XDG_RUNTIME_DIR"/sayit-*.wav ]]
    [ -f "$wav" ]
    [ ! -f "$INTENT" ]
    grep -q "Recording" "$STUB_CTL/notify.log"
    "$SAYIT" cancel
}

@test "indicator is shown only after the recorder is live, after the BT switch" {
    "$SAYIT" start
    grep -n "" "$STUB_LOG" > "$STUB_CTL/order"
    bt_line=$(grep -n "bt up" "$STUB_CTL/order" | head -1 | cut -d: -f1)
    rec_line=$(grep -n "record start" "$STUB_CTL/order" | head -1 | cut -d: -f1)
    ind_line=$(grep -n "indicator show" "$STUB_CTL/order" | head -1 | cut -d: -f1)
    [ -n "$ind_line" ]
    [ "$bt_line" -lt "$rec_line" ]
    [ "$rec_line" -lt "$ind_line" ]
    "$SAYIT" cancel
}

@test "RECORDING_INDICATOR=0 disables the indicator" {
    RECORDING_INDICATOR=0 "$SAYIT" start
    ! grep -q "indicator" "$STUB_LOG"
    RECORDING_INDICATOR=0 "$SAYIT" stop
    ! grep -q "indicator" "$STUB_LOG"
}

@test "second start while recording is a guarded no-op" {
    "$SAYIT" start
    pid1=$(session_pid)
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ "$(session_pid)" = "$pid1" ]
    [ "$(grep -c 'record start' "$STUB_LOG")" -eq 1 ]
    grep -q "Already recording" "$STUB_CTL/notify.log"
    "$SAYIT" cancel
}

@test "stop waits for WAV finalization before transcribing" {
    "$SAYIT" start
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    # The transcribe stub echoes the WAV content: FINAL is only present if
    # stop actually waited for the recorder's SIGINT flush to complete.
    grep -q "START FINAL" "$STUB_CTL/inject.log"
    [ ! -f "$SESSION" ]
    grep -q "indicator hide" "$STUB_LOG"
    grep -q "bt down" "$STUB_LOG"
}

@test "stop appends exactly one valid JSON history line" {
    "$SAYIT" start
    "$SAYIT" stop
    [ "$(wc -l < "$HIST_FILE")" -eq 1 ]
    python3 - "$HIST_FILE" <<'PYEOF'
import json, sys
d = json.loads(open(sys.argv[1]).readline())
assert isinstance(d["seconds"], (int, float)) and d["seconds"] >= 0, d
assert d["words"] >= 1
assert "START" in d["text"]
PYEOF
}

@test "history JSON survives quotes and newlines in the text" {
    printf 'he said "hej"\noch\tmer' > "$STUB_CTL/transcribe.text"
    "$SAYIT" start
    "$SAYIT" stop
    python3 - "$HIST_FILE" <<'PYEOF'
import json, sys
d = json.loads(open(sys.argv[1]).readline())
assert 'he said "hej"' in d["text"], d
PYEOF
}

@test "history survives a Swedish decimal-comma locale" {
    if ! locale -a 2>/dev/null | grep -qi 'sv_SE.utf8'; then
        skip "sv_SE.utf8 locale not generated on this system"
    fi
    LC_ALL=sv_SE.utf8 "$SAYIT" start
    LC_ALL=sv_SE.utf8 "$SAYIT" stop
    [ -s "$HIST_FILE" ]
    python3 -c "import json,sys; json.loads(open(sys.argv[1]).readline())" "$HIST_FILE"
}

@test "stop with no recording notifies and exits 0 without waiting" {
    start=$(date +%s)
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    (( $(date +%s) - start < 2 ))
    grep -q "No recording in progress" "$STUB_CTL/notify.log"
    [ ! -f "$STUB_CTL/inject.log" ]
}

@test "race guard: stop waits while a start is still in flight" {
    echo 1.0 > "$STUB_CTL/bt.sleep"
    "$SAYIT" start &
    start_job=$!
    sleep 0.4   # release arrives while start is still in the BT switch
    run "$SAYIT" stop
    wait "$start_job" 2>/dev/null || true
    [ "$status" -eq 0 ]
    grep -q "transcribe" "$STUB_LOG"
    grep -q "START FINAL" "$STUB_CTL/inject.log"
    [ ! -f "$SESSION" ]
}

@test "double stop: exactly one wins, both exit 0" {
    "$SAYIT" start
    "$SAYIT" stop &
    s1=$!
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    wait "$s1"
    [ "$(grep -c . "$STUB_CTL/inject.log")" -eq 1 ]
    [ "$(wc -l < "$HIST_FILE")" -eq 1 ]
}

@test "back-to-back: a new start during slow transcription is not clobbered" {
    "$SAYIT" start
    wav1=$(session_wav)
    echo 1 > "$STUB_CTL/transcribe.sleep"
    "$SAYIT" stop &
    stop_job=$!
    sleep 0.4   # stop is now inside its slow transcription
    rm -f "$STUB_CTL/transcribe.sleep"
    "$SAYIT" start
    [ -f "$SESSION" ]
    wav2=$(session_wav)
    [ "$wav1" != "$wav2" ]
    [ -f "$wav2" ]        # session 2's WAV must not be deleted by stop 1
    wait "$stop_job"
    grep -q "START FINAL" "$STUB_CTL/inject.log"   # session 1's audio intact
    "$SAYIT" cancel
}

@test "empty transcription: no injection, no history line" {
    touch "$STUB_CTL/transcribe.empty"
    "$SAYIT" start
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_CTL/inject.log" ]
    [ ! -s "$HIST_FILE" ]
    grep -q "Empty result" "$STUB_CTL/notify.log"
}

@test "transcription failure is reported as a failure, not as empty" {
    touch "$STUB_CTL/transcribe.fail"
    "$SAYIT" start
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    grep -q "Transcription failed" "$STUB_CTL/notify.log"
    ! grep -q "Empty result" "$STUB_CTL/notify.log"
    [ -s "$XDG_RUNTIME_DIR/sayit-last-error.log" ]
}

@test "injection failure still appends history and notifies" {
    touch "$STUB_CTL/inject.fail"
    "$SAYIT" start
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    grep -q "Injection failed" "$STUB_CTL/notify.log"
    [ "$(wc -l < "$HIST_FILE")" -eq 1 ]
}

@test "cancel discards the session without transcribing" {
    "$SAYIT" start
    wav=$(session_wav)
    run "$SAYIT" cancel
    [ "$status" -eq 0 ]
    [ ! -f "$SESSION" ]
    [ ! -f "$wav" ]
    ! grep -q "transcribe" "$STUB_LOG"
    grep -q "bt down" "$STUB_LOG"
    grep -q "indicator hide" "$STUB_LOG"
    grep -q "cancelled" "$STUB_CTL/notify.log"
}

@test "cancel during an in-flight start waits and then discards" {
    echo 1.0 > "$STUB_CTL/bt.sleep"
    "$SAYIT" start &
    start_job=$!
    sleep 0.4
    run "$SAYIT" cancel
    wait "$start_job" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ ! -f "$SESSION" ]
    ! grep -q "transcribe" "$STUB_LOG"
    # No orphaned recorder may remain
    ! pgrep -f "$SANDBOX/bin/sayit-record" >/dev/null
}

@test "stale session with a dead PID is cleaned up by start" {
    printf '99999999\t%s\tnope\n' "$XDG_RUNTIME_DIR/sayit-stale.wav" > "$SESSION"
    touch "$XDG_RUNTIME_DIR/sayit-stale.wav"
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ ! -f "$XDG_RUNTIME_DIR/sayit-stale.wav" ]
    pid=$(session_pid)
    kill -0 "$pid"
    "$SAYIT" cancel
}

@test "a recycled PID belonging to another process is never signalled" {
    sleep 30 &
    other=$!
    printf '%s\t%s\t1\n' "$other" "$XDG_RUNTIME_DIR/sayit-x.wav" > "$SESSION"
    touch "$XDG_RUNTIME_DIR/sayit-x.wav"
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    kill -0 "$other"   # the innocent process must still be alive
    kill "$other" 2>/dev/null || true
}

@test "recorder spawn failure cleans up and reports" {
    touch "$STUB_CTL/record.die"
    run "$SAYIT" start
    [ "$status" -eq 1 ]
    [ ! -f "$SESSION" ]
    [ ! -f "$INTENT" ]
    grep -q "bt down" "$STUB_LOG"
    grep -q "failed to start" "$STUB_CTL/notify.log"
    ! grep -q "indicator show" "$STUB_LOG"
}

@test "toggle starts when idle and stops when recording" {
    "$SAYIT" toggle
    [ -f "$SESSION" ]
    "$SAYIT" toggle
    [ ! -f "$SESSION" ]
    grep -q "START FINAL" "$STUB_CTL/inject.log"
}

@test "unknown argument exits 1" {
    run "$SAYIT" bogus
    [ "$status" -eq 1 ]
}

@test "an intent marker from a crashed start is cleared, not waited on" {
    echo 99999999 > "$INTENT"   # owner PID that cannot exist
    start=$(date +%s)
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    (( $(date +%s) - start < 2 ))
    [ ! -f "$INTENT" ]
    grep -q "No recording in progress" "$STUB_CTL/notify.log"
}

@test "start reclaims a dead intent immediately" {
    echo 99999999 > "$INTENT"
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ -f "$SESSION" ]
    "$SAYIT" cancel
}

@test "notification text is markup-escaped" {
    printf 'x < y & z' > "$STUB_CTL/transcribe.text"
    "$SAYIT" start
    "$SAYIT" stop
    grep -q 'x &lt; y &amp; z' "$STUB_CTL/notify.log"
}
