#!/usr/bin/env bats
# Unit tests for bin/sayit-snippets — pure text transformation, no model,
# no microphone and no .env required.

setup() {
    SNIP="$BATS_TEST_DIRNAME/../bin/sayit-snippets"
    TSV="$BATS_TEST_TMPDIR/snippets.tsv"
    printf '%s\n' \
        '# a comment line' \
        '' \
        $'min signatur\tMed vänliga hälsningar\\nAlex' \
        $'Åsas adress\tStorgatan 1\\t2 tr' \
        $'en backslash\tC:\\\\temp' \
        $'utan text\t' \
        $'min signatur\tthe second line for the same cue' \
        > "$TSV"
}

expand() {
    printf '%s' "$1" | "$SNIP" "$TSV"
}

@test "a dictation that is a cue becomes its text, the first line for it winning" {
    run expand "min signatur"
    [ "$status" -eq 0 ]
    [ "$output" = $'Med vänliga hälsningar\nAlex' ]
}

@test "case, end punctuation and extra spaces do not matter" {
    run expand "  Min   SIGNATUR. "
    [ "$output" = $'Med vänliga hälsningar\nAlex' ]
    run expand "ÅSAS ADRESS!"
    [ "$output" = $'Storgatan 1\t2 tr' ]
}

@test "a cue inside a longer dictation is left alone" {
    run expand "skriv min signatur här"
    [ "$output" = "skriv min signatur här" ]
}

@test "an escaped backslash is one backslash" {
    run expand "en backslash"
    [ "$output" = 'C:\temp' ]
}

@test "a cue without text is skipped" {
    run expand "utan text"
    [ "$output" = "utan text" ]
}

@test "anything else passes through unchanged" {
    run expand "Hej, hur går det?"
    [ "$output" = "Hej, hur går det?" ]
    run expand ""
    [ "$output" = "" ]
}

@test "a missing file passes the text through" {
    run bash -c "printf '%s' 'min signatur' | '$SNIP' '$BATS_TEST_TMPDIR/none.tsv'"
    [ "$status" -eq 0 ]
    [ "$output" = "min signatur" ]
}
