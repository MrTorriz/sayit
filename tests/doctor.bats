#!/usr/bin/env bats
# Tests for bin/sayit-doctor — the read-only diagnostics command. Runs against
# a sandboxed copy of bin/ with a stubbed pactl, so no real PipeWire, sound
# card, Bluetooth device or user configuration is ever touched. The fixtures
# model a generic machine (a USB microphone card plus a Bluetooth headset),
# never one specific device.

setup() {
    ORIG_PATH="$PATH"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp -r "$BATS_TEST_DIRNAME/../bin" "$SANDBOX/bin"

    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME"

    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"

    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"
    export STUBBIN

    # pw-record only has to exist; the doctor never runs it.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/pw-record"
    chmod +x "$STUBBIN/pw-record"

    # pactl stub: serves the JSON fixtures written by the helpers below.
    cat > "$STUBBIN/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "info")                 exit 0 ;;
    "-f json list sources") cat "$STUB_CTL/sources.json" ;;
    "-f json list cards")   cat "$STUB_CTL/cards.json" ;;
    "get-default-source")   cat "$STUB_CTL/default-source" 2>/dev/null || true ;;
    "get-default-sink")     cat "$STUB_CTL/default-sink" 2>/dev/null || true ;;
    *)                      exit 1 ;;
esac
EOF
    chmod +x "$STUBBIN/pactl"
    export PATH="$STUBBIN:$PATH"

    default_fixtures
}

# Restore the full PATH so bats' own cleanup still finds its tools after a
# test has run with an isolated PATH.
teardown() {
    export PATH="$ORIG_PATH"
}

# Cut PATH down to the stub directory alone, with only the handful of real
# tools the doctor needs symlinked in. Removing a stub from $STUBBIN then
# genuinely removes that tool, instead of merely unshadowing the host's copy.
isolate_path() {
    local t src
    for t in env bash jq grep sed cat dirname; do
        src=$(command -v "$t") || continue
        ln -sf "$src" "$STUBBIN/$t"
    done
    export PATH="$STUBBIN"
}

# A machine with a USB microphone card in a profile that has an input, and a
# Bluetooth headset playing over A2DP.
default_fixtures() {
    cat > "$STUB_CTL/sources.json" <<'EOF'
[
  {"name": "alsa_input.usb-Acme_USB_Mic-00.mono-fallback",
   "description": "Acme USB Mic Mono"},
  {"name": "alsa_input.pci-0000_00_1f.3-platform-generic.HiFi__Mic1__source",
   "description": "Built-in Microphone"}
]
EOF
    cat > "$STUB_CTL/cards.json" <<'EOF'
[
  {"name": "alsa_card.usb-Acme_USB_Mic-00",
   "active_profile": "output:analog-stereo+input:mono-fallback",
   "properties": {"device.description": "Acme USB Mic"},
   "profiles": {
     "off":                                  {"sinks": 0, "sources": 0},
     "output:analog-stereo":                 {"sinks": 1, "sources": 0},
     "output:analog-stereo+input:mono-fallback": {"sinks": 1, "sources": 1},
     "input:mono-fallback":                  {"sinks": 0, "sources": 1}
   }},
  {"name": "bluez_card.AA_BB_CC_DD_EE_FF",
   "active_profile": "a2dp-sink",
   "properties": {"device.description": "(null)"},
   "profiles": {
     "a2dp-sink":          {"sinks": 1, "sources": 1},
     "headset-head-unit":  {"sinks": 1, "sources": 1}
   }}
]
EOF
    echo "alsa_input.usb-Acme_USB_Mic-00.mono-fallback" > "$STUB_CTL/default-source"
    echo "alsa_output.usb-Acme_USB_Mic-00.analog-stereo" > "$STUB_CTL/default-sink"
}

set_env() { printf 'AUDIO_SOURCE="%s"\n' "$1" > "$SANDBOX/.env"; }

doctor() { run "$SANDBOX/bin/sayit-doctor" "$@"; }

