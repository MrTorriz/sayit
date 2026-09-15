#!/usr/bin/env bats
# Launcher path/configuration checks with a fake interpreter; no model or GPU.
setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    REPO="$BATS_TEST_TMPDIR/repo with spaces"
    mkdir -p "$REPO/bin" "$XDG_DATA_HOME/sayit/openvino/venv/bin" "$HOME/build/bin"
    cp "$BATS_TEST_DIRNAME/../bin/sayit-openvino" "$REPO/bin/"
    printf 'WHISPER_SERVER="%s/build/bin/whisper-server"\nDAEMON_PORT=19899\n' "$HOME" > "$REPO/.env"
    touch "$HOME/build/bin/whisper-server"
    cat > "$XDG_DATA_HOME/sayit/openvino/venv/bin/python" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
    chmod +x "$XDG_DATA_HOME/sayit/openvino/venv/bin/python"
}

@test "new whisper.cpp layout resolves libwhisper beside the server" {
    touch "$HOME/build/bin/libwhisper.so"
    run "$REPO/bin/sayit-openvino" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/build/bin/libwhisper.so"* ]]
    [[ "$output" == *"19899"* ]]
    [[ "$output" == *"--check"* ]]
}

@test "older whisper.cpp layout resolves libwhisper under src" {
    mkdir -p "$HOME/build/src"
    touch "$HOME/build/src/libwhisper.so"
    run "$REPO/bin/sayit-openvino"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/bin/../src/libwhisper.so"* ]]
}

@test "explicit library override wins and supports spaces" {
    touch "$HOME/custom library.so"
    printf 'WHISPER_LIB="%s/custom library.so"\n' "$HOME" >> "$REPO/.env"
    run "$REPO/bin/sayit-openvino"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/custom library.so"* ]]
}

@test "a missing shared library fails with a recovery hint" {
    run "$REPO/bin/sayit-openvino"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WHISPER_LIB"* ]]
}
