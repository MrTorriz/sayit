#!/usr/bin/env bats
# Unit tests for bin/sayit-wordlist — pure text transformation, no model,
# no microphone and no .env required.

setup() {
    WORDLIST_BIN="$BATS_TEST_DIRNAME/../bin/sayit-wordlist"
    WL="$BATS_TEST_TMPDIR/wordlist.tsv"
}

apply() {
    printf '%s' "$1" | "$WORDLIST_BIN" "$WL"
}

@test "replaces a simple rule" {
    printf 'get hub\tGitHub\n' > "$WL"
    run apply "pushed to get hub today"
    [ "$status" -eq 0 ]
    [ "$output" = "pushed to GitHub today" ]
}

@test "matching is case-insensitive" {
    printf 'get hub\tGitHub\n' > "$WL"
    run apply "Get Hub is down"
    [ "$output" = "GitHub is down" ]
}

@test "respects word boundaries (no substring matches)" {
    printf 'cat\tdog\n' > "$WL"
    run apply "category cat concatenate"
    [ "$output" = "category dog concatenate" ]
}

@test "word boundaries are UTF-8 aware" {
    # "på" must not match inside "påse" — å is a word character
    printf 'på\tON\n' > "$WL"
    run apply "på påse"
    [ "$output" = "ON påse" ]
}

@test "replacement text may contain non-ASCII" {
    printf 'ratta\trätta\n' > "$WL"
    run apply "vi ska ratta detta"
    [ "$output" = "vi ska rätta detta" ]
}

@test "longest original wins regardless of file order" {
    printf 'hub\tnav\nget hub\tGitHub\n' > "$WL"
    run apply "open get hub"
    [ "$output" = "open GitHub" ]
}

@test "replaces every occurrence" {
    printf 'cat\tdog\n' > "$WL"
    run apply "cat sees cat"
    [ "$output" = "dog sees dog" ]
}

@test "regex metacharacters in originals are matched literally" {
    printf '2+2\t4\n' > "$WL"
    run apply "what is 2+2 now"
    [ "$output" = "what is 4 now" ]
}

@test "comments and blank lines are ignored" {
    printf '# cat\tthis is only a comment\n\ncat\tdog\n' > "$WL"
    run apply "a cat appears"
    [ "$output" = "a dog appears" ]
}

@test "missing wordlist passes text through unchanged" {
    run apply "untouched text"
    [ "$status" -eq 0 ]
    [ "$output" = "untouched text" ]
}
