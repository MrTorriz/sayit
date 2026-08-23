#!/usr/bin/env bats
# Tests for bin/sayit-transcribe. Runs against a sandboxed copy of bin/ with
# curl and whisper-cli replaced by PATH/env stubs — no network, no daemon,
# no model and no .env is ever touched.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"

    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    # curl stub: logs argv, behavior controlled via CURL_MODE.
    cat > "$STUBBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CTL/curl.args"
case "${CURL_MODE:-ok}" in
    ok)    printf 'daemon text from server' ;;
    empty) ;;
    token) printf ' <|nospeech|> ' ;;
    fail)  exit 7 ;;
esac
exit 0
EOF
    chmod +x "$STUBBIN/curl"
    export PATH="$STUBBIN:$PATH"

    # whisper-cli stub: logs argv, prints canned text.
    CLI_STUB="$BATS_TEST_TMPDIR/whisper-cli"
    cat > "$CLI_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CTL/cli.args"
printf 'cli text from fallback'
EOF
    chmod +x "$CLI_STUB"
    export WHISPER_CLI="$CLI_STUB"

    # A model file that exists (content irrelevant for the stubs).
    MODEL_STUB="$BATS_TEST_TMPDIR/model.bin"
    printf 'model' > "$MODEL_STUB"
    export MODEL_PATH="$MODEL_STUB"
    unset SAYIT_MODEL 2>/dev/null || true
    unset WORDLIST 2>/dev/null || true
    unset INITIAL_PROMPT 2>/dev/null || true

    TRANSCRIBE="$SANDBOX/bin/sayit-transcribe"
    WAV="$BATS_TEST_TMPDIR/test.wav"
    head -c 64000 /dev/zero > "$WAV"   # 2 s of 16 kHz s16 mono
}

@test "daemon success is used directly; CLI is never invoked" {
    run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "daemon text from server" ]
    [ ! -f "$STUB_CTL/cli.args" ]
}

@test "empty daemon result is authoritative: no cold CLI rerun" {
    CURL_MODE=empty run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STUB_CTL/cli.args" ]
}

@test "daemon result with only special tokens counts as empty, no CLI rerun" {
    CURL_MODE=token run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STUB_CTL/cli.args" ]
}

@test "transport failure falls back to the CLI" {
    CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "cli text from fallback" ]
    [ -f "$STUB_CTL/cli.args" ]
}

@test "healthy daemon works even when whisper-cli is missing" {
    WHISPER_CLI=/nonexistent run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "daemon text from server" ]
}

@test "healthy daemon works even when the model file is missing" {
    MODEL_PATH=/nonexistent/model.bin run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ "$output" = "daemon text from server" ]
}

@test "transport failure plus missing CLI fails with a clear error" {
    CURL_MODE=fail WHISPER_CLI=/nonexistent run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 1 ]
    [[ "$output" != *"daemon text"* ]]
    [[ "$output" == *whisper-cli* ]]
}

@test "prompt beginning with @ is sent literally via --form-string" {
    INITIAL_PROMPT="@handle-style names: GitHub" run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- '--form-string prompt=@handle-style' "$STUB_CTL/curl.args"
    ! grep -q -- '-F prompt=' "$STUB_CTL/curl.args"
}

@test "curl deadline scales with audio length" {
    head -c 320000 /dev/zero > "$WAV"   # 10 s of audio -> deadline 20 s
    run "$TRANSCRIBE" "$WAV"
    grep -q -- '-m 20' "$STUB_CTL/curl.args"
    grep -q -- '--connect-timeout 2' "$STUB_CTL/curl.args"
}

@test "SAYIT_MODEL override reaches the CLI fallback" {
    ALT="$BATS_TEST_TMPDIR/alt-model.bin"
    printf 'alt' > "$ALT"
    CURL_MODE=fail SAYIT_MODEL="$ALT" run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- "$ALT" "$STUB_CTL/cli.args"
}

@test "special tokens are stripped from CLI output" {
    cat > "$BATS_TEST_TMPDIR/whisper-cli" <<'EOF'
#!/usr/bin/env bash
printf '<|sv|> hej там <|endoftext|>'
EOF
    chmod +x "$BATS_TEST_TMPDIR/whisper-cli"
    CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [[ "$output" != *"<|"* ]]
    [[ "$output" == *hej* ]]
}

@test "wordlist is applied to daemon output" {
    WL="$BATS_TEST_TMPDIR/wl.tsv"
    printf 'daemon\tDAEMON\n' > "$WL"
    WORDLIST="$WL" run "$TRANSCRIBE" "$WAV"
    [ "$output" = "DAEMON text from server" ]
}

@test "missing WAV argument fails with exit 1" {
    run "$TRANSCRIBE" /nonexistent/file.wav
    [ "$status" -eq 1 ]
}

# --- VAD tuning and the empty-WAV shortcut ---------------------------------
# The default VAD_MODEL points inside the repo, and the sandbox copies only
# bin/, so VAD is off unless a test puts a file there.

vad_on() {
    VADFILE="$BATS_TEST_TMPDIR/silero.bin"
    printf 'vad' > "$VADFILE"
    export VAD_MODEL="$VADFILE"
}

@test "VAD tuning is sent with the request, so no daemon restart is needed" {
    vad_on
    run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- '--form-string vad_speech_pad_ms=250' "$STUB_CTL/curl.args"
    grep -q -- '--form-string vad_threshold=0.30' "$STUB_CTL/curl.args"
    grep -q -- '--form-string vad_min_speech_duration_ms=0' "$STUB_CTL/curl.args"
    grep -q -- '--form-string vad_min_silence_duration_ms=300' "$STUB_CTL/curl.args"
}

@test "VAD tuning is omitted when the VAD model is missing" {
    VAD_MODEL=/nonexistent/silero.bin run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    ! grep -q -- 'vad_speech_pad_ms' "$STUB_CTL/curl.args"
}

@test "VAD settings from the environment override the defaults" {
    vad_on
    VAD_SPEECH_PAD_MS=120 VAD_THRESHOLD=0.45 run "$TRANSCRIBE" "$WAV"
    grep -q -- '--form-string vad_speech_pad_ms=120' "$STUB_CTL/curl.args"
    grep -q -- '--form-string vad_threshold=0.45' "$STUB_CTL/curl.args"
}

@test "the CLI fallback gets the same VAD tuning as the daemon" {
    vad_on
    CURL_MODE=fail run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    grep -q -- '-vp 250' "$STUB_CTL/cli.args"
    grep -q -- '-vt 0.30' "$STUB_CTL/cli.args"
    grep -q -- '-vspd 0' "$STUB_CTL/cli.args"
    grep -q -- '-vsd 300' "$STUB_CTL/cli.args"
}

@test "a WAV with no samples answers empty without contacting either path" {
    EMPTY="$BATS_TEST_TMPDIR/empty.wav"
    head -c 44 /dev/zero > "$EMPTY"
    run "$TRANSCRIBE" "$EMPTY"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STUB_CTL/curl.args" ]
    [ ! -f "$STUB_CTL/cli.args" ]
}

@test "a WAV with samples is not mistaken for an empty one" {
    run "$TRANSCRIBE" "$WAV"
    [ "$status" -eq 0 ]
    [ -f "$STUB_CTL/curl.args" ]
}