# --- Source resolution ------------------------------------------------------

@test "a configured source that exists passes with no failures" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolves to a live source"* ]]
}

@test "a numeric AUDIO_SOURCE fails: node ids do not survive a reboot" {
    set_env "206"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"numeric id"* ]]
    [[ "$output" == *"reassigns"* ]]
}

@test "a missing source on a present card names the card and its active profile" {
    # The card sits in an output-only profile — the classic silent failure.
    python3 - "$STUB_CTL/cards.json" <<'PY'
import json, sys
p = sys.argv[1]
cards = json.load(open(p))
cards[0]["active_profile"] = "output:analog-stereo"
json.dump(cards, open(p, "w"))
PY
    python3 - "$STUB_CTL/sources.json" <<'PY'
import json, sys
p = sys.argv[1]
srcs = [s for s in json.load(open(p)) if "Acme" not in s["name"]]
json.dump(srcs, open(p, "w"))
PY
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"names no current source"* ]]
    [[ "$output" == *"alsa_card.usb-Acme_USB_Mic-00"* ]]
    [[ "$output" == *"active profile: output:analog-stereo"* ]]
    [[ "$output" == *"set-card-profile alsa_card.usb-Acme_USB_Mic-00 output:analog-stereo+input:mono-fallback"* ]]
}

@test "the active profile is never suggested as the fix" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.does-not-exist"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" != *"set-card-profile alsa_card.usb-Acme_USB_Mic-00 output:analog-stereo+input:mono-fallback"* ]]
    [[ "$output" == *"set-card-profile alsa_card.usb-Acme_USB_Mic-00 input:mono-fallback"* ]]
}

@test "a source whose card is gone reports the device as disconnected" {
    set_env "alsa_input.usb-Absent_Device-99.mono-fallback"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"disconnected"* ]]
}

@test "one failure is counted once even when it prints several lines" {
    set_env "206"
    doctor
    [[ "$output" == *"1 failure(s)"* ]]
}

# --- Bluetooth interaction --------------------------------------------------

@test "an empty AUDIO_SOURCE with Bluetooth playback warns about the profile switch" {
    echo "bluez_output.AA_BB_CC_DD_EE_FF.1" > "$STUB_CTL/default-sink"
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"switch the"* ]]
    [[ "$output" == *"call profile"* ]]
}

@test "an empty AUDIO_SOURCE with wired playback does not warn about Bluetooth" {
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *"call profile and back"* ]]
}

@test "a dedicated AUDIO_SOURCE reports that Bluetooth is left untouched" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"left untouched while recording"* ]]
}

@test "a headset left in its call profile is reported with the way back" {
    python3 - "$STUB_CTL/cards.json" <<'PY'
import json, sys
p = sys.argv[1]
cards = json.load(open(p))
cards[1]["active_profile"] = "headset-head-unit"
json.dump(cards, open(p, "w"))
PY
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"call profile"* ]]
    [[ "$output" == *"sayit-bt down"* ]]
}

@test "a description pactl could not encode falls back to the card name" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"bluez_card.AA_BB_CC_DD_EE_FF"* ]]
    [[ "$output" != *"(null)"* ]]
}

# --- Leftover state ---------------------------------------------------------

@test "a stale session file is reported" {
    printf '999999\t/nonexistent.wav\t0\n' > "$XDG_RUNTIME_DIR/sayit.session"
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale session file"* ]]
}

@test "leftover Bluetooth profile state is reported with the way back" {
    printf 'bluez_card.AA_BB_CC_DD_EE_FF\ta2dp-sink\n' > "$XDG_RUNTIME_DIR/sayit.bt"
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"leftover Bluetooth state"* ]]
    [[ "$output" == *"sayit-bt down"* ]]
}

@test "a clean runtime directory reports no leftovers" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"no leftover recording session"* ]]
    [[ "$output" == *"no leftover Bluetooth profile state"* ]]
}

