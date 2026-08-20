#!/usr/bin/env bats
# Tests for bin/sayit-indicator — the persistent recording indicator.
# notify-send and gdbus are PATH stubs; no real notification is shown.

setup() {
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
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

    cat > "$STUBBIN/gdbus" <<'EOF'
#!/usr/bin/env bash
echo "gdbus $*" >> "$STUB_CTL/calls.log"
exit 0
EOF

    chmod +x "$STUBBIN"/*
    export PATH="$STUBBIN:$PATH"

    INDICATOR="$BATS_TEST_DIRNAME/../bin/sayit-indicator"
    ID_FILE="$XDG_RUNTIME_DIR/sayit.indicator"
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
    ! grep -q "gdbus" "$STUB_CTL/calls.log" 2>/dev/null
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
    "$INDICATOR" show
    rm -f "$STUBBIN/gdbus"
    if command -v gdbus >/dev/null; then
        skip "a real gdbus exists on this system; absence cannot be simulated"
    fi
    run "$INDICATOR" hide
    [ "$status" -eq 0 ]
    [ -f "$ID_FILE" ]        # kept, so a later show can replace via -r
}

@test "unknown argument exits 1" {
    run "$INDICATOR" bogus
    [ "$status" -eq 1 ]
}
