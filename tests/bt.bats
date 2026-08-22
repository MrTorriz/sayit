#!/usr/bin/env bats
# Tests for bin/sayit-bt — the Bluetooth profile switch. Runs against a
# stubbed pactl, so no real Bluetooth device is ever reprofiled. The fixtures
# model a generic headset, never one specific device.

setup() {
    BT="$BATS_TEST_DIRNAME/../bin/sayit-bt"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    STATE="$XDG_RUNTIME_DIR/sayit.bt"

    export STUB_CTL="$BATS_TEST_TMPDIR/ctl"
    mkdir -p "$STUB_CTL"
    STUBBIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUBBIN"

    cat > "$STUBBIN/pactl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    get-default-sink) cat "$STUB_CTL/default-sink" ;;
    set-card-profile)
        printf '%s %s\n' "$2" "$3" >> "$STUB_CTL/switches"
        [[ -f "$STUB_CTL/switch.fail" ]] && exit 1
        printf '%s\n' "$3" > "$STUB_CTL/active"
        ;;
    -f) case "$4" in
            cards)   sed "s/__ACTIVE__/$(cat "$STUB_CTL/active")/" "$STUB_CTL/cards.json" ;;
            sources) cat "$STUB_CTL/sources.json" ;;
        esac ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$STUBBIN/pactl"
    export PATH="$STUBBIN:$PATH"

    echo "a2dp-sink" > "$STUB_CTL/active"
    : > "$STUB_CTL/switches"
    echo "bluez_output.AA_BB_CC_DD_EE_FF.1" > "$STUB_CTL/default-sink"
    cat > "$STUB_CTL/cards.json" <<'EOF'
[{"name": "bluez_card.AA_BB_CC_DD_EE_FF",
  "active_profile": "__ACTIVE__",
  "profiles": {"a2dp-sink": {}, "headset-head-unit": {}}}]
EOF
    cat > "$STUB_CTL/sources.json" <<'EOF'
[{"name": "bluez_input.AA:BB:CC:DD:EE:FF"}]
EOF
}

@test "up switches an A2DP headset to the headset profile and prints its source" {
    run "$BT" up
    [ "$status" -eq 0 ]
    [ "$output" = "bluez_input.AA:BB:CC:DD:EE:FF" ]
    grep -q "bluez_card.AA_BB_CC_DD_EE_FF headset-head-unit" "$STUB_CTL/switches"
}

@test "up records the profile to restore before switching" {
    run "$BT" up
    [ -f "$STATE" ]
    grep -q "a2dp-sink" "$STATE"
}

@test "a failed switch leaves no state behind" {
    : > "$STUB_CTL/switch.fail"
    run "$BT" up
    [ "$status" -eq 0 ]
    [ ! -f "$STATE" ]
}

@test "a headset already in the headset profile is not switched again" {
    echo "headset-head-unit" > "$STUB_CTL/active"
    run "$BT" up
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_CTL/switches" ]
    [ ! -f "$STATE" ]
}

@test "up is a no-op when no Bluetooth card is present" {
    echo "alsa_output.usb-Acme_USB_Mic-00.analog-stereo" > "$STUB_CTL/default-sink"
    echo "[]" > "$STUB_CTL/cards.json"
    run "$BT" up
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$STATE" ]
}

@test "the card is found by enumeration when the default sink is not Bluetooth" {
    echo "alsa_output.usb-Acme_USB_Mic-00.analog-stereo" > "$STUB_CTL/default-sink"
    run "$BT" up
    [ "$status" -eq 0 ]
    grep -q "bluez_card.AA_BB_CC_DD_EE_FF headset-head-unit" "$STUB_CTL/switches"
}

@test "down restores the recorded profile and clears the state" {
    run "$BT" up
    run "$BT" down
    [ "$status" -eq 0 ]
    [ ! -f "$STATE" ]
    grep -q "bluez_card.AA_BB_CC_DD_EE_FF a2dp-sink" "$STUB_CTL/switches"
}

@test "down without state is a no-op" {
    run "$BT" down
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_CTL/switches" ]
}

@test "an unknown argument exits 1" {
    run "$BT" sideways
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}
