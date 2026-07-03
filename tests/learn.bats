#!/usr/bin/env bats
# Tests for bin/sayit-learn. Runs against a sandboxed copy of bin/ (without
# any .env) and with XDG paths inside the test tmpdir, so the developer's real
# wordlist is never read or modified.

setup() {
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    unset WORDLIST
    LEARN="$SANDBOX/bin/sayit-learn"
    WL="$XDG_CONFIG_HOME/sayit/wordlist.tsv"
    mkdir -p "$(dirname "$WL")"
}

@test "adds a rule as original<TAB>replacement" {
    run "$LEARN" "get hub" "GitHub"
    [ "$status" -eq 0 ]
    [ "$output" = "Added: get hub -> GitHub" ]
    grep -q "$(printf 'get hub\tGitHub')" "$WL"
}

@test "rejects a duplicate original (case-insensitive)" {
    "$LEARN" "get hub" "GitHub"
    run "$LEARN" "Get Hub" "GitHub"
    [ "$status" -eq 1 ]
    [ "$(grep -c 'GitHub' "$WL")" -eq 1 ]
}

@test "rejects identical original and replacement" {
    run "$LEARN" "same" "same"
    [ "$status" -eq 1 ]
    ! grep -q "same" "$WL"
}

@test "--undo removes the rule" {
    "$LEARN" "get hub" "GitHub"
    run "$LEARN" --undo "get hub"
    [ "$status" -eq 0 ]
    ! grep -q "GitHub" "$WL"
}

@test "--undo on a missing original fails" {
    run "$LEARN" --undo "never added"
    [ "$status" -eq 1 ]
}

@test "--list shows rules but hides comments" {
    printf '# a comment line\n' > "$WL"
    "$LEARN" "get hub" "GitHub"
    run "$LEARN" --list
    [[ "$output" == *"get hub"* ]]
    [[ "$output" != *"comment"* ]]
}

@test "a learned rule is applied by sayit-wordlist" {
    "$LEARN" "gitting nore" "gitignore"
    run bash -c "printf '%s' 'add it to gitting nore' | '$SANDBOX/bin/sayit-wordlist' '$WL'"
    [ "$output" = "add it to gitignore" ]
}
