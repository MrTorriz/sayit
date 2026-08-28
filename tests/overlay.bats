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

# --- geometry and the three states ----------------------------------------
# The pill is 160x32 with an eight-bar meter growing about its centre line,
# and a lamp that means one thing only: the microphone is open. Between "open
# and silent" and "open and speaking" the meter is the ONLY thing that moves.

@test "the pill is 160x40 with a 12 px radius" {
    run load_overlay "(ov.WIDTH, ov.HEIGHT, ov.RADIUS)"
    [ "$output" = "(160, 40, 12)" ]
}

@test "the height fills a 44 px panel with room to spare" {
    # A default Plasma panel measures 44 px. At 40 the pill fills it with 2 px
    # top and bottom rather than floating in the middle of it, and EDGE_MARGIN
    # has to be small enough to let it be dropped that high.
    run load_overlay "(44 - ov.HEIGHT) // 2"
    [ "$output" = "2" ]
    run load_overlay "ov.EDGE_MARGIN <= (44 - ov.HEIGHT) // 2"
    [ "$output" = "True" ]
}

@test "the meter has ten bars" {
    run load_overlay "(ov.BAR_COUNT, len(ov.BAR_MAX_U), len(ov.bar_heights(7)))"
    [ "$output" = "(10, 10, 10)" ]
}

@test "at rest every bar is a dot, as wide as it is tall" {
    run load_overlay "set(ov.bar_heights(0)) == {ov.BAR_U}"
    [ "$output" = "True" ]
}

@test "speaking makes every bar grow, none shrink" {
    run load_overlay "all(b > a for a, b in zip(ov.bar_heights(0), ov.bar_heights(7)))"
    [ "$output" = "True" ]
}

@test "the bars are drawn about a shared centre line, not off a baseline" {
    # Every bar's vertical midpoint must be the same, at every level: that is
    # what keeps the row level with the lamp instead of sinking to the floor.
    run load_overlay "[round(cy, 6) for cy in ov._test_bar_midpoints(0)]"
    mitt_vila="$output"
    run load_overlay "[round(cy, 6) for cy in ov._test_bar_midpoints(7)]"
    [ "$output" = "$mitt_vila" ]
    run load_overlay "len(set(ov._test_bar_midpoints(7))) == 1"
    [ "$output" = "True" ]
}

@test "the resting row sits at the same height as the lamp" {
    run load_overlay "abs(ov._test_bar_midpoints(0)[0] - ov.HEIGHT / 2.0) < 1e-9"
    [ "$output" = "True" ]
}

@test "reading order is lamp, meter, wordmark, centred as one group" {
    run load_overlay "round(ov.CONTENT_X, 4) == round((ov.WIDTH - ov.CONTENT_W) / 2, 4)"
    [ "$output" = "True" ]
    run load_overlay "round(ov.CONTENT_W, 4) == round(ov.LAMP_W + ov.LAMP_GAP + ov.WAVE_W + ov.LAYOUT_GAP + ov.WORDMARK_W, 4)"
    [ "$output" = "True" ]
}

@test "the wordmark is stored as outlines, needing no font at runtime" {
    # A font that is missing, or simply different, must not change the pill.
    run load_overlay "len(ov.WORDMARK) > 50"
    [ "$output" = "True" ]
    run load_overlay "sorted({s[0] for s in ov.WORDMARK}) == ['c', 'l', 'm', 'z']"
    [ "$output" = "True" ]
    run bash -c "grep -cE 'show_text|text_path|Pango|toy_font|select_font_face' '$OVERLAY'"
    [ "$output" = "0" ]
}

@test "the wordmark outlines are normalised, so one number sets its size" {
    run load_overlay "all(0.0 <= v <= max(3.0, ov.WORDMARK_ASPECT) for s in ov.WORDMARK for v in s[1:])"
    [ "$output" = "True" ]
    run load_overlay "round(ov.WORDMARK_W / ov.WORDMARK_H, 6) == ov.WORDMARK_ASPECT"
    [ "$output" = "True" ]
}

@test "a closed microphone leaves the lamp unlit" {
    # The strongest claim the pill makes. It may never be made falsely: an
    # unlit lamp is still drawn, so the pill stays whole, but it must never
    # carry the lit colour while the microphone is shut.
    run load_overlay "(ov._test_state(active=False)['lamp'], ov._test_state(active=False)['lamp_lit'])"
    [ "$output" = "(True, False)" ]
    run load_overlay "ov._test_state(active=False)['lamp_rgb'] == ov.LAMP_UNLIT"
    [ "$output" = "True" ]
}

@test "an open microphone lights the lamp, silent or not" {
    run load_overlay "ov._test_state(active=True)['lamp_lit']"
    [ "$output" = "True" ]
    run load_overlay "ov._test_state(active=True, level=0)['lamp_rgb'] == ov._test_state(active=True, level=6)['lamp_rgb'] == ov.LAMP_LIT"
    [ "$output" = "True" ]
}

@test "lit and unlit are different colours, and unlit is the darker" {
    run load_overlay "ov.LAMP_LIT != ov.LAMP_UNLIT and sum(ov.LAMP_UNLIT) < sum(ov.LAMP_LIT)"
    [ "$output" = "True" ]
}

@test "a window opened only to be placed never lights the lamp" {
    run load_overlay "ov._test_state(active=False, place_mode=True)['lamp_lit']"
    [ "$output" = "False" ]
}

@test "the lamp keeps its place and size whether lit or not" {
    # Colour is the whole signal: nothing moves, nothing resizes.
    run bash -c "sed -n '/def draw_lamp/,/cr.fill()/p' '$OVERLAY' | grep -c 'LAMP_W / 2.0'"
    [ "$output" = "1" ]
}

@test "silence and speech differ in the meter and in nothing else" {
    tyst=$(load_overlay "ov._test_state(active=True, level=0)")
    tal=$(load_overlay "ov._test_state(active=True, level=6)")
    [ "$tyst" != "$tal" ]
    # Everything except the bar heights must be byte-identical.
    run load_overlay "{k: v for k, v in ov._test_state(active=True, level=0).items() if k != 'bars'} == {k: v for k, v in ov._test_state(active=True, level=6).items() if k != 'bars'}"
    [ "$output" = "True" ]
}

@test "nothing on the pill pulses or fades over time" {
    # No frame counter reaches the drawing any more: same inputs, same pixels.
    run load_overlay "ov.bar_heights.__code__.co_argcount"
    [ "$output" = "1" ]
    run bash -c "sed -n '/def on_draw/,/return False/p' '$OVERLAY' | grep -cE 'self\.frame|math\.sin'"
    [ "$output" = "0" ]
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
