#!/usr/bin/env bats
# Tests for bin/sayit-meter — style selection, fallbacks and capture cleanup.
# Runs against a sandboxed copy of bin/ (no .env), with pw-cat, gdbus and
# sayit-overlay as stubs and XDG_DATA_HOME pointed at a sandbox so installed
# theme icons on the developer machine can never leak in. Synthetic PCM only,
# no microphone, no real OSD, no real window.

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
    # forever = runs until signalled (models a live capture);
    # loud = full-scale noise; long = 12 frames of silence; default = 4.
    cat > "$STUBBIN/pw-cat" <<'EOF'
#!/usr/bin/env bash
echo "pw-cat $*" >> "$STUB_CTL/calls.log"
if [[ -f "$STUB_CTL/pw-cat.forever" ]]; then
    printf '%s\n' "$$" > "$STUB_CTL/pw-cat.pid"
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

    # Stub: sayit-overlay — --check reports availability from a control file;
    # otherwise it drains stdin so the pipeline behaves like the real one.
    cat > "$SANDBOX/bin/sayit-overlay" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then
    echo "overlay-check" >> "$STUB_CTL/calls.log"
    [[ -f "$STUB_CTL/overlay-unavailable" ]] && exit 1
    exit 0
fi
echo "overlay-start" >> "$STUB_CTL/calls.log"
[[ -f "$STUB_CTL/overlay-exits-now" ]] && exit 0
trap 'echo overlay-stop >> "$STUB_CTL/calls.log"; exit 0' INT TERM
cat >/dev/null
exit 0
EOF
    chmod +x "$SANDBOX/bin/sayit-overlay"

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

@test "the overlay is the default style and never touches the OSD" {
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "overlay-start" "$STUB_CTL/calls.log"
    ! grep -q "showText" "$STUB_CTL/calls.log"
    ! grep -q "osdService.hide" "$STUB_CTL/calls.log"
}

@test "an unavailable overlay falls back to the mark in the OSD" {
    touch "$STUB_CTL/overlay-unavailable"
    install_icons
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    ! grep -q "overlay-start" "$STUB_CTL/calls.log"
    grep -q "showText sayit-level-7 sayit" "$STUB_CTL/calls.log"
}

@test "an unavailable overlay without icons falls back to the waveform" {
    touch "$STUB_CTL/overlay-unavailable" "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
}

@test "an unknown style in .env falls back to the default instead of guessing" {
    printf 'RECORDING_METER_STYLE="bogus"\n' > "$SANDBOX/.env"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "overlay-start" "$STUB_CTL/calls.log"
}

@test "the recording source is forwarded to the capture stream" {
    run "$METER" "bluez_input.stub"
    [ "$status" -eq 0 ]
    grep -q -- "--target bluez_input.stub" "$STUB_CTL/calls.log"
}

@test "a renderer that exits on its own takes the capture down with it" {
    # Regression: pw-cat ignores SIGPIPE, so a finished renderer used to
    # leave it running as an orphan with the microphone still open.
    touch "$STUB_CTL/pw-cat.forever" "$STUB_CTL/overlay-exits-now"
    "$METER" >/dev/null 2>&1 &
    mpid=$!
    sleep 1.5
    wait "$mpid" 2>/dev/null || true
    sleep 0.5
    [ -f "$STUB_CTL/pw-cat.pid" ]
    ! kill -0 "$(cat "$STUB_CTL/pw-cat.pid")" 2>/dev/null
}

@test "a kill stops the meter, the renderer and the capture stream" {
    touch "$STUB_CTL/pw-cat.forever"
    "$METER" >/dev/null 2>&1 &
    mpid=$!
    sleep 1
    kill "$mpid"
    wait "$mpid" 2>/dev/null || true
    sleep 0.5
    ! kill -0 "$mpid" 2>/dev/null
    [ -f "$STUB_CTL/pw-cat.pid" ]
    ! kill -0 "$(cat "$STUB_CTL/pw-cat.pid")" 2>/dev/null
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

# --- the OSD styles, reached explicitly ----------------------------------

@test "wave style renders a scrolling waveform and hides the OSD at the end" {
    printf 'RECORDING_METER_STYLE="wave"\n' > "$SANDBOX/.env"
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    [ "$(grep -c "showText" "$STUB_CTL/calls.log")" -ge 3 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    grep -q "osdService.hide" "$STUB_CTL/calls.log"
}

@test "mark style with icons animates the mark, silence pulses the idle dot" {
    printf 'RECORDING_METER_STYLE="mark"\n' > "$SANDBOX/.env"
    install_icons
    touch "$STUB_CTL/pw-cat.long"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-0 sayit" "$STUB_CTL/calls.log"
    grep -q "showText sayit-idle sayit" "$STUB_CTL/calls.log"
}

@test "a light color scheme picks the -light icon variant" {
    printf 'RECORDING_METER_STYLE="mark"\n' > "$SANDBOX/.env"
    install_icons
    touch "$STUB_CTL/light-scheme" "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-7-light sayit" "$STUB_CTL/calls.log"
}

@test "a light scheme with only the base icons falls back to the base set" {
    printf 'RECORDING_METER_STYLE="mark"\n' > "$SANDBOX/.env"
    install_icons ""
    touch "$STUB_CTL/light-scheme" "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep -q "showText sayit-level-7 sayit" "$STUB_CTL/calls.log"
    ! grep -q -- "-light" "$STUB_CTL/calls.log"
}

@test "an incomplete level set falls back to the waveform, never blank frames" {
    printf 'RECORDING_METER_STYLE="mark"\n' > "$SANDBOX/.env"
    install_icons
    rm "$ICON_DIR/status/sayit-level-5.svg" "$ICON_DIR/status/sayit-level-5-light.svg"
    touch "$STUB_CTL/pw-cat.loud"
    run "$METER"
    [ "$status" -eq 0 ]
    grep "showText" "$STUB_CTL/calls.log" | tail -1 | grep -q "█"
    ! grep -q "sayit-level" "$STUB_CTL/calls.log"
}

@test "an unavailable OSD service is a silent no-op for the OSD styles" {
    printf 'RECORDING_METER_STYLE="wave"\n' > "$SANDBOX/.env"
    touch "$STUB_CTL/no-osd"
    run "$METER"
    [ "$status" -eq 0 ]
    ! grep -q "showText" "$STUB_CTL/calls.log"
}
