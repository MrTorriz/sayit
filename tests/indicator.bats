#!/usr/bin/env bats
# Tests for bin/sayit-indicator — the persistent recording indicator and the
# waveform-meter lifecycle. Runs against a sandboxed copy of bin/ where
# sayit-meter is a stub, and notify-send/gdbus are PATH stubs; no real
# notification, OSD or microphone is touched.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    # Sandboxed data home: installed theme icons on the developer machine
    # must never leak into icon-selection tests.
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    mkdir -p "$XDG_DATA_HOME"
    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"

    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    # notify-send stub: honors --print-id unless told to act like an old
    # libnotify build without that flag.
    cat > "$STUBBIN/notify-send" <<'EOF'
#!/usr/bin/env bash
echo "notify-send $*" >> "$STUB_CTL/calls.log"
if [[ "$*" == *"-p"* ]]; then
    if [[ -f "$STUB_CTL/no-print-id" ]]; then
        echo "Unknown option -p" >&2
        exit 1
    fi
    echo 42
fi
exit 0
EOF

    # gdbus stub: also answers the portal color-scheme probe (dark by
    # default, light when the light-scheme flag exists).
    cat > "$STUBBIN/gdbus" <<'EOF'
#!/usr/bin/env bash
echo "gdbus $*" >> "$STUB_CTL/calls.log"
if [[ "$*" == *color-scheme* ]]; then
    if [[ -f "$STUB_CTL/light-scheme" ]]; then
        echo "(<<uint32 2>>,)"
    else
        echo "(<<uint32 1>>,)"
    fi
