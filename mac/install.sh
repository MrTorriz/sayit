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
#   - Bundles them into /Applications/Sayit.app when that folder is writable
#     (an administrator account), so Sayit shows under Applications in Finder,
#     else into ~/Applications (SAYIT_APP_DIR overrides either); a copy left
#     in the other place by an earlier install is removed. Menu bar only, with this repository's path in Info.plist and
#     an icon (the pill on a dark tile) drawn by mac/Sources/Icon from the same
#     geometry as the logo, then packed with iconutil.
#   - Signs with a local, self-signed code-signing identity, created on the
#     first install in a keychain of its own
#     (~/Library/Keychains/sayit-signing.keychain-db, no password, never in
#     the keychain search list). macOS ties the Microphone and Accessibility
#     grants to the signature's designated requirement: with this identity it
#     is "this identifier, this certificate", the same for every build, so a
#     rebuild keeps the grants. SAYIT_SIGN_IDENTITY names another identity in
#     your keychain, or "-" for ad hoc - whose requirement is the build's own
#     hash, so every rebuild asks for the permissions again. The app is
#     rebuilt only when its sources change.
#   - Writes and (re)loads two LaunchAgents in ~/Library/LaunchAgents, the
#     counterparts of the Linux systemd user units:
#       io.github.mrtorriz.sayit.daemon  the warm whisper-server (bin/sayit-daemon)
#       io.github.mrtorriz.sayit.agent   Sayit.app
#     Both run only in the graphical session, with Homebrew's bash first on
#     PATH and ProcessType Interactive (the default lets macOS throttle them).
#   - --uninstall also removes the signing keychain, and leaves models, .env,
#     history and the wordlist untouched.
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
if [[ -n "${SAYIT_APP_DIR:-}" ]]; then
    APP_DIR="$SAYIT_APP_DIR"
elif [[ -w /Applications ]]; then
    APP_DIR=/Applications
else
    APP_DIR="$HOME/Applications"
fi
DEST="$APP_DIR/$APP_NAME"

# Removes a bundle only when it is Sayit's.
remove_ours() {  # remove_ours <bundle>
    [[ -d "$1" ]] || return 0
    local id
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$id" == "$BUNDLE_ID" ]]; then
        rm -rf "$1"
        log "Removed $1"
    else
        warn "$1 is not Sayit ($id) - left in place"
    fi
}
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
    # Wherever an install put it; only ever a bundle that is ours.
    for app in "$DEST" "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
        remove_ours "$app"
    done
    security delete-keychain "$HOME/Library/Keychains/sayit-signing.keychain-db" 2>/dev/null \
        && log "Removed the local signing identity"
    log "LaunchAgents removed. Models, .env, history and wordlist are untouched."
    log "The Microphone and Accessibility entries can be removed in System Settings."
    exit 0
fi

command -v swiftc >/dev/null || die "swiftc missing - run: xcode-select --install"

# --- signing identity -----------------------------------------------------------
SIGN_KEYCHAIN="$HOME/Library/Keychains/sayit-signing.keychain-db"
SIGN_NAME="Sayit Local Signing"

# Creates the identity when it is missing and unlocks its keychain. The key
# signs only Sayit: anything running as this user could use it as well, as
# with any developer's signing key on their own Mac.
local_identity() {
    if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
        # The system's LibreSSL: a newer OpenSSL writes PKCS#12 files with
        # ciphers that `security import` cannot read.
        local ssl=/usr/bin/openssl tmp rc=0
        [[ -x "$ssl" ]] || return 1
        tmp=$(mktemp -d)
        cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
        {
            "$ssl" req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/req.cnf" \
                -extensions ext -keyout "$tmp/key.pem" -out "$tmp/cert.pem" &&
            "$ssl" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
                -out "$tmp/id.p12" -passout pass:sayit &&
            security create-keychain -p "" "$SIGN_KEYCHAIN" &&
            security set-keychain-settings "$SIGN_KEYCHAIN" &&
            security unlock-keychain -p "" "$SIGN_KEYCHAIN" &&
            security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P sayit -T /usr/bin/codesign &&
            security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$SIGN_KEYCHAIN"
        } >/dev/null 2>&1 || rc=1
        rm -rf "$tmp"
        if (( rc )); then
            security delete-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true
            return 1
        fi
        log "Created the local signing identity \"$SIGN_NAME\" ($SIGN_KEYCHAIN)"
    fi
    security unlock-keychain -p "" "$SIGN_KEYCHAIN" 2>/dev/null &&
        security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -qF "\"$SIGN_NAME\""
}

