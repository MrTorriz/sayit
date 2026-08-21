#!/usr/bin/env bats
# Tests for bin/sayit-overlay — the parts that need no desktop: position
# storage, availability reporting and the never-break-dictation exits.
# WAYLAND_DISPLAY is cleared so every case is deterministic on any machine;
# no window is ever created.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME"
    OVERLAY="$BATS_TEST_DIRNAME/../bin/sayit-overlay"
    POS_FILE="$XDG_CONFIG_HOME/sayit/overlay-position"
}

@test "no saved position reports unset" {
    WAYLAND_DISPLAY= run "$OVERLAY" --print-position
    [ "$status" -eq 0 ]
    [ "$output" = "unset" ]
}

@test "a saved position is read back" {
    mkdir -p "$(dirname "$POS_FILE")"
    printf '# comment\nx=420\ny=980\n' > "$POS_FILE"
    WAYLAND_DISPLAY= run "$OVERLAY" --print-position
    [ "$status" -eq 0 ]
    [ "$output" = "420 980" ]
}

@test "a malformed position file reports unset instead of failing" {
    mkdir -p "$(dirname "$POS_FILE")"
    printf 'x=left\ny=980\n' > "$POS_FILE"
    WAYLAND_DISPLAY= run "$OVERLAY" --print-position
    [ "$status" -eq 0 ]
    [ "$output" = "unset" ]
}

@test "a half-written position file reports unset" {
    mkdir -p "$(dirname "$POS_FILE")"
    printf 'x=420\n' > "$POS_FILE"
    WAYLAND_DISPLAY= run "$OVERLAY" --print-position
    [ "$status" -eq 0 ]
    [ "$output" = "unset" ]
}

@test "--check fails outside a Wayland session" {
    WAYLAND_DISPLAY= run "$OVERLAY" --check
    [ "$status" -eq 1 ]
}

@test "rendering outside a Wayland session is a silent no-op" {
    WAYLAND_DISPLAY= run "$OVERLAY"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--place outside a Wayland session is a silent no-op" {
    WAYLAND_DISPLAY= run "$OVERLAY" --place
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "audio on stdin is never written anywhere" {
    # The renderer computes a level and nothing else: no file may appear.
    before=$(find "$HOME" -type f | wc -l)
    WAYLAND_DISPLAY= run bash -c "head -c 4000 /dev/urandom | '$OVERLAY'"
    [ "$status" -eq 0 ]
    [ "$(find "$HOME" -type f | wc -l)" -eq "$before" ]
}