# --- Degraded environments --------------------------------------------------

@test "a missing pw-record is a failure" {
    rm -f "$STUBBIN/pw-record"
    isolate_path
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"pw-record missing"* ]]
}

@test "a missing pactl degrades to a warning and skips the rest" {
    rm -f "$STUBBIN/pactl"
    isolate_path
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"pactl missing"* ]]
    [[ "$output" == *"further checks skipped"* ]]
}

@test "an unreachable PipeWire is a failure, not a crash" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/pactl"
    chmod +x "$STUBBIN/pactl"
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"not reachable"* ]]
}

# --- Interface --------------------------------------------------------------

@test "--quiet suppresses ok, info and section lines but keeps the summary" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor --quiet
    [ "$status" -eq 0 ]
    [[ "$output" != *"  ok    "* ]]
    [[ "$output" != *"  --    "* ]]
    [[ "$output" != *"Recording source"* ]]
    [[ "$output" != *"Bluetooth"* ]]
    [[ "$output" == *"0 failure(s), 0 warning(s)"* ]]
}

@test "--help prints the whole exit-code table" {
    doctor --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"0  No failures"* ]]
    [[ "$output" == *"1  At least one failure"* ]]
}

# --- Empty AUDIO_SOURCE: the fallback path must be checked too ---------------

@test "an empty AUDIO_SOURCE fails when no capture source exists at all" {
    echo "[]" > "$STUB_CTL/sources.json"
    echo "" > "$STUB_CTL/default-source"
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"no capture source at all"* ]]
    [[ "$output" == *"set-card-profile alsa_card.usb-Acme_USB_Mic-00 input:mono-fallback"* ]]
}

@test "an empty AUDIO_SOURCE fails when the default source is not live" {
    echo "alsa_input.usb-Gone_Device-00.mono-fallback" > "$STUB_CTL/default-source"
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"default source names no live source"* ]]
}

@test "monitor sources do not count as a capture source" {
    cat > "$STUB_CTL/sources.json" <<'EOF'
[{"name": "alsa_output.usb-Acme_USB_Mic-00.analog-stereo.monitor",
  "description": "Monitor of Acme"}]
EOF
    echo "" > "$STUB_CTL/default-source"
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"no capture source at all"* ]]
}

@test "an empty AUDIO_SOURCE with a live default source passes" {
    : > "$SANDBOX/.env"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"PipeWire default source:"* ]]
}

# --- Malformed input must not kill the run ----------------------------------

@test "cards without a profiles key do not abort the report" {
    printf '[{"name": "alsa_card.usb-Acme_USB_Mic-00", "active_profile": "x"}]' \
        > "$STUB_CTL/cards.json"
    set_env "alsa_input.usb-Acme_USB_Mic-00.does-not-exist"
    doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"Session state"* ]]
    [[ "$output" == *"failure(s)"* ]]
}

@test "invalid JSON from pactl does not abort the report" {
    printf 'not json at all' > "$STUB_CTL/cards.json"
    printf 'not json either' > "$STUB_CTL/sources.json"
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    doctor
    [[ "$output" == *"Session state"* ]]
    [[ "$output" == *"failure(s)"* ]]
}

@test "a card with a null name does not abort the report" {
    printf '[{"name": null, "active_profile": "x", "profiles": {}}]' \
        > "$STUB_CTL/cards.json"
    set_env "alsa_input.usb-Acme_USB_Mic-00.does-not-exist"
    doctor
    [[ "$output" == *"Session state"* ]]
}

@test "an unknown argument exits 1" {
    doctor --nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "sayit doctor dispatches to sayit-doctor and forwards its arguments" {
    set_env "alsa_input.usb-Acme_USB_Mic-00.mono-fallback"
    run "$SANDBOX/bin/sayit" doctor --quiet
    [ "$status" -eq 0 ]
    [[ "$output" != *"  ok    "* ]]
    [[ "$output" == *"0 failure(s)"* ]]
}
