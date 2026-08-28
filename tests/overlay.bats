#!/usr/bin/env bats
# Tests for bin/sayit-overlay — the parts that need no desktop: position
# storage, availability reporting and the never-break-dictation exits.
# WAYLAND_DISPLAY is cleared so every case is deterministic on any machine;
# no window is ever created.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME"
    # Sandboxed too: the resident's FIFO and PID file live here, and a test
    # must never reach for -- or signal -- a real overlay on the machine.
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
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

@test "--resident outside a Wayland session reports the failure" {
    # Unlike the meter path, a resident overlay is nothing's dependency, and
    # saying so is what lets the service unit retry once the session is up.
    WAYLAND_DISPLAY= run "$OVERLAY" --resident
    [ "$status" -eq 1 ]
}

# The FIFO and PID handling has no window in it, so it is reachable directly.
# load_overlay makes the script importable under a name Python accepts.
load_overlay() {
    python3 - "$OVERLAY" "$@" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("sayit_overlay", sys.argv[1])
spec = importlib.util.spec_from_loader("sayit_overlay", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(eval(sys.argv[2], {"ov": mod, "os": __import__("os")}))
PY
}

@test "the resident FIFO is created as a FIFO and read-write to nobody else" {
    run load_overlay 'ov.open_fifo() is not None'
    [ "$output" = "True" ]
    [ -p "$XDG_RUNTIME_DIR/sayit.overlay" ]
    run stat -c '%a' "$XDG_RUNTIME_DIR/sayit.overlay"
    [ "$output" = "600" ]
}

@test "a plain file squatting on the FIFO name is replaced" {
    echo "not a fifo" > "$XDG_RUNTIME_DIR/sayit.overlay"
    run load_overlay 'ov.open_fifo() is not None'
    [ "$output" = "True" ]
    [ -p "$XDG_RUNTIME_DIR/sayit.overlay" ]
}

@test "no PID file means no resident" {
    run load_overlay 'ov.resident_pid()'
    [ "$output" = "None" ]
}

@test "a PID belonging to another process is never reported as the resident" {
    # The identity check is the whole point: signalling a recycled PID would
    # send SIGUSR1 to something that never asked for it.
    sleep 30 &
    other=$!
    echo "$other" > "$XDG_RUNTIME_DIR/sayit.overlay.pid"
    run load_overlay 'ov.resident_pid()'
    kill "$other" 2>/dev/null || true
    [ "$output" = "None" ]
}

@test "a malformed PID file is not a resident either" {
    echo "not-a-number" > "$XDG_RUNTIME_DIR/sayit.overlay.pid"
    run load_overlay 'ov.resident_pid()'
    [ "$output" = "None" ]
}

@test "our own PID is reported, since this process names sayit-overlay" {
    # python3 running the overlay file has it on its command line, which is
    # exactly the shape a real resident has, so writing the PID file and
    # reading it back must come out as this very process.
    run load_overlay '[ov.write_pid(), ov.resident_pid() == os.getpid()][1]'
    [ "$output" = "True" ]
}

@test "clear_runtime removes both the FIFO and the PID file" {
    run load_overlay '(ov.open_fifo() is not None, ov.write_pid(), ov.clear_runtime())'
    [ ! -e "$XDG_RUNTIME_DIR/sayit.overlay" ]
    [ ! -e "$XDG_RUNTIME_DIR/sayit.overlay.pid" ]
}

# --- what the pill is allowed to claim ------------------------------------
# The pill is drawn the same whether or not it is recording. MOVEMENT is the
# only difference: the bars rise and fall while audio drives them and stand
# still otherwise. Nothing else animates, because a pill that moves while
# nothing is listening is telling the user something untrue.

levels() {   # active -> "ink lamp"
    load_overlay "'%.3f %.3f' % ov.draw_levels($1)"
}

@test "resting and recording are drawn identically" {
    # The whole point: no greying out between dictations. Only the bar
    # heights, computed from the level outside this function, differ.
    rest=$(levels False)
    live=$(levels True)
    [ "$rest" = "$live" ]
    [ "$rest" = "1.000 1.000" ]
}

@test "the drawing depends on nothing but whether audio is arriving" {
    # No frame counter, no placing flag: there is nothing left that could
    # make the pill animate on its own.
    run load_overlay "ov.draw_levels.__code__.co_argcount"
    [ "$output" = "1" ]
}

@test "the idle knobs are what fade the pill, and they default to no fade" {
    run load_overlay "'%.2f %.2f' % (ov.IDLE_INK, ov.IDLE_LAMP)"
    [ "$output" = "1.00 1.00" ]
}

# --- who can grab the pill ------------------------------------------------
# A resident pill is a fixture the user has to be able to move, so it keeps a
# normal input region and a drag moves it. A piped one is on screen for the
# seconds a recording lasts and must never be in the way, so its input region
# is empty and every click passes through. The choice is made before the
# window is mapped and never revisited: an empty input region cannot be taken
# back on a mapped layer-shell surface.

@test "dragging is not gated on a mode any more" {
    # Regression: the drag handlers used to return early unless a placing
    # mode was on, and that mode could never actually receive a click.
    run bash -c "grep -A2 'def on_press' '$OVERLAY' | grep -c place_mode"
    [ "$output" = "0" ]
    run bash -c "grep -A3 'def on_motion' '$OVERLAY' | grep -c place_mode"
    [ "$output" = "0" ]
}

@test "only the piped pill is given an empty input region" {
    run bash -c "sed -n '/def on_realize/,/input_shape_combine_region/p' '$OVERLAY' \
        | grep -c 'if self.resident or self.place_mode'"
    [ "$output" = "1" ]
}

@test "the input region is never touched after the window is built" {
    # One call site, inside on_realize. A second one would mean something is
    # trying to change it on a mapped surface, which does not work.
    run bash -c "grep -c input_shape_combine_region '$OVERLAY'"
    [ "$output" = "1" ]
}

@test "--place against a running resident draws no second pill" {
    printf '# resident\n' > "$XDG_RUNTIME_DIR/sayit.overlay"
    load_overlay 'ov.write_pid()' >/dev/null
    # No Wayland session here, so this exercises the argument handling only.
    WAYLAND_DISPLAY= run "$OVERLAY" --place
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
