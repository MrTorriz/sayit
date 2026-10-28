#!/usr/bin/env bash
# mac/install.sh — build Sayit.app and load its LaunchAgents (macOS)
#
# Usage:
#   mac/install.sh                build when the sources changed, install, (re)load
#   mac/install.sh --rebuild      build even when nothing changed
#   mac/install.sh --no-launchd   build and install the app only
#   mac/install.sh --uninstall    unload the agents, remove the app and the plists
#   mac/install.sh -h | --help
#
# Behavior:
#   - Compiles Sayit (trigger, pill, menu bar item), sayit-rec and sayit-paste
#     with swiftc from the Xcode Command Line Tools: no Xcode project and no
#     package manager. Run by ./install.sh on macOS; runnable on its own.
#   - Bundles them into ~/Applications/Sayit.app (SAYIT_APP_DIR overrides the
#     directory), menu bar only, with this repository's path in Info.plist.
#   - Signs ad hoc, or with SAYIT_SIGN_IDENTITY when it names a code-signing
#     identity in your keychain. macOS ties the Microphone and Accessibility
#     grants to the signature, and an ad-hoc signature changes with every
#     build - so the app is rebuilt only when its sources change, and a stable
#     identity is what lets an upgrade keep its grants.
#   - Writes and (re)loads two LaunchAgents in ~/Library/LaunchAgents, the
#     counterparts of the Linux systemd user units:
#       io.github.mrtorriz.sayit.daemon  the warm whisper-server (bin/sayit-daemon)
#       io.github.mrtorriz.sayit.agent   Sayit.app
#     Both run only in the graphical session, with Homebrew's bash first on
#     PATH and ProcessType Interactive (the default lets macOS throttle them).
#   - --uninstall leaves models, .env, history and the wordlist untouched.
#
# Exit codes:
#   0  Installed (or uninstalled)
#   1  Not macOS, unknown flag, compiler missing, build or signing failure

set -euo pipefail

log()  { printf '\033[1;34m[sayit]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warning]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

REBUILD=0
LAUNCHD=1
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild) REBUILD=1 ;;
        --no-launchd) LAUNCHD=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown flag: $1 (see --help)" ;;
    esac
    shift
done

[[ "$OSTYPE" == darwin* ]] || die "mac/install.sh is for macOS"

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$MAC_DIR/.." && pwd)"
BUILD="$MAC_DIR/build"
APP_NAME="Sayit.app"
APP_DIR="${SAYIT_APP_DIR:-$HOME/Applications}"
DEST="$APP_DIR/$APP_NAME"
BUNDLE_ID="io.github.mrtorriz.sayit"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/sayit"
DAEMON_LABEL="$BUNDLE_ID.daemon"
AGENT_LABEL="$BUNDLE_ID.agent"
GUI="gui/$(id -u)"
# Homebrew's bash 5 first: `env bash` would otherwise find /bin/bash 3.2.
SERVICE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

unload() {  # unload <label>
    launchctl bootout "$GUI/$1" 2>/dev/null || true
}

load() {  # load <label> <plist>
    unload "$1"
    # bootout returns before launchd has let go of the label; one retry covers it.
    launchctl bootstrap "$GUI" "$2" 2>/dev/null || { sleep 1; launchctl bootstrap "$GUI" "$2"; }
}

if [[ $UNINSTALL -eq 1 ]]; then
    for label in "$AGENT_LABEL" "$DAEMON_LABEL"; do
        unload "$label"
        rm -f "$AGENTS/$label.plist"
    done
    # Only ever remove a bundle that is ours.
    if [[ -d "$DEST" ]]; then
        id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$id" == "$BUNDLE_ID" ]]; then
            rm -rf "$DEST"
            log "Removed $DEST"
        else
            warn "$DEST is not Sayit ($id) - left in place"
        fi
    fi
    log "LaunchAgents removed. Models, .env, history and wordlist are untouched."
    log "The Microphone and Accessibility entries can be removed in System Settings."
    exit 0
fi

command -v swiftc >/dev/null || die "swiftc missing - run: xcode-select --install"

# --- build -------------------------------------------------------------------
xml() {  # escape for an XML text node
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    printf '%s' "$s"
}

# The sources, the repository path, the signing identity and the build recipe
# itself (compile, bundle, sign - everything between the two markers below).
SOURCES_HASH=$( { find "$MAC_DIR/Sources" -name '*.swift' -print0 | sort -z | xargs -0 cat
                  printf '%s\n' "$REPO_ROOT" "${SAYIT_SIGN_IDENTITY:-}"
                  sed -n '/^# --- build recipe/,/^# --- end build recipe/p' "${BASH_SOURCE[0]}"; } | shasum -a 256 | cut -d' ' -f1)