fi
exit 0
EOF

    chmod +x "$STUBBIN"/*
    export PATH="$STUBBIN:$PATH"

    # Stub: sayit-meter — records its argument, stays alive until killed.
    cat > "$SANDBOX/bin/sayit-meter" <<'EOF'
#!/usr/bin/env bash
echo "meter-start [$1]" >> "$STUB_CTL/calls.log"
trap 'echo meter-stop >> "$STUB_CTL/calls.log"; exit 0' INT TERM
while :; do sleep 0.05; done
EOF
    chmod +x "$SANDBOX/bin/sayit-meter"

    INDICATOR="$SANDBOX/bin/sayit-indicator"
    ID_FILE="$XDG_RUNTIME_DIR/sayit.indicator"
    METER_PID_FILE="$XDG_RUNTIME_DIR/sayit.meter"
}

teardown() {
    pkill -f "$SANDBOX/bin/sayit-meter" 2>/dev/null || true
    sleep 0.2
}

@test "show creates a persistent notification and stores its id" {
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    [ "$(cat "$ID_FILE")" = "42" ]
    grep -q -- "-t 0" "$STUB_CTL/calls.log"
}

@test "show twice replaces instead of stacking" {
    "$INDICATOR" show
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    grep -q -- "-r 42" "$STUB_CTL/calls.log"
    [ "$(grep -c "notify-send" "$STUB_CTL/calls.log")" -eq 2 ]
}

@test "hide closes exactly the stored notification and removes the id file" {
    "$INDICATOR" show
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    [ ! -f "$ID_FILE" ]
    grep -q "CloseNotification 42" "$STUB_CTL/calls.log"
}

@test "hide without a shown indicator is a safe no-op" {
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    ! grep -q "CloseNotification" "$STUB_CTL/calls.log" 2>/dev/null
}

@test "old notify-send without --print-id falls back to a transient cue" {
    touch "$STUB_CTL/no-print-id"
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    [ ! -f "$ID_FILE" ]
    grep -q -- "-t 1500" "$STUB_CTL/calls.log"
}

@test "an unusable notify-send never fails the pipeline" {
    # Overwrite rather than remove: removing the stub would fall through to a
    # real notify-send on developer machines.
    printf '#!/usr/bin/env bash\nexit 127\n' > "$STUBBIN/notify-send"
    chmod +x "$STUBBIN/notify-send"
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    [ ! -f "$ID_FILE" ]
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
}

@test "hide keeps the id when gdbus is unavailable so the next show replaces" {
    RECORDING_METER=0 "$INDICATOR" show
    rm -f "$STUBBIN/gdbus"
    if command -v gdbus >/dev/null; then
        skip "a real gdbus exists on this system; absence cannot be simulated"
    fi
    RECORDING_METER=0 run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    [ -f "$ID_FILE" ]        # kept, so a later show can replace via -r
}

@test "unknown argument exits 1" {
    run "$INDICATOR" bogus
    [ "$status" -eq 1 ]
}

@test "show starts the meter with the recording source" {
    run "$INDICATOR" show "bluez_input.stub"
    [ "$status" -eq 0 ]
    [ -f "$METER_PID_FILE" ]
    kill -0 "$(cat "$METER_PID_FILE")"
    # The backgrounded stub writes its log line asynchronously.
    sleep 0.3
    grep -q 'meter-start \[bluez_input.stub\]' "$STUB_CTL/calls.log"
}

@test "hide stops the meter and removes its pid file" {
    "$INDICATOR" show
    mpid=$(cat "$METER_PID_FILE")
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    [ ! -f "$METER_PID_FILE" ]
    sleep 0.3
    ! kill -0 "$mpid" 2>/dev/null
    grep -q "meter-stop" "$STUB_CTL/calls.log"
}

@test "RECORDING_METER=0 disables the meter but keeps the notification" {
    RECORDING_METER=0 run "$INDICATOR" show
    [ "$status" -eq 0 ]
    [ ! -f "$METER_PID_FILE" ]
    ! grep -q "meter-start" "$STUB_CTL/calls.log" 2>/dev/null
    grep -q "notify-send" "$STUB_CTL/calls.log"
}

@test "show twice keeps exactly one meter running" {
    "$INDICATOR" show
    first=$(cat "$METER_PID_FILE")
    "$INDICATOR" show
    second=$(cat "$METER_PID_FILE")
    [ "$first" != "$second" ]
    sleep 0.3
    ! kill -0 "$first" 2>/dev/null
    kill -0 "$second"
}

@test "the notification uses the sayit mark when the theme icons are installed" {
    mkdir -p "$XDG_DATA_HOME/icons/hicolor/scalable/apps"
    touch "$XDG_DATA_HOME/icons/hicolor/scalable/apps/sayit.svg"
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    grep -q -- "-i sayit sayit" "$STUB_CTL/calls.log"
}

@test "the notification falls back to a generic icon without the theme icons" {
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    grep -q -- "-i audio-input-microphone" "$STUB_CTL/calls.log"
}

@test "a light color scheme picks the light mark variant in the notification" {
    mkdir -p "$XDG_DATA_HOME/icons/hicolor/scalable/apps"
    touch "$XDG_DATA_HOME/icons/hicolor/scalable/apps/sayit.svg" \
          "$XDG_DATA_HOME/icons/hicolor/scalable/apps/sayit-light.svg"
    touch "$STUB_CTL/light-scheme"
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    grep -q -- "-i sayit-light sayit" "$STUB_CTL/calls.log"
}

@test "RECORDING_INDICATOR=0 suppresses the notification but keeps the meter" {
    RECORDING_INDICATOR=0 run "$INDICATOR" show
    [ "$status" -eq 0 ]
    [ -f "$METER_PID_FILE" ]
    kill -0 "$(cat "$METER_PID_FILE")"
    ! grep -q "notify-send" "$STUB_CTL/calls.log" 2>/dev/null
}

@test "a light scheme with only the base mark installed falls back to it" {
    mkdir -p "$XDG_DATA_HOME/icons/hicolor/scalable/apps"
    touch "$XDG_DATA_HOME/icons/hicolor/scalable/apps/sayit.svg"
    touch "$STUB_CTL/light-scheme"
    run "$INDICATOR" show
    [ "$status" -eq 0 ]
    grep -q -- "-i sayit sayit" "$STUB_CTL/calls.log"
}

@test "a recycled meter PID belonging to another process is never killed" {
    # fd 3 closed: an orphan must never hold bats' pipe open (bats blocks
    # on it at end of run when an assertion above fails).
    sleep 30 3>&- &
    other=$!
    printf '%s\n' "$other" > "$METER_PID_FILE"
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    kill -0 "$other"
    kill "$other" 2>/dev/null || true
}
