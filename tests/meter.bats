#!/usr/bin/env bats
# Tests for bin/sayit-meter — the OSD meter. Runs against a sandboxed copy of
# bin/ (no .env), with pw-cat and gdbus as PATH stubs and XDG_DATA_HOME
# pointed at a sandbox so installed theme icons on the developer machine can
# never leak in. Synthetic PCM only, no microphone, no real OSD.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    mkdir -p "$XDG_DATA_HOME"
    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"

    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    # pw-cat stub: emits synthetic s16 PCM on stdout, then ends the stream.
    # Loud mode = full-scale noise; long = 12 frames of silence (enough for
    # the idle-dot pulse to toggle); default = 4 frames of digital silence.
    cat > "$STUBBIN/pw-cat" <<'EOF'
#!/usr/bin/env bash
echo "pw-cat $*" >> "$STUB_CTL/calls.log"
if [[ -f "$STUB_CTL/pw-cat.forever" ]]; then
    # Die on SIGPIPE like the real pw-cat when the reader goes away.
    while :; do head -c 2000 /dev/zero || exit 0; sleep 0.05; done
elif [[ -f "$STUB_CTL/pw-cat.loud" ]]; then
    head -c 8000 /dev/urandom
elif [[ -f "$STUB_CTL/pw-cat.long" ]]; then
    head -c 24000 /dev/zero
else
    head -c 8000 /dev/zero
fi
exit 0
EOF

    # gdbus stub: answers the portal color-scheme probe (dark by default,
    # light when the light-scheme flag exists) and the OSD availability ping.
    cat > "$STUBBIN/gdbus" <<'EOF'
#!/usr/bin/env bash
echo "gdbus $*" >> "$STUB_CTL/calls.log"
if [[ "$*" == *color-scheme* ]]; then
    if [[ -f "$STUB_CTL/light-scheme" ]]; then
        echo "(<<uint32 2>>,)"
    else
        echo "(<<uint32 1>>,)"
    fi
    exit 0
fi
if [[ "$*" == *Ping* && -f "$STUB_CTL/no-osd" ]]; then
    exit 1
fi
exit 0
EOF

    chmod +x "$STUBBIN"/*
    export PATH="$STUBBIN:$PATH"

    METER="$SANDBOX/bin/sayit-meter"
    ICON_DIR="$XDG_DATA_HOME/icons/hicolor/scalable"
}

teardown() {
    pkill -f "$STUBBIN/pw-cat" 2>/dev/null || true
    sleep 0.2
}

# Fake the installed theme icons (contents never rendered by the stubs).
# Arguments = tone variants to install; default is both sets.
install_icons() {
    mkdir -p "$ICON_DIR/apps" "$ICON_DIR/status"
    local v l
    [[ $# -gt 0 ]] || set -- "" "-light"
    for v in "$@"; do
        touch "$ICON_DIR/apps/sayit$v.svg" "$ICON_DIR/status/sayit-idle$v.svg"
        for l in 0 1 2 3 4 5 6 7; do
            touch "$ICON_DIR/status/sayit-level-$l$v.svg"
        done
    done
}

@test "loud audio without icons renders tall waveform frames and hides the OSD at stream end" {
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    [ "$(grep -c "showText" "$STUB_CTL/calls.log")" -ge 3 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    tail -1 "$STUB_CTL/calls.log" | grep -q "hide"
}

@test "silence without icons renders the floor glyph, never a full bar" {
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText" "$STUB_CTL/calls.log"
    ! grep "showText" "$STUB_CTL/calls.log" | grep -q "█"
}

@test "with theme icons the mark is the meter: level icons plus the wordmark" {
    install_icons
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-7 sayit" "$STUB_CTL/calls.log"
    ! grep "showText" "$STUB_CTL/calls.log" | grep -q "█"
}

@test "silence with icons pulses the idle dot" {
    install_icons
    touch "$STUB_CTL/pw-cat.long"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-0 sayit" "$STUB_CTL/calls.log"
    grep -q "showText sayit-idle sayit" "$STUB_CTL/calls.log"
}

@test "a light color scheme picks the -light icon variant" {
    install_icons
    touch "$STUB_CTL/light-scheme" "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-7-light sayit" "$STUB_CTL/calls.log"
}

@test "a light scheme with only the base icons falls back to the base mark set" {
    install_icons ""
    touch "$STUB_CTL/light-scheme" "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-7 sayit" "$STUB_CTL/calls.log"
    ! grep -q -- "-light" "$STUB_CTL/calls.log"
}

@test "an incomplete level set falls back to the waveform, never blank frames" {
    install_icons
    rm "$ICON_DIR/status/sayit-level-5.svg" "$ICON_DIR/status/sayit-level-5-light.svg"
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    ! grep -q "sayit-level" "$STUB_CTL/calls.log"
}

@test "RECORDING_METER_STYLE=wave forces the waveform and uses the mark as its icon" {
    install_icons
    printf 'RECORDING_METER_STYLE="wave"\n' > "$SANDBOX/.env"
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    grep -q "showText sayit ▁" "$STUB_CTL/calls.log"
    ! grep -q "sayit-level" "$STUB_CTL/calls.log"
}

@test "mark style without installed icons falls back to the waveform" {
    printf 'RECORDING_METER_STYLE="mark"\n' > "$SANDBOX/.env"
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    ! grep -q "sayit-level" "$STUB_CTL/calls.log"
}

@test "the recording source is forwarded to the capture stream" {
    run "$METER" "bluez_input.stub"
    [ "$status" -eq 0 ]
    grep -q -- "--target bluez_input.stub" "$STUB_CTL/calls.log"
}

@test "a kill stops the meter, its stream and hides the OSD" {
    touch "$STUB_CTL/pw-cat.forever"
    "$METER" >/dev/null 2>&1 &
    mpid=$!
    sleep 0.8
    kill "$mpid"
    wait "$mpid" 2>/dev/null || true
    sleep 0.5
    ! pgrep -f "$STUBBIN/pw-cat" >/dev/null
    # Not tail -1: an in-flight showText forked just before the kill may
    # append after the EXIT trap's hide line.
    grep -q "org.kde.osdService.hide" "$STUB_CTL/calls.log"
}

@test "missing pw-cat is a silent no-op" {
    rm -f "$STUBBIN/pw-cat"
    if command -v pw-cat >/dev/null; then
        skip "a real pw-cat exists on this system; absence cannot be simulated"
    fi
    run "$METER"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_CTL/calls.log" ]
}

@test "an unavailable OSD service is a silent no-op" {
    touch "$STUB_CTL/no-osd"
    run "$METER"
    [ "$status" -eq 0 ]
    ! grep -q "showText" "$STUB_CTL/calls.log"
}
