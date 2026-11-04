#!/usr/bin/env bats
# Unit tests for bin/sayit-punctuation — pure text transformation, no model,
# no microphone and no .env required.

setup() {
    PUNCT="$BATS_TEST_DIRNAME/../bin/sayit-punctuation"
}

apply() {
    printf '%s' "$1" | "$PUNCT"
}

@test "a spoken question mark attaches to the word before it" {
    run apply "Hur går det frågetecken"
    [ "$status" -eq 0 ]
    [ "$output" = "Hur går det?" ]
}

@test "the punctuation the model put around the spoken word goes" {
    run apply "Hur går det, frågetecken."
    [ "$output" = "Hur går det?" ]
    run apply "Hur går det? Frågetecken."
    [ "$output" = "Hur går det?" ]
}

@test "every attaching word, in any case, with the text after it kept" {
    run apply "Varning UTROPSTECKEN Nu kör vi"
    [ "$output" = "Varning! Nu kör vi" ]
    run apply "ett kommatecken två kolon tre semikolon fyra"
    [ "$output" = "ett, två: tre; fyra" ]
}

@test "slash joins the words on both sides into a path" {
    run apply "slash Users slash alex"
    [ "$output" = "/Users/alex" ]
    run apply "Slash, Users, slash, Alex."
    [ "$output" = "/Users/Alex" ]
    run apply "och snedstreck eller"
    [ "$output" = "och/eller" ]
}

@test "a spoken command at the start loses the model's final period" {
    run apply "Slash commit."
    [ "$output" = "/commit" ]
}

@test "a slash after a sentence end keeps one space, and the period stays" {
    run apply "Klart. Slash help."
    [ "$output" = "Klart. /help." ]
}

@test "lone marks a wordlist rule left between spaces are tidied" {
    run apply "Hur går det ?."
    [ "$output" = "Hur går det?" ]
    run apply "/ Users / alex"
    [ "$output" = "/Users/alex" ]
}

@test "marks the model wrote, URLs, numbers and times are untouched" {
    run apply "Vad?! Se https://example.com/a 3.14 kl. 10:30, 1/2"
    [ "$output" = "Vad?! Se https://example.com/a 3.14 kl. 10:30, 1/2" ]
}

@test "only whole words match" {
    run apply "Frågetecknet om kolonin och slashen"
    [ "$output" = "Frågetecknet om kolonin och slashen" ]
}

@test "empty input gives empty output" {
    run apply ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