SIGN_ARGS=()
if [[ -n "${SAYIT_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SAYIT_SIGN_IDENTITY"
elif local_identity; then
    IDENTITY="$SIGN_NAME"
    SIGN_ARGS=(--keychain "$SIGN_KEYCHAIN")
else
    warn "Could not create a local signing identity - signing ad hoc"
    IDENTITY="-"
fi

# --- build -------------------------------------------------------------------
xml() {  # escape for an XML text node
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    printf '%s' "$s"
}

# The sources, the repository path, the signing identity and the build recipe
# itself (compile, bundle, sign - everything between the two markers below).
SOURCES_HASH=$( { find "$MAC_DIR/Sources" -name '*.swift' -print0 | sort -z | xargs -0 cat
                  printf '%s\n' "$REPO_ROOT" "$IDENTITY"
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

    log "Drawing the app icon"
    "${SWIFTC[@]}" "$MAC_DIR"/Sources/Common/*.swift "$MAC_DIR/Sources/Icon/main.swift" -o "$BUILD/sayit-icon"
    rm -rf "$BUILD/AppIcon.iconset"
    "$BUILD/sayit-icon" "$BUILD/AppIcon.iconset"
    iconutil -c icns -o "$STAGE/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

    if [[ "$IDENTITY" == - ]]; then log "Signing ad hoc"; else log "Signing with \"$IDENTITY\""; fi
    codesign --force ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$IDENTITY" --identifier "$BUNDLE_ID.rec" "$STAGE/Contents/MacOS/sayit-rec"
    codesign --force ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$IDENTITY" --identifier "$BUNDLE_ID.paste" "$STAGE/Contents/MacOS/sayit-paste"
    codesign --force ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$IDENTITY" "$STAGE"
# --- end build recipe ----------------------------------------------------------

    # Replace the installed app only now that the new one is complete.
    [[ $LAUNCHD -eq 1 ]] && unload "$AGENT_LABEL"
    mkdir -p "$APP_DIR"
    OLD_REQ=""
    if [[ -d "$DEST" ]]; then
        old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
        [[ "$old" == "$BUNDLE_ID" ]] || die "$DEST exists and is not Sayit ($old) - move it away and re-run"
        OLD_REQ=$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^#* *designated => //p')
        rm -rf "$DEST"
    fi
    ditto "$STAGE" "$DEST"
    # Tell Launch Services about the new bundle, so Finder and Launchpad pick
    # up its icon without waiting for their own rescan.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST" >/dev/null 2>&1 || true
    log "Installed $DEST"
    # A copy an earlier install left in the other place would be found first
    # by a manual run of bin/sayit, and is stale from now on.
    for app in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
        [[ "$app" == "$DEST" ]] || remove_ours "$app"
    done
    # A grant stays only while the designated requirement does. When it
    # changes (an ad-hoc build, or the first build with a new identity), the
    # old entries can still look switched on in System Settings while they no
    # longer apply - reset them, so macOS asks afresh instead.
    NEW_REQ=$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^#* *designated => //p')
    if [[ -n "$INSTALLED_HASH" && "$NEW_REQ" != "${OLD_REQ:-}" ]]; then
        tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
        tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
        warn "The signature changed: allow Sayit under Microphone and Accessibility"
        warn "again when asked (System Settings > Privacy & Security)."
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
