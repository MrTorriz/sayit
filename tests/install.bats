#!/usr/bin/env bats
# Tests for install.sh — argument parsing and the side-effect-free control
# flow only. The script runs against a sandboxed copy of the repo with fake
# HOME/XDG paths and --skip flags, so no package manager, network, build or
# real configuration is ever touched.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$SANDBOX/config"
    cp "$BATS_TEST_DIRNAME/../install.sh" "$SANDBOX/"
    cp "$BATS_TEST_DIRNAME/../.env.example" "$SANDBOX/"
    cp "$BATS_TEST_DIRNAME/../config/wordlist.example.tsv" "$SANDBOX/config/"

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    mkdir -p "$HOME"

    INSTALL="$SANDBOX/install.sh"
    SKIP=(--skip-packages --skip-build --skip-model -y)
}

@test "--help exits 0 and documents --rebuild" {
    run "$INSTALL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--rebuild"* ]]
    [[ "$output" == *"--model"* ]]
}

@test "unknown flag exits 1" {
    run "$INSTALL" --bogus
    [ "$status" -eq 1 ]
}

@test "invalid model size exits 1" {
    run "$INSTALL" --model gigantic
    [ "$status" -eq 1 ]
}

@test "seeding creates .env and the wordlist" {
    run "$INSTALL" "${SKIP[@]}"
    [ "$status" -eq 0 ]
    [ -f "$SANDBOX/.env" ]
    [ -f "$XDG_CONFIG_HOME/sayit/wordlist.tsv" ]
}

@test "existing .env is never overwritten" {
    printf 'MODEL_PATH="/custom/path.bin"\n' > "$SANDBOX/.env"
    run "$INSTALL" "${SKIP[@]}"
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/.env")" = 'MODEL_PATH="/custom/path.bin"' ]
}

@test "variables missing from an existing .env are reported" {
    printf 'MODEL_PATH=""\nTHREADS=8\n' > "$SANDBOX/.env"
    run "$INSTALL" "${SKIP[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BEAM"* ]]
    [[ "$output" == *"WORDLIST"* ]]
}

@test "--model large with an existing .env prints the activation hint" {
    printf 'MODEL_PATH=""\n' > "$SANDBOX/.env"
    run "$INSTALL" "${SKIP[@]}" --model large
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL_PATH"* ]]
    [[ "$output" == *"ggml-kb-whisper-large-q5_0.bin"* ]]
    [[ "$output" == *"restart"* ]]
}

@test "a non-git whisper.cpp directory aborts with a clear message before any network use" {
    export WHISPER_SRC="$BATS_TEST_TMPDIR/broken-src"
    mkdir -p "$WHISPER_SRC"
    run "$INSTALL" --skip-packages --skip-model -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a git repository"* ]]
}

@test "checksums and pin are defined for every model size" {
    for size in small medium large; do
        run bash -c "grep -A6 'MODEL_SHA256' '$INSTALL' | grep -c '[0-9a-f]\{64\}'"
        [ "${output}" -ge 3 ]
    done
    grep -qE 'WHISPER_REF="?\$\{WHISPER_REF:-v[0-9]+\.[0-9]+\.[0-9]+\}"?' "$INSTALL"
}
