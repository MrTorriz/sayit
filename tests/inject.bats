#!/usr/bin/env bats
# Tests for bin/sayit-inject. Every injector (wl-copy, wl-paste, ydotool,
# wtype, xdotool) is a PATH stub — no compositor, clipboard or input device
# is touched. Clipboard state is simulated with files in the control dir.

setup() {
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"

    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    # wl-paste stub: --list-types prints $CLIP_TYPES; -n prints the current
    # simulated clipboard ($STUB_CTL/clipboard) or primary selection.
    cat > "$STUBBIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--list-types" || "$1" == "-l" ]]; then
    printf '%s\n' "${CLIP_TYPES:-text/plain;charset=utf-8}" | tr ';' '\n'
    exit 0
fi
if [[ "$*" == *"--primary"* ]]; then
    [[ -f "$STUB_CTL/primary" ]] || exit 1
    cat "$STUB_CTL/primary"
    exit 0
fi
echo "wl-paste $*" >> "$STUB_CTL/calls.log"
[[ -f "$STUB_CTL/clipboard" ]] || exit 1
cat "$STUB_CTL/clipboard"
EOF

    # wl-copy stub: records what was copied where.
    cat > "$STUBBIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--primary"* && "$*" == *"--clear"* ]]; then
    echo "primary-clear" >> "$STUB_CTL/calls.log"
    exit 0
fi
data=$(cat)
if [[ "$*" == *"--primary"* ]]; then
    printf '%s' "$data" > "$STUB_CTL/primary"
    echo "wl-copy-primary" >> "$STUB_CTL/calls.log"
else
    printf '%s' "$data" > "$STUB_CTL/clipboard"
    echo "wl-copy" >> "$STUB_CTL/calls.log"
fi
EOF

    # ydotool stub: key succeeds unless told to fail; type logs its text.
    cat > "$STUBBIN/ydotool" <<'EOF'
#!/usr/bin/env bash
echo "ydotool $*" >> "$STUB_CTL/calls.log"
[[ "$1" == key  && -f "$STUB_CTL/ydotool-key.fail"  ]] && exit 1
[[ "$1" == type && -f "$STUB_CTL/ydotool-type.fail" ]] && exit 1
exit 0
EOF

    cat > "$STUBBIN/wtype" <<'EOF'
#!/usr/bin/env bash
echo "wtype $*" >> "$STUB_CTL/calls.log"
[[ -f "$STUB_CTL/wtype.fail" ]] && exit 1
exit 0
EOF

    cat > "$STUBBIN/xdotool" <<'EOF'