INSTALLED_HASH=$(cat "$DEST/Contents/Resources/source-hash" 2>/dev/null || true)

if [[ $REBUILD -eq 0 && "$SOURCES_HASH" == "$INSTALLED_HASH" ]]; then
    log "Sayit.app is up to date at $DEST"
else
# --- build recipe (part of the source hash: a change here rebuilds the app) ---
    TARGET="$(uname -m)-apple-macos14.0"
    SWIFTC=(swiftc -O -swift-version 5 -target "$TARGET")
    STAGE="$BUILD/$APP_NAME"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

    log "Compiling sayit-rec, sayit-paste and Sayit ($TARGET)"
    "${SWIFTC[@]}" "$MAC_DIR"/Sources/Common/*.swift "$MAC_DIR/Sources/Rec/main.swift" \
        -o "$STAGE/Contents/MacOS/sayit-rec"
    "${SWIFTC[@]}" "$MAC_DIR/Sources/Paste/main.swift" -o "$STAGE/Contents/MacOS/sayit-paste"
    "${SWIFTC[@]}" "$MAC_DIR"/Sources/Common/*.swift "$MAC_DIR"/Sources/Agent/*.swift \
        -o "$STAGE/Contents/MacOS/Sayit"

    VERSION=$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo dev)
    cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Sayit</string>
    <key>CFBundleDisplayName</key><string>Sayit</string>
    <key>CFBundleExecutable</key><string>Sayit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(xml "$VERSION")</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sayit records only while you hold or tap your push-to-talk button, and transcribes on this Mac. Audio never leaves it.</string>
    <key>SayitRepository</key><string>$(xml "$REPO_ROOT")</string>
</dict>
</plist>
EOF
    printf '%s\n' "$SOURCES_HASH" > "$STAGE/Contents/Resources/source-hash"

    IDENTITY="${SAYIT_SIGN_IDENTITY:--}"
    log "Signing ${SAYIT_SIGN_IDENTITY:+with \"$IDENTITY\"}${SAYIT_SIGN_IDENTITY:-ad hoc}"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.rec" "$STAGE/Contents/MacOS/sayit-rec"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.paste" "$STAGE/Contents/MacOS/sayit-paste"
    codesign --force --sign "$IDENTITY" "$STAGE"
# --- end build recipe ----------------------------------------------------------

    # Replace the installed app only now that the new one is complete.
    [[ $LAUNCHD -eq 1 ]] && unload "$AGENT_LABEL"
    mkdir -p "$APP_DIR"
    if [[ -d "$DEST" ]]; then
        old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
        [[ "$old" == "$BUNDLE_ID" ]] || die "$DEST exists and is not Sayit ($old) - move it away and re-run"
        rm -rf "$DEST"
    fi
    ditto "$STAGE" "$DEST"
    log "Installed $DEST"
    if [[ -n "$INSTALLED_HASH" && -z "${SAYIT_SIGN_IDENTITY:-}" ]]; then
        warn "The ad-hoc signature changed: macOS may ask for the Microphone and"
        warn "Accessibility permissions again (System Settings > Privacy & Security)."
    fi
fi

[[ $LAUNCHD -eq 1 ]] || { log "Skipping the LaunchAgents (--no-launchd)"; exit 0; }

# --- LaunchAgents --------------------------------------------------------------
mkdir -p "$AGENTS" "$LOGS"

cat > "$AGENTS/$DAEMON_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$(xml "$REPO_ROOT/bin/sayit-daemon")</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$SERVICE_PATH</string>
        <key>SAYIT_DAEMON_LOG</key><string>$(xml "$LOGS/daemon.log")</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

cat > "$AGENTS/$AGENT_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$(xml "$DEST/Contents/MacOS/Sayit")</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$SERVICE_PATH</string>
        <key>SAYIT_REPO</key><string>$(xml "$REPO_ROOT")</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$(xml "$LOGS/agent.log")</string>
</dict>
</plist>
EOF

plutil -lint "$AGENTS/$DAEMON_LABEL.plist" "$AGENTS/$AGENT_LABEL.plist" >/dev/null \
    || die "Generated LaunchAgent is not a valid plist"
load "$DAEMON_LABEL" "$AGENTS/$DAEMON_LABEL.plist"
load "$AGENT_LABEL" "$AGENTS/$AGENT_LABEL.plist"
log "LaunchAgents loaded: $DAEMON_LABEL, $AGENT_LABEL"
log "Sayit is in the menu bar. Allow Microphone and Accessibility when asked,"
log "then hold your trigger and speak. Check everything with: ./bin/sayit doctor"
