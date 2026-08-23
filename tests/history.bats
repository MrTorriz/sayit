#!/usr/bin/env bats
# Tests for bin/sayit-history. Runs against a sandboxed copy of bin/ (without
# any .env) and with XDG paths inside the test tmpdir, so the developer's real
# history is never read or modified.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    export TYPING_WPM=40
    HISTORY="$SANDBOX/bin/sayit-history"
    HIST_FILE="$XDG_DATA_HOME/sayit/history.jsonl"
    mkdir -p "$(dirname "$HIST_FILE")"
}

# add_entry <iso-time> <seconds> <words> <text>
add_entry() {
    printf '{"time": "%s", "seconds": %s, "words": %s, "text": "%s"}\n' \
        "$1" "$2" "$3" "$4" >> "$HIST_FILE"
}

now() { date +%Y-%m-%dT%H:%M:%S; }

@test "empty history prints a friendly message" {
    run "$HISTORY"
    [ "$status" -eq 0 ]
    [ "$output" = "Empty history" ]
}

@test "listing shows absolute line numbers" {
    add_entry "$(now)" 1 2 "first"
    add_entry "$(now)" 1 2 "second"
    add_entry "$(now)" 1 2 "third"
    run "$HISTORY" 2
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "  2 "*"second"* ]]
    [[ "${lines[1]}" == "  3 "*"third"* ]]
}

@test "--stat sums words and computes time saved" {
    # 80 words in 60 s of speech; typing at 40 wpm would take 120 s -> 60 s saved
    add_entry "$(now)" 60 80 "a long dictation"
    run "$HISTORY" --stat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Entries:         1"* ]]
    [[ "$output" == *"Total words:     80"* ]]
    [[ "$output" == *"(80 words/min spoken)"* ]]
    [[ "$output" == *"Time saved:      60s"* ]]
}

@test "--stat with a period excludes older entries" {
    add_entry "$(date -d '-2 days' +%Y-%m-%dT%H:%M:%S)" 10 20 "old"
    add_entry "$(now)" 10 20 "recent"
    run "$HISTORY" --stat 1d
    [[ "$output" == *"Entries:         1"* ]]
    [[ "$output" == *"Total words:     20"* ]]
}

@test "--stat rejects an invalid period" {
    add_entry "$(now)" 1 2 "text"
    run "$HISTORY" --stat 7x
    [ "$status" -eq 1 ]
}

@test "--copy sends the entry text to the clipboard" {
    add_entry "$(now)" 1 3 "kopiera åäö text"
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB"
    printf '#!/usr/bin/env bash\ncat > "%s/clip"\n' "$STUB" > "$STUB/wl-copy"
    chmod +x "$STUB/wl-copy"
    PATH="$STUB:$PATH" run "$HISTORY" --copy 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Copied to clipboard"* ]]
    [ "$(cat "$STUB/clip")" = "kopiera åäö text" ]
}

@test "--copy on a missing line fails" {
    run "$HISTORY" --copy 99
    [ "$status" -eq 1 ]
}

@test "--clear empties the history" {
    add_entry "$(now)" 1 2 "text"
    run "$HISTORY" --clear
    [ "$status" -eq 0 ]
    [ ! -s "$HIST_FILE" ]
}

@test "rejects an unknown argument" {
    add_entry "$(now)" 1 2 "text"
    run "$HISTORY" --bogus
    [ "$status" -eq 1 ]
}

@test "a corrupt line does not break the listing; entries after it still show" {
    add_entry "$(now)" 1 2 "before"
    echo 'THIS IS NOT JSON {broken' >> "$HIST_FILE"
    add_entry "$(now)" 1 2 "after"
    run "$HISTORY"
    [ "$status" -eq 0 ]
    [[ "$output" == *before* ]]
    [[ "$output" == *after* ]]
    [[ "$output" != *Traceback* ]]
}

@test "a corrupt line does not break --stat" {
    add_entry "$(now)" 60 80 "healthy"
    echo '{truncated' >> "$HIST_FILE"
    run "$HISTORY" --stat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total words:     80"* ]]
    [[ "$output" != *Traceback* ]]
}

@test "corrupt lines are counted in a warning without leaking content" {
    add_entry "$(now)" 1 2 "fine"
    echo 'secret-looking {garbage' >> "$HIST_FILE"
    run "$HISTORY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"corrupt"* ]]
    [[ "$output" != *"secret-looking"* ]]
}

@test "--copy on a corrupt line fails cleanly without a traceback" {
    echo 'not json' > "$HIST_FILE"
    run "$HISTORY" --copy 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Corrupt entry"* ]]
    [[ "$output" != *Traceback* ]]
}

@test "an entry missing optional keys does not crash the listing" {
    printf '{"time": "%s", "text": "no words key"}\n' "$(now)" >> "$HIST_FILE"
    run "$HISTORY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no words key"* ]]
}

@test "a valid-JSON non-object line is treated as corrupt" {
    add_entry "$(now)" 1 2 "fine"
    echo 'null' >> "$HIST_FILE"
    echo '[1, 2]' >> "$HIST_FILE"
    run "$HISTORY"
    [ "$status" -eq 0 ]
    [[ "$output" == *fine* ]]
    [[ "$output" == *corrupt* ]]
    run "$HISTORY" --stat
    [ "$status" -eq 0 ]
    [[ "$output" != *Traceback* ]]
}

@test "a long entry is shortened with an ellipsis, not silently cut" {
    long=$(printf 'wordy%.0s ' $(seq 1 30))
    add_entry "$(now)" 5 30 "${long% }"
    run "$HISTORY" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"…"* ]]
}

@test "an entry that fits is printed whole, with no ellipsis" {
    add_entry "$(now)" 2 4 "short enough to fit"
    run "$HISTORY" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"short enough to fit"* ]]
    [[ "$output" != *"…"* ]]
}

@test "the shortened line never exceeds the 80-character text budget" {
    long=$(printf 'wordy%.0s ' $(seq 1 30))
    add_entry "$(now)" 5 30 "${long% }"
    run "$HISTORY" 1
    text=${output#*words) }
    [ "${#text}" -le 80 ]
}