#!/usr/bin/env bash
echo "xdotool $*" >> "$STUB_CTL/calls.log"
exit 0
EOF

    chmod +x "$STUBBIN"/*
    export PATH="$STUBBIN:$PATH"
    export XDG_SESSION_TYPE=wayland

    INJECT="$BATS_TEST_DIRNAME/../bin/sayit-inject"
}

# Make a tool unusable without removing it from PATH — deleting the stub
# would fall through to a REAL system binary on developer machines.
break_stub() {
    local t
    for t in "$@"; do
        printf '#!/usr/bin/env bash\nexit 127\n' > "$STUBBIN/$t"
        chmod +x "$STUBBIN/$t"
    done
}

@test "happy path: copies to clipboard and primary, pastes with Shift+Insert" {
    printf 'previous content' > "$STUB_CTL/clipboard"
    run "$INJECT" "hej världen åäö"
    [ "$status" -eq 0 ]
    grep -q "ydotool key 42:1 110:1 110:0 42:0" "$STUB_CTL/calls.log"
    [ -f "$STUB_CTL/primary" ]
    [ "$(cat "$STUB_CTL/primary")" = "hej världen åäö" ]
}

@test "previous text clipboard is restored and primary cleared after the delay" {
    printf 'previous content' > "$STUB_CTL/clipboard"
    # Background the injector: the restore runs ~1 s later in a detached
    # subshell, and we must observe the clipboard both during and after.
    "$INJECT" "dictated text" >/dev/null 2>&1 &
    sleep 0.4
    [ "$(cat "$STUB_CTL/clipboard")" = "dictated text" ]   # paste window
    sleep 1.2
    [ "$(cat "$STUB_CTL/clipboard")" = "previous content" ]  # restored
    grep -q "primary-clear" "$STUB_CTL/calls.log"
}

@test "restore is skipped when the user changed the clipboard meanwhile" {
    printf 'previous content' > "$STUB_CTL/clipboard"
    "$INJECT" "dictated text" >/dev/null 2>&1 &
    sleep 0.4
    printf 'user copied this' > "$STUB_CTL/clipboard"   # copy inside the window
    sleep 1.2
    [ "$(cat "$STUB_CTL/clipboard")" = "user copied this" ]
    grep -q "primary-clear" "$STUB_CTL/calls.log"
}

@test "a primary selection the user made meanwhile is never cleared" {
    printf 'previous content' > "$STUB_CTL/clipboard"
    "$INJECT" "dictated text" >/dev/null 2>&1 &
    sleep 0.4
    printf 'user selection' > "$STUB_CTL/primary"   # select inside the window
    sleep 1.2
    ! grep -q "primary-clear" "$STUB_CTL/calls.log"
    [ "$(cat "$STUB_CTL/primary")" = "user selection" ]
}

@test "non-text clipboard is never saved or clobbered by a restore" {
    printf 'PNGBYTES' > "$STUB_CTL/clipboard"
    CLIP_TYPES="image/png" run "$INJECT" "dictated text"
    [ "$status" -eq 0 ]
    # No wl-paste -n read of the image content may occur.
    ! grep -q "wl-paste -n" "$STUB_CTL/calls.log"
    sleep 1.4
    # The dictation stays on the clipboard; the image is not re-offered as text.
    [ "$(cat "$STUB_CTL/clipboard")" = "dictated text" ]
}

@test "password-manager-hinted clipboard is never read or re-offered" {
    printf 'secret' > "$STUB_CTL/clipboard"
    CLIP_TYPES="text/plain;x-kde-passwordManagerHint" run "$INJECT" "dictated"
    [ "$status" -eq 0 ]
    ! grep -q "wl-paste -n" "$STUB_CTL/calls.log"
    sleep 1.4
    [ "$(cat "$STUB_CTL/clipboard")" = "dictated" ]
}

@test "total failure never leaks the text to a non-tty stdout" {
    break_stub wl-copy wl-paste wtype xdotool
    touch "$STUB_CTL/ydotool-type.fail" "$STUB_CTL/ydotool-key.fail"
    run "$INJECT" "very private dictation"
    [ "$status" -eq 1 ]
    [[ "$output" != *"very private dictation"* ]]
    [[ "$output" == *sayit-history* ]]
}

@test "xdotool is never used in a Wayland session" {
    break_stub wl-copy wl-paste wtype
    touch "$STUB_CTL/ydotool-type.fail" "$STUB_CTL/ydotool-key.fail"
    XDG_SESSION_TYPE=wayland run "$INJECT" "text"
    [ "$status" -eq 1 ]
    ! grep -q "xdotool" "$STUB_CTL/calls.log"
}

@test "on X11 the layout-aware xdotool is preferred over ydotool type" {
    break_stub wl-copy wl-paste
    XDG_SESSION_TYPE=x11 run "$INJECT" "text åäö"
    [ "$status" -eq 0 ]
    grep -q "xdotool type" "$STUB_CTL/calls.log"
    ! grep -q "ydotool type" "$STUB_CTL/calls.log"
}

@test "failed paste keystroke falls back to ydotool type on Wayland" {
    printf 'prev' > "$STUB_CTL/clipboard"
    touch "$STUB_CTL/ydotool-key.fail"
    run "$INJECT" "text"
    [ "$status" -eq 0 ]
    grep -q "ydotool type" "$STUB_CTL/calls.log"
}
