#!/usr/bin/env bats
# Tests for the macOS branches of bin/ and install.sh. Every script runs from
# a sandboxed copy of the repo with OSTYPE=darwin27 in the environment (bash
# takes OSTYPE from there), so these tests run on a Linux host too. Sayit.app's
# helpers, sayit-rec and sayit-paste, are stubs found through
# SAYIT_MAC_HELPERS, and the Linux tools are logging stubs that must never be
# called. No microphone, clipboard, keystroke, LaunchAgent or real .env is
# ever touched. The few tests that need a host without /proc skip elsewhere.

setup() {
    export OSTYPE=darwin27
    unset AUDIO_SOURCE MAX_RECORD_SECONDS INJECT_METHOD RECORDING_INDICATOR \
          MODEL_PATH SAYIT_MODEL WORDLIST INITIAL_PROMPT SAYIT_DAEMON_LOG 2>/dev/null || true

    SANDBOX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"
    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    # The Linux tools: any call at all is a failure on the macOS path.
    local t
    for t in notify-send gdbus pactl pw-record pw-cat wl-copy wl-paste ydotool \
             wtype xdotool espeak-ng; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_CTL/linux.log"\n' "$t" > "$STUBBIN/$t"
    done
    chmod +x "$STUBBIN"/*
    export PATH="$STUBBIN:$PATH"

    HELPERS="$BATS_TEST_TMPDIR/helpers"
    install_helpers "$HELPERS"
    export SAYIT_MAC_HELPERS="$HELPERS"

    RUN_DIR="$XDG_RUNTIME_DIR"
    STATUS="$XDG_RUNTIME_DIR/sayit.status"
    MARKER="$XDG_RUNTIME_DIR/sayit.indicator.on"
}

teardown() {
    pkill -f "$HELPERS/sayit-rec" 2>/dev/null || true
    sleep 0.3
}

# install_helpers <dir> — stub sayit-rec and sayit-paste into <dir>.
#
# sayit-rec records its PID, argv, path and environment, then exits with
# rec.exit (default 0) — or, with rec.live, behaves like a recorder: writes
# START, and FINAL after a short flush once SIGINT/SIGTERM arrives.
# sayit-paste stores stdin, its argument count, INJECT_METHOD and
# PASTE_RESTORE_DELAY, and exits with paste.exit (default 0).
install_helpers() {
    mkdir -p "$1"
    cat > "$1/sayit-rec" <<'EOF'
#!/usr/bin/env bash
OUT="${1:-}"
printf '%s\n' "$$" > "$STUB_CTL/rec.pid"
printf '%s\n' "$0" > "$STUB_CTL/rec.path"
printf '[%s]' "$@" > "$STUB_CTL/rec.args"
printf '%s\n' "${MAX_RECORD_SECONDS-unset}" > "$STUB_CTL/rec.max"
printf '%s\n' "${XDG_RUNTIME_DIR-unset}" > "$STUB_CTL/rec.rundir"
echo start >> "$STUB_CTL/rec.log"
[[ -f "$STUB_CTL/rec.exit" ]] && exit "$(cat "$STUB_CTL/rec.exit")"
[[ -f "$STUB_CTL/rec.live" ]] || exit 0
trap 'sleep 0.2; printf "FINAL" >> "$OUT"; exit 0' INT TERM
printf 'START ' > "$OUT"
while :; do sleep 0.05; done
EOF
    cat > "$1/sayit-paste" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" > "$STUB_CTL/paste.path"
cat > "$STUB_CTL/paste.stdin"
printf '%s\n' "$#" > "$STUB_CTL/paste.argc"
printf '%s\n' "${INJECT_METHOD-unset}" > "$STUB_CTL/paste.method"
printf '%s\n' "${PASTE_RESTORE_DELAY-unset}" > "$STUB_CTL/paste.delay"
exit "$(cat "$STUB_CTL/paste.exit" 2>/dev/null || echo 0)"
EOF
    chmod +x "$1/sayit-rec" "$1/sayit-paste"
}

# The helper lookup ends in /Applications, which the sandbox cannot redirect.
no_system_app() {
    [[ ! -e /Applications/Sayit.app ]] \
        || skip "a system-wide Sayit.app is installed; its absence cannot be simulated"
}

# fake_getconf — unset XDG_RUNTIME_DIR and answer DARWIN_USER_TEMP_DIR with a
# sandbox directory, trailing slash included, as the real getconf does.
fake_getconf() {
    DARWIN_TMP="$BATS_TEST_TMPDIR/darwin-tmp"
    mkdir -p "$DARWIN_TMP"
    cat > "$STUBBIN/getconf" <<EOF
#!/usr/bin/env bash
echo "getconf \$*" >> "$STUB_CTL/getconf.log"
[[ "\$1" == DARWIN_USER_TEMP_DIR ]] || exit 1
printf '%s/\n' "$DARWIN_TMP"
EOF
    chmod +x "$STUBBIN/getconf"
    unset XDG_RUNTIME_DIR
}

# --- sayit-record -----------------------------------------------------------

@test "sayit-record execs sayit-rec with the WAV, the source and the time cap" {
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav" "Studio Mic"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/rec.args")" = "[$BATS_TEST_TMPDIR/out.wav][Studio Mic]" ]
    [ "$(cat "$STUB_CTL/rec.max")" = "120" ]
    [ "$(cat "$STUB_CTL/rec.path")" = "$HELPERS/sayit-rec" ]
    [ ! -f "$STUB_CTL/linux.log" ]
}

@test "the recorder replaces sayit-record, so the PID sayit signals is the recorder" {
    # bin/sayit stores the PID it spawned and later sends SIGINT to it. Only an
    # exec makes that PID the recorder's own.
    "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav" &
    pid=$!
    wait "$pid"
    [ "$(cat "$STUB_CTL/rec.pid")" = "$pid" ]
}

@test "AUDIO_SOURCE and MAX_RECORD_SECONDS from .env reach sayit-rec" {
    printf 'AUDIO_SOURCE="alsa_input.usb-Acme_USB_Mic-00.mono-fallback"\nMAX_RECORD_SECONDS=30\n' \
        > "$SANDBOX/.env"
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/rec.args")" = "[$BATS_TEST_TMPDIR/out.wav][alsa_input.usb-Acme_USB_Mic-00.mono-fallback]" ]
    [ "$(cat "$STUB_CTL/rec.max")" = "30" ]
}

@test "an empty source is passed on as empty, and MAX_RECORD_SECONDS from the environment" {
    MAX_RECORD_SECONDS=45 run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/rec.args")" = "[$BATS_TEST_TMPDIR/out.wav][]" ]
    [ "$(cat "$STUB_CTL/rec.max")" = "45" ]
}

@test "the recorder's exit code comes through (2 = microphone permission denied)" {
    echo 2 > "$STUB_CTL/rec.exit"
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 2 ]
}

@test "a missing sayit-rec fails with a clear message" {
    no_system_app
    rm "$HELPERS/sayit-rec"
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sayit-rec missing"* ]]
    [ ! -f "$STUB_CTL/rec.log" ]
}

@test "without SAYIT_MAC_HELPERS, ~/Applications wins over the repository's build" {
    no_system_app
    unset SAYIT_MAC_HELPERS
    BUILD="$SANDBOX/mac/build/Sayit.app/Contents/MacOS"
    install_helpers "$BUILD"
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/rec.path")" = "$BUILD/sayit-rec" ]

    USER_APP="$HOME/Applications/Sayit.app/Contents/MacOS"
    install_helpers "$USER_APP"
    run "$SANDBOX/bin/sayit-record" "$BATS_TEST_TMPDIR/out.wav"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/rec.path")" = "$USER_APP/sayit-rec" ]
}

# --- sayit-inject -----------------------------------------------------------

@test "sayit-inject hands the text to sayit-paste on stdin, never in argv" {
    text=$'hej världen åäö\nrad två $HOME `id` "quoted"'
    run "$SANDBOX/bin/sayit-inject" "$text"
    [ "$status" -eq 0 ]
    cmp <(printf '%s' "$text") "$STUB_CTL/paste.stdin"
    [ "$(cat "$STUB_CTL/paste.argc")" = "0" ]
    [ "$(cat "$STUB_CTL/paste.method")" = "auto" ]
    [ "$(cat "$STUB_CTL/paste.delay")" = "1.0" ]
    [ ! -f "$STUB_CTL/linux.log" ]
}

@test "INJECT_METHOD and PASTE_RESTORE_DELAY reach sayit-paste from the environment and from .env" {
    INJECT_METHOD=type PASTE_RESTORE_DELAY=2.5 run "$SANDBOX/bin/sayit-inject" "text"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/paste.method")" = "type" ]
    [ "$(cat "$STUB_CTL/paste.delay")" = "2.5" ]

    printf 'INJECT_METHOD="clipboard"\nPASTE_RESTORE_DELAY=0.5\n' > "$SANDBOX/.env"
    run "$SANDBOX/bin/sayit-inject" "text"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/paste.method")" = "clipboard" ]
    [ "$(cat "$STUB_CTL/paste.delay")" = "0.5" ]
}

@test "sayit-paste's clipboard outcomes pass through, other failures map to exit 1, the text never echoes" {
    echo 2 > "$STUB_CTL/paste.exit"   # no Accessibility permission
    run "$SANDBOX/bin/sayit-inject" "very private dictation"
    [ "$status" -eq 2 ]
    [[ "$output" != *"very private dictation"* ]]
    echo 3 > "$STUB_CTL/paste.exit"   # Secure Input was on
    run "$SANDBOX/bin/sayit-inject" "very private dictation"
    [ "$status" -eq 3 ]
    echo 9 > "$STUB_CTL/paste.exit"
    run "$SANDBOX/bin/sayit-inject" "very private dictation"
    [ "$status" -eq 1 ]
    [[ "$output" != *"very private dictation"* ]]
}

@test "sayit-inject takes the text on stdin when there is no argument" {
    run bash -c 'printf "from stdin åäö" | "$1"' _ "$SANDBOX/bin/sayit-inject"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/paste.stdin")" = "from stdin åäö" ]
    run bash -c '"$1" < /dev/null' _ "$SANDBOX/bin/sayit-inject"
    [ "$status" -eq 1 ]
    [[ "$output" == *Usage* ]]
}

@test "a missing sayit-paste fails with a clear message" {
    no_system_app
    rm "$HELPERS/sayit-paste"
    run "$SANDBOX/bin/sayit-inject" "very private dictation"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sayit-paste missing"* ]]
    [[ "$output" != *"very private dictation"* ]]
}

# --- sayit-indicator --------------------------------------------------------

@test "indicator show and hide create and remove the marker Sayit.app watches" {
    run "$SANDBOX/bin/sayit-indicator" show "Studio Mic"
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
    run "$SANDBOX/bin/sayit-indicator" hide
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ]
    # No notification, no OSD and no meter of its own: Sayit.app draws the pill.
    [ ! -f "$STUB_CTL/linux.log" ]
    [ ! -f "$XDG_RUNTIME_DIR/sayit.meter" ]
    [ ! -f "$XDG_RUNTIME_DIR/sayit.indicator" ]
}

@test "RECORDING_INDICATOR=0 shows nothing, and hide still clears a marker" {
    RECORDING_INDICATOR=0 run "$SANDBOX/bin/sayit-indicator" show
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ]

    printf 'RECORDING_INDICATOR=0\n' > "$SANDBOX/.env"
    run "$SANDBOX/bin/sayit-indicator" show
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ]

    touch "$MARKER"   # left by a show from before the setting changed
    run "$SANDBOX/bin/sayit-indicator" hide
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ]
}

@test "an unknown indicator command exits 1 with the usage" {
    run "$SANDBOX/bin/sayit-indicator" bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "without XDG_RUNTIME_DIR the indicator marker goes to the per-user temporary directory" {
    fake_getconf
    run "$SANDBOX/bin/sayit-indicator" show
    [ "$status" -eq 0 ]
    [ -f "$DARWIN_TMP/sayit.indicator.on" ]
}

# --- sayit-bt ---------------------------------------------------------------

@test "sayit-bt is a no-op on macOS: nothing switched, nothing printed" {
    run "$SANDBOX/bin/sayit-bt" up
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run "$SANDBOX/bin/sayit-bt" down
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STUB_CTL/linux.log" ]
    [ ! -f "$XDG_RUNTIME_DIR/sayit.bt" ]
}

# --- bin/sayit --------------------------------------------------------------
# The real sayit-bt, sayit-record, sayit-inject and sayit-indicator run here,
# down their macOS branches; only sayit-transcribe and the helpers are stubs.

sayit_sandbox() {
    cat > "$SANDBOX/bin/sayit-transcribe" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$STUB_CTL/transcribe.text" ]]; then cat "$STUB_CTL/transcribe.text"; exit 0; fi
tr '\n' ' ' < "$1"
EOF
    chmod +x "$SANDBOX/bin/sayit-transcribe"
    touch "$STUB_CTL/rec.live"
    SAYIT="$SANDBOX/bin/sayit"
    SESSION="$RUN_DIR/sayit.session"
}

@test "a dictation runs record, paste and the pill marker end to end" {
    sayit_sandbox
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ -f "$SESSION" ]
    [ -f "$MARKER" ]
    [ "$(cat "$STATUS")" = "Recording" ]
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    [ ! -f "$SESSION" ]
    [ ! -f "$MARKER" ]
    # FINAL is only there if the SIGINT reached sayit-rec through sayit-record.
    [ "$(cat "$STUB_CTL/paste.stdin")" = "START FINAL" ]
    [ "$(cat "$STATUS")" = "Done (2 words)" ]
    # The recording lasted at least the start's 0.3 s liveness check.
    python3 -c 'import json, sys; assert json.loads(open(sys.argv[1]).readline())["seconds"] >= 0.3' \
        "$XDG_DATA_HOME/sayit/history.jsonl"
    # notify-send is never used on macOS, even where one is installed.
    [ ! -f "$STUB_CTL/linux.log" ]
}

@test "a Done status never carries the dictated text, while history keeps it" {
    sayit_sandbox
    printf 'secret words ): more secret' > "$STUB_CTL/transcribe.text"
    "$SAYIT" start
    "$SAYIT" stop
    [ "$(cat "$STATUS")" = "Done (5 words)" ]
    [[ "$(cat "$STATUS")" != *secret* ]]
    grep -q "secret words ): more secret" "$XDG_DATA_HOME/sayit/history.jsonl"
}

@test "other statuses reach the status file unchanged, problems with their level" {
    sayit_sandbox
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    [ "$(cat "$STATUS")" = "No recording in progress" ]

    echo 1 > "$STUB_CTL/paste.exit"
    "$SAYIT" start
    "$SAYIT" stop
    [ "$(cat "$STATUS")" = $'Injection failed — recover with: sayit-history --inject\nerror' ]

    echo 2 > "$STUB_CTL/paste.exit"
    "$SAYIT" start
    "$SAYIT" stop
    [[ "$(head -n 1 "$STATUS")" == "Not pasted: Sayit needs the Accessibility permission"*"Cmd+V" ]]
    [ "$(sed -n 2p "$STATUS")" = error ]

    echo 3 > "$STUB_CTL/paste.exit"
    "$SAYIT" start
    "$SAYIT" stop
    [[ "$(head -n 1 "$STATUS")" == "Secure Input is on"*"Cmd+V" ]]
    [ "$(sed -n 2p "$STATUS")" = warn ]
    rm "$STUB_CTL/paste.exit"

    "$SAYIT" start
    "$SAYIT" cancel
    [ "$(cat "$STATUS")" = "Recording cancelled — nothing injected" ]
    [ ! -f "$STUB_CTL/linux.log" ]
}

@test "without XDG_RUNTIME_DIR, sayit uses the per-user temporary directory and exports it" {
    sayit_sandbox
    fake_getconf
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    # The trailing slash is gone: the session's WAV is a direct child.
    wav=$(cut -f2 "$DARWIN_TMP/sayit.session")
    [[ "$wav" == "$DARWIN_TMP"/sayit-*.wav && "$wav" != *//* ]]
    [ -f "$DARWIN_TMP/sayit.indicator.on" ]
    [ "$(cat "$DARWIN_TMP/sayit.status")" = "Recording" ]
    # Exported: the recorder sees it, and no child had to ask getconf again.
    [ "$(cat "$STUB_CTL/rec.rundir")" = "$DARWIN_TMP" ]
    [ "$(grep -c . "$STUB_CTL/getconf.log")" -eq 1 ]
    "$SAYIT" cancel
}

@test "without /proc, a live recorder is recognised through ps" {
    [[ ! -d /proc ]] || skip "this host has /proc, so ps is never consulted"
    sayit_sandbox
    "$SAYIT" start
    run "$SAYIT" start
    [ "$status" -eq 0 ]
    [ "$(cat "$STATUS")" = "Already recording" ]
    [ "$(grep -c start "$STUB_CTL/rec.log")" -eq 1 ]
    pid=$(cut -f1 "$SESSION")
    "$SAYIT" cancel
    run kill -0 "$pid"
    [ "$status" -ne 0 ]
}

@test "without /proc, a recycled PID is never signalled" {
    [[ ! -d /proc ]] || skip "this host has /proc, so ps is never consulted"
    sayit_sandbox
    sleep 30 &
    other=$!
    printf '%s\t%s\t1\n' "$other" "$RUN_DIR/sayit-x.wav" > "$SESSION"
    touch "$RUN_DIR/sayit-x.wav"
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    kill -0 "$other"   # the innocent process must still be alive
    kill "$other" 2>/dev/null || true
}

@test "without /proc, SAYIT_PROFILE measures uptime from kern.boottime" {
    [[ ! -d /proc ]] || skip "this host has /proc/uptime"
    sayit_sandbox
    SAYIT_PROFILE=1 run "$SAYIT" stop
    [ "$status" -eq 0 ]
    line=$(grep ',stop.enter,' "$RUN_DIR/sayit-profile.csv")
    up=$(cut -d, -f3 <<< "$line")
    [[ "$up" =~ ^[0-9]+\.[0-9]+$ ]]
    # Seconds since boot, not since the epoch: a failed boottime parse would
    # leave the wall clock here.
    (( ${up%.*} < 1000000000 ))
}

# --- sayit-transcribe -------------------------------------------------------

transcribe_sandbox() {
    cat > "$STUBBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CTL/curl.args"
[[ "${CURL_MODE:-ok}" == fail ]] && exit 7
printf 'daemon text'
EOF
    cat > "$BATS_TEST_TMPDIR/whisper-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CTL/cli.args"
printf 'cli text'
EOF
    chmod +x "$STUBBIN/curl" "$BATS_TEST_TMPDIR/whisper-cli"
    export WHISPER_CLI="$BATS_TEST_TMPDIR/whisper-cli"
    MODELS="$SANDBOX/models"
    mkdir -p "$MODELS"
    MEDIUM="$MODELS/ggml-kb-whisper-medium-q5_0.bin"
    LARGE="$MODELS/ggml-kb-whisper-large-q5_0.bin"
    printf 'model' > "$MEDIUM"
    TRANSCRIBE="$SANDBOX/bin/sayit-transcribe"
    WAV="$BATS_TEST_TMPDIR/test.wav"
    head -c 64000 /dev/zero > "$WAV"   # 2 s of 16 kHz s16 mono
}

@test "an empty WAV answers empty without contacting either path" {
    transcribe_sandbox
    head -c 44 /dev/zero > "$WAV"
    run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STUB_CTL/curl.args" ]
    [ ! -f "$STUB_CTL/cli.args" ]
}

@test "the curl deadline comes from the portable file size" {
    transcribe_sandbox
    head -c 320000 /dev/zero > "$WAV"   # 10 s of audio -> deadline 20 s
    run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "daemon text" ]
    grep -q -- '-m 20' "$STUB_CTL/curl.args"
}

@test "Apple Silicon defaults to the large model when it is installed" {
    transcribe_sandbox
    printf 'model' > "$LARGE"
    HOSTTYPE=aarch64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "cli text" ]
    grep -q -- "-m $LARGE " "$STUB_CTL/cli.args"
}

@test "Apple Silicon keeps medium when large is not installed" {
    transcribe_sandbox
    HOSTTYPE=aarch64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- "-m $MEDIUM " "$STUB_CTL/cli.args"
}

@test "Intel Macs and Linux keep the medium default even with large installed" {
    transcribe_sandbox
    printf 'model' > "$LARGE"
    HOSTTYPE=x86_64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- "-m $MEDIUM " "$STUB_CTL/cli.args"
    OSTYPE=linux-gnu HOSTTYPE=aarch64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- "-m $MEDIUM " "$STUB_CTL/cli.args"
}

@test "MODEL_PATH and SAYIT_MODEL still win over the macOS default" {
    transcribe_sandbox
    printf 'model' > "$LARGE"
    printf 'MODEL_PATH="%s"\n' "$MEDIUM" > "$SANDBOX/.env"
    HOSTTYPE=aarch64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    grep -q -- "-m $MEDIUM " "$STUB_CTL/cli.args"
    ALT="$BATS_TEST_TMPDIR/alt.bin"
    printf 'alt' > "$ALT"
    SAYIT_MODEL="$ALT" HOSTTYPE=aarch64 CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    grep -q -- "-m $ALT " "$STUB_CTL/cli.args"
}

@test "without XDG_RUNTIME_DIR the transcriber's profile goes to the per-user temporary directory" {
    transcribe_sandbox
    fake_getconf
    head -c 44 /dev/zero > "$WAV"
    SAYIT_PROFILE=1 run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q ',t.empty,' "$DARWIN_TMP/sayit-profile.csv"
}

@test "a failed start keeps its reason: the release's stop does not replace it" {
    sayit_sandbox
    rm "$STUB_CTL/rec.live"
    cat > "$HELPERS/sayit-rec" <<'EOF'
#!/usr/bin/env bash
echo 'sayit-rec: no input device matches "Studio Mic" (available: Built-in)' >&2
exit 1
EOF
    run "$SAYIT" start
    [ "$status" -eq 1 ]
    [ "$(head -n 1 "$STATUS")" = 'Recording failed to start: no input device matches "Studio Mic" (available: Built-in)' ]
    [ "$(sed -n 2p "$STATUS")" = error ]
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    [[ "$(head -n 1 "$STATUS")" == "Recording failed to start: no input device"* ]]
    # An old failure no longer holds the line.
    touch -t 202001010000 "$STATUS"
    run "$SAYIT" stop
    [ "$(cat "$STATUS")" = "No recording in progress" ]
}

@test "a recording whose recorder already ended says so, and the busy marker goes away" {
    sayit_sandbox
    "$SAYIT" start
    kill -TERM "$(cat "$STUB_CTL/rec.pid")"
    sleep 0.5
    run "$SAYIT" stop
    [ "$status" -eq 0 ]
    [ "$(cat "$STATUS")" = "Done (2 words; the recording had already stopped)" ]
    [ ! -f "$RUN_DIR/sayit.busy" ]
}

# --- sayit-daemon -----------------------------------------------------------

daemon_sandbox() {
    transcribe_sandbox
    cat > "$BATS_TEST_TMPDIR/whisper-server" <<'EOF'
#!/usr/bin/env bash
echo "server $*"
EOF
    chmod +x "$BATS_TEST_TMPDIR/whisper-server"
    export WHISPER_SERVER="$BATS_TEST_TMPDIR/whisper-server"
    DAEMON="$SANDBOX/bin/sayit-daemon"
}

@test "the daemon picks the same macOS default model as the fallback" {
    daemon_sandbox
    HOSTTYPE=aarch64 run "$DAEMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--model $MEDIUM "* ]]
    printf 'model' > "$LARGE"
    HOSTTYPE=aarch64 run "$DAEMON"
    [[ "$output" == *"--model $LARGE "* ]]
    HOSTTYPE=x86_64 run "$DAEMON"
    [[ "$output" == *"--model $MEDIUM "* ]]
}

@test "SAYIT_DAEMON_LOG collects the server output and starts afresh past 1 MiB" {
    daemon_sandbox
    LOG="$HOME/Library/Logs/sayit/daemon.log"
    SAYIT_DAEMON_LOG="$LOG" run "$DAEMON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q "^server --model" "$LOG"
    [ ! -f "$LOG.1" ]

    SAYIT_DAEMON_LOG="$LOG" run "$DAEMON"
    [ "$(grep -c "^server" "$LOG")" -eq 2 ]   # appended, not truncated

    head -c 1048577 /dev/zero > "$LOG"
    SAYIT_DAEMON_LOG="$LOG" run "$DAEMON"
    [ "$(wc -c < "$LOG.1")" -eq 1048577 ]
    [ "$(grep -c "^server" "$LOG")" -eq 1 ]
}

@test "the daemon serves under a fresh private path that sayit-transcribe and only the user can read" {
    daemon_sandbox
    run "$DAEMON"
    [ "$status" -eq 0 ]
    prefix=$(cat "$RUN_DIR/sayit-daemon.path")
    [[ "$prefix" =~ ^/[0-9a-f]{32}$ ]]
    [[ "$output" == *"--request-path $prefix"* ]]
    [ "$(ls -l "$RUN_DIR/sayit-daemon.path" | cut -c1-10)" = "-rw-------" ]
    run "$DAEMON"
    [ "$(cat "$RUN_DIR/sayit-daemon.path")" != "$prefix" ]

    prefix=$(cat "$RUN_DIR/sayit-daemon.path")
    run "$TRANSCRIBE" "$WAV"
    [ "$output" = "daemon text" ]
    grep -q -- "http://127.0.0.1:9876$prefix/inference" "$STUB_CTL/curl.args"
    # Anything else in the file is ignored.
    printf '/../load\n' > "$RUN_DIR/sayit-daemon.path"
    run "$TRANSCRIBE" "$WAV"
    grep -q -- "http://127.0.0.1:9876/inference" "$STUB_CTL/curl.args"
}

@test "a fallback to the cold CLI is announced in the status file" {
    transcribe_sandbox
    printf 'model' > "$LARGE"
    CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "cli text" ]
    [[ "$(cat "$STATUS")" == "Transcribing without the server"* ]]
}

@test "a daemon that cannot start says why in SAYIT_DAEMON_LOG" {
    daemon_sandbox
    LOG="$HOME/Library/Logs/sayit/daemon.log"
    WHISPER_SERVER=/nonexistent SAYIT_DAEMON_LOG="$LOG" run "$DAEMON"
    [ "$status" -eq 1 ]
    grep -q "whisper-server missing" "$LOG"
    MODEL_PATH=/nonexistent/model.bin SAYIT_DAEMON_LOG="$LOG" run "$DAEMON"
    [ "$status" -eq 1 ]
    grep -q "Model missing: /nonexistent/model.bin" "$LOG"
}

# --- sayit-doctor -----------------------------------------------------------

@test "sayit-doctor and sayit doctor hand over to mac/sayit-doctor with their arguments" {
    mkdir -p "$SANDBOX/mac"
    printf '#!/usr/bin/env bash\necho "mac doctor [$*]"\n' > "$SANDBOX/mac/sayit-doctor"
    chmod +x "$SANDBOX/mac/sayit-doctor"
    run "$SANDBOX/bin/sayit-doctor" --quiet
    [ "$status" -eq 0 ]
    [ "$output" = "mac doctor [--quiet]" ]
    run "$SANDBOX/bin/sayit" doctor --quiet
    [ "$status" -eq 0 ]
    [ "$output" = "mac doctor [--quiet]" ]
    [ ! -f "$STUB_CTL/linux.log" ]
}

# --- sayit-history ----------------------------------------------------------

@test "history --copy falls back to pbcopy when there is no wl-copy" {
    rm "$STUBBIN/wl-copy"
    if command -v wl-copy >/dev/null; then
        skip "a real wl-copy exists on this system; absence cannot be simulated"
    fi
    printf '#!/usr/bin/env bash\ncat > "$STUB_CTL/pbcopy.in"\n' > "$STUBBIN/pbcopy"
    chmod +x "$STUBBIN/pbcopy"
    mkdir -p "$XDG_DATA_HOME/sayit"
    printf '{"time": "2026-10-27T12:00:00", "seconds": 1, "words": 3, "text": "kopiera åäö text"}\n' \
        > "$XDG_DATA_HOME/sayit/history.jsonl"
    run "$SANDBOX/bin/sayit-history" --copy 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Copied to clipboard"* ]]
    [ "$(cat "$STUB_CTL/pbcopy.in")" = "kopiera åäö text" ]
}

# --- test-pipeline ----------------------------------------------------------

pipeline_sandbox() {
    # The voice list in the system's own layout: a name may hold spaces and
    # parentheses, and a sample text may hold a word shaped like a locale.
    cat > "$STUBBIN/say" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -v && "$2" == '?' ]]; then
    cat <<'LIST'
Albert              en_US    # Hello! My name is Albert.
Alva (Svenska (Sverige)) sv_SE    # Hej! Jag heter Alva.
Klara               sv_SE    # Hej! Jag heter Klara.
Daniel              en_GB    # Hello! Try sv_SE for Swedish.
LIST
    exit 0
fi
echo "say $*" >> "$STUB_CTL/say.log"
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { printf 'AIFF' > "$2"; shift; }; shift; done
EOF
    cat > "$STUBBIN/afconvert" <<'EOF'
#!/usr/bin/env bash
echo "afconvert $*" >> "$STUB_CTL/afconvert.log"
cp "${@: -2:1}" "${@: -1}"
EOF
    printf '#!/usr/bin/env bash\necho "heard: $(cat "$1")"\n' > "$SANDBOX/bin/sayit-transcribe"
    chmod +x "$STUBBIN/say" "$STUBBIN/afconvert" "$SANDBOX/bin/sayit-transcribe"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
}

@test "test-pipeline speaks with the first system voice for the language" {
    pipeline_sandbox
    run "$SANDBOX/bin/test-pipeline" "hej hej"
    [ "$status" -eq 0 ]
    [[ "$output" == *"voice: Alva (Svenska (Sverige))"* ]]
    [[ "$output" == *"heard: AIFF"* ]]
    grep -q -- "-v Alva (Svenska (Sverige)) -o $TMPDIR/sayit-test-[0-9]*.aiff hej hej" "$STUB_CTL/say.log"
    grep -q -- "-f WAVE -d LEI16@16000 -c 1 " "$STUB_CTL/afconvert.log"
    [ -z "$(ls -A "$TMPDIR")" ]   # both temporary files are gone
    [ ! -f "$STUB_CTL/linux.log" ]

    SPEECH_LANGUAGE=en run "$SANDBOX/bin/test-pipeline"
    [ "$status" -eq 0 ]
    [[ "$output" == *"voice: Albert"* ]]
}

@test "test-pipeline without a voice for the language says how to add one" {
    pipeline_sandbox
    SPEECH_LANGUAGE="fi" run "$SANDBOX/bin/test-pipeline"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No system voice for fi"* ]]
    [ ! -f "$STUB_CTL/say.log" ]
}

# --- install.sh -------------------------------------------------------------

install_sandbox() {
    mkdir -p "$SANDBOX/config" "$SANDBOX/icons"
    cp "$BATS_TEST_DIRNAME/../install.sh" "$SANDBOX/"
    cp "$BATS_TEST_DIRNAME/../.env.example" "$SANDBOX/"
    cp "$BATS_TEST_DIRNAME/../config/wordlist.example.tsv" "$SANDBOX/config/"
    cp "$BATS_TEST_DIRNAME/../icons/"*.svg "$SANDBOX/icons/"
    # mac/install.sh builds Sayit.app and loads LaunchAgents: a stub here.
    mkdir -p "$SANDBOX/mac"
    cat > "$SANDBOX/mac/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "mac-install $*" >> "$STUB_CTL/mac-install.log"
exit "$(cat "$STUB_CTL/mac-install.exit" 2>/dev/null || echo 0)"
EOF
    chmod +x "$SANDBOX/mac/install.sh"
    INSTALL="$SANDBOX/install.sh"
    SKIP=(--skip-packages --skip-build --skip-model -y)
}

@test "install.sh with --skip-agent seeds .env and the wordlist and installs no theme icons" {
    install_sandbox
    run "$INSTALL" "${SKIP[@]}" --skip-agent
    [ "$status" -eq 0 ]
    [ -f "$SANDBOX/.env" ]
    [ -f "$XDG_CONFIG_HOME/sayit/wordlist.tsv" ]
    # The template's trigger is the Windows mouse button; a Mac gets F18.
    [ "$(grep '^TRIGGER_BUTTON=' "$SANDBOX/.env")" = 'TRIGGER_BUTTON="F18"' ]
    [ "$(wc -l < "$SANDBOX/.env")" -eq "$(wc -l < "$SANDBOX/.env.example")" ]
    [ ! -e "$SANDBOX/.env.tmp" ]
    [ ! -e "$XDG_DATA_HOME/icons" ]
    [[ "$output" == *"Skipping Sayit.app"* ]]
    [[ "$output" != *"icons/"* ]]
    [ ! -f "$STUB_CTL/mac-install.log" ]
}

@test "install.sh builds Sayit.app through mac/install.sh, and stops when that fails" {
    install_sandbox
    run "$INSTALL" "${SKIP[@]}"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_CTL/mac-install.log")" = "mac-install " ]
    [[ "$output" == *"INSTALL-MACOS"* ]]

    echo 1 > "$STUB_CTL/mac-install.exit"
    run "$INSTALL" "${SKIP[@]}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Building Sayit.app failed"* ]]
}

@test "Apple Silicon leaves MODEL_PATH to the scripts, whose default is large there" {
    install_sandbox
    HOSTTYPE=aarch64 run "$INSTALL" "${SKIP[@]}" --skip-agent
    [ "$status" -eq 0 ]
    [ "$(grep '^MODEL_PATH=' "$SANDBOX/.env")" = "$(grep '^MODEL_PATH=' "$SANDBOX/.env.example")" ]

    # An existing .env needs no activation hint for the default either.
    HOSTTYPE=aarch64 run "$INSTALL" "${SKIP[@]}" --skip-agent --model large
    [ "$status" -eq 0 ]
    [[ "$output" != *"To activate"* ]]
}

@test "a non-default model is written to a fresh .env without sed -i" {
    install_sandbox
    HOSTTYPE=aarch64 run "$INSTALL" "${SKIP[@]}" --skip-agent --model small
    [ "$status" -eq 0 ]
    [ "$(grep '^MODEL_PATH=' "$SANDBOX/.env")" = "MODEL_PATH=\"$SANDBOX/models/ggml-kb-whisper-small-q5_0.bin\"" ]
    [ "$(wc -l < "$SANDBOX/.env")" -eq "$(wc -l < "$SANDBOX/.env.example")" ]
    [ ! -e "$SANDBOX/.env.tmp" ]
}

@test "an explicit --model medium on Apple Silicon is written, since large is the default there" {
    install_sandbox
    HOSTTYPE=aarch64 run "$INSTALL" "${SKIP[@]}" --skip-agent --model medium
    [ "$status" -eq 0 ]
    [ "$(grep '^MODEL_PATH=' "$SANDBOX/.env")" = "MODEL_PATH=\"$SANDBOX/models/ggml-kb-whisper-medium-q5_0.bin\"" ]
}

@test "large on an Intel Mac is not the scripts' default, so it is activated" {
    install_sandbox
    HOSTTYPE=x86_64 run "$INSTALL" "${SKIP[@]}" --skip-agent --model large
    [ "$status" -eq 0 ]
    [ "$(grep '^MODEL_PATH=' "$SANDBOX/.env")" = "MODEL_PATH=\"$SANDBOX/models/ggml-kb-whisper-large-q5_0.bin\"" ]
}

@test "the activation hint for an existing .env restarts the daemon through launchctl" {
    install_sandbox
    printf 'MODEL_PATH=""\nTRIGGER_BUTTON="XBUTTON2"\n' > "$SANDBOX/.env"
    HOSTTYPE=aarch64 run "$INSTALL" "${SKIP[@]}" --skip-agent --model small
    [ "$status" -eq 0 ]
    # An existing .env is never rewritten, the trigger included.
    [ "$(cat "$SANDBOX/.env")" = $'MODEL_PATH=""\nTRIGGER_BUTTON="XBUTTON2"' ]
    [[ "$output" == *"ggml-kb-whisper-small-q5_0.bin"* ]]
    [[ "$output" == *"launchctl kickstart -k gui/"*"/io.github.mrtorriz.sayit.daemon"* ]]
    [[ "$output" != *"systemctl"* ]]
}
