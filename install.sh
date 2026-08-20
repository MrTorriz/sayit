#!/usr/bin/env bash
# install.sh — one-time setup for sayit
#
# Verifies system packages (Fedora/Debian/Ubuntu/Arch), builds whisper.cpp at
# a pinned release (with Vulkan when available), downloads a Whisper model +
# the Silero VAD model with sha256 verification, creates .env and seeds the
# user wordlist. Re-running is safe: existing artifacts are left untouched.
#
# Flags:
#   -y, --yes           answer yes to all prompts
#   --model SIZE        model size to download: small | medium | large (default: medium)
#   --rebuild           re-fetch and rebuild whisper.cpp at the pinned release
#                       (upgrade path; also repairs a broken build)
#   --skip-packages     skip the system package check
#   --skip-build        skip building whisper.cpp
#   --skip-model        skip the model downloads
#   -h, --help          show help and exit
#
# Upgrade/rollback:
#   ./install.sh --rebuild                      # build the pinned WHISPER_REF
#   WHISPER_REF=<tag|commit> ./install.sh --rebuild   # pin something else
#   The previously built revision is recorded in $WHISPER_SRC/.sayit-build-info.
#
# Exit codes:
#   0  Successful installation
#   1  Bad flag, missing package declined by the user, build failure, or
#      checksum mismatch on a downloaded model

set -euo pipefail

show_help() {
    cat <<'EOF'
install.sh — one-time setup for sayit

Usage:
  ./install.sh [flags]

Flags:
  -y, --yes           answer yes to all prompts
  --model SIZE        model size to download: small | medium | large (default: medium)
  --rebuild           re-fetch and rebuild whisper.cpp at the pinned release
  --skip-packages     skip the system package check
  --skip-build        skip building whisper.cpp
  --skip-model        skip the model downloads
  -h, --help          show this help

Examples:
  ./install.sh                        # interactive installation
  ./install.sh -y                     # answer yes to everything
  ./install.sh --model large          # best accuracy (slower, more RAM)
  ./install.sh --rebuild              # upgrade whisper.cpp to the pinned release
  ./install.sh --skip-packages        # packages already installed
  ./install.sh --skip-build --skip-model  # only create .env + wordlist

Rollback: WHISPER_REF=<older tag or commit> ./install.sh --rebuild
EOF
}

YES=0
SKIP_PACKAGES=0
SKIP_BUILD=0
SKIP_MODEL=0
REBUILD=0
MODEL_SIZE="medium"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) YES=1; shift ;;
        --rebuild) REBUILD=1; shift ;;
        --model)
            MODEL_SIZE="${2:?--model requires a size: small|medium|large}"
            [[ "$MODEL_SIZE" =~ ^(small|medium|large)$ ]] \
                || { echo "Invalid model size: $MODEL_SIZE (use small, medium or large)" >&2; exit 1; }
            shift 2 ;;
        --skip-packages) SKIP_PACKAGES=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-model) SKIP_MODEL=1; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; echo "Run './install.sh --help' to see available flags." >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_SRC="${WHISPER_SRC:-$HOME/.local/src/whisper.cpp}"
WHISPER_BIN="$HOME/.local/bin/whisper-cli"
MODEL_DIR="$REPO_ROOT/models"
MODEL_FILE="$MODEL_DIR/ggml-kb-whisper-$MODEL_SIZE-q5_0.bin"
MODEL_URL="https://huggingface.co/KBLab/kb-whisper-$MODEL_SIZE/resolve/main/ggml-model-q5_0.bin"
VAD_FILE="$MODEL_DIR/ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
WORDLIST_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sayit/wordlist.tsv"

# Pinned upstream revision for whisper.cpp (release tag or commit). Bump
# deliberately when upgrading; override for rollback:
#   WHISPER_REF=<tag|commit> ./install.sh --rebuild
WHISPER_REF="${WHISPER_REF:-v1.9.2}"

# Official sha256 checksums, taken from the Hugging Face LFS pointer files
# (huggingface.co/KBLab/kb-whisper-<size>/raw/main/ggml-model-q5_0.bin and
# huggingface.co/ggml-org/whisper-vad). Verified 2026-08-20.
MODEL_SHA256=""
case "$MODEL_SIZE" in
    small)  MODEL_SHA256="6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7" ;;
    medium) MODEL_SHA256="7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0" ;;
    large)  MODEL_SHA256="6d2863812d7410322bb7d8647a5c7260761300fa946714c9ed66d22bb30bcb19" ;;
esac
VAD_SHA256="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"

log()  { printf '\033[1;34m[sayit]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warning]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Verify system packages (per-distro package names)
if [[ $SKIP_PACKAGES -eq 0 ]]; then
    # ydotool + wl-clipboard: primary injection (clipboard + Shift+Insert)
    # jq: sayit-bt (Bluetooth profile switching), libnotify: notifications
    # wtype: injection fallback on wlroots (not KWin), espeak-ng: test-pipeline
    PM=""
    if command -v dnf >/dev/null 2>&1; then
        PM="dnf"
        REQUIRED=(cmake gcc-c++ git curl pipewire-utils ydotool wl-clipboard jq libnotify)
        VULKAN=(mesa-vulkan-drivers vulkan-tools vulkan-headers vulkan-loader-devel glslc spirv-headers-devel)
        OPTIONAL=(wtype espeak-ng)
        pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }
        pkg_install() { sudo dnf install -y "$@"; }
    elif command -v apt-get >/dev/null 2>&1; then
        PM="apt"
        REQUIRED=(cmake g++ git curl pipewire-bin ydotool wl-clipboard jq libnotify-bin)
        VULKAN=(mesa-vulkan-drivers vulkan-tools libvulkan-dev glslc spirv-headers)
        OPTIONAL=(wtype espeak-ng)
        pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
        pkg_install() { sudo apt-get install -y "$@"; }
    elif command -v pacman >/dev/null 2>&1; then
        PM="pacman"
        REQUIRED=(cmake gcc git curl pipewire ydotool wl-clipboard jq libnotify)
        VULKAN=(vulkan-tools vulkan-headers vulkan-icd-loader shaderc spirv-headers)
        OPTIONAL=(wtype espeak-ng)
        pkg_installed() { pacman -Qi "$1" >/dev/null 2>&1; }
        pkg_install() { sudo pacman -S --needed --noconfirm "$@"; }
    fi

    if [[ -z "$PM" ]]; then
        warn "No supported package manager found (dnf/apt/pacman)."
        warn "Install these yourself, then re-run with --skip-packages:"
        warn "  required: cmake, a C++ compiler, git, PipeWire tools (pw-record),"
        warn "            ydotool, wl-clipboard, jq, libnotify (notify-send)"
        warn "  for GPU:  Vulkan drivers + headers, glslc, SPIR-V headers"
        warn "  optional: wtype (wlroots fallback), espeak-ng (test-pipeline)"
        die "Cannot verify packages on this distribution"
    fi

    log "Checking system packages ($PM)"
    MISSING=()
    for pkg in "${REQUIRED[@]}" "${VULKAN[@]}"; do
        pkg_installed "$pkg" || MISSING+=("$pkg")
    done
    for pkg in "${OPTIONAL[@]}"; do
        pkg_installed "$pkg" || warn "Optional package missing: $pkg (wtype = wlroots fallback, espeak-ng = test-pipeline)"
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Missing packages: ${MISSING[*]}"
        if [[ $YES -eq 1 ]]; then
            pkg_install "${MISSING[@]}" || die "Package installation failed — see above"
        else
            read -rp "Install now? (y/N) " answer
            if [[ "$answer" =~ ^[yY]$ ]]; then
                pkg_install "${MISSING[@]}" || die "Package installation failed — see above"
            else
                die "Aborting — install the packages yourself or run with --skip-packages"
            fi
        fi
    else
        log "All required packages present"
    fi
fi

# 2. Build whisper.cpp at the pinned revision (Vulkan when available)
if [[ $SKIP_BUILD -eq 1 ]]; then
    log "Skipping whisper.cpp build"
elif [[ ! -x "$WHISPER_BIN" || $REBUILD -eq 1 ]]; then
    log "Fetching whisper.cpp $WHISPER_REF into $WHISPER_SRC"
    if [[ ! -d "$WHISPER_SRC" ]]; then
        mkdir -p "$(dirname "$WHISPER_SRC")"
        git clone --depth 1 --branch "$WHISPER_REF" \
            https://github.com/ggml-org/whisper.cpp.git "$WHISPER_SRC"
    else
        # Guard against a directory left behind by a hard-killed clone.
        git -C "$WHISPER_SRC" rev-parse --git-dir >/dev/null 2>&1 \
            || die "$WHISPER_SRC exists but is not a git repository (interrupted clone?) — remove the directory and re-run"
        git -C "$WHISPER_SRC" fetch --depth 1 origin tag "$WHISPER_REF" 2>/dev/null \
            || git -C "$WHISPER_SRC" fetch --depth 1 origin "$WHISPER_REF"
        git -C "$WHISPER_SRC" checkout --detach "$WHISPER_REF"
    fi

    # Auto-detect Vulkan development support (shader compiler + headers)
    VULKAN_FLAG="-DGGML_VULKAN=1"
    if ! command -v glslc >/dev/null || [[ ! -f /usr/include/vulkan/vulkan.h ]]; then
        warn "Vulkan development packages missing — building CPU-only (still fast on modern CPUs)"
        warn "For GPU acceleration, install the Vulkan headers, loader and glslc, then re-run"
        VULKAN_FLAG=""
    fi

    log "Building whisper.cpp ${VULKAN_FLAG:+with Vulkan support}"
    cmake -S "$WHISPER_SRC" -B "$WHISPER_SRC/build" $VULKAN_FLAG -DCMAKE_BUILD_TYPE=Release
    cmake --build "$WHISPER_SRC/build" -j"$(nproc)" --config Release

    mkdir -p "$HOME/.local/bin"
    ln -sf "$WHISPER_SRC/build/bin/whisper-cli" "$WHISPER_BIN"
    # Record what was built, for reproducibility and rollback.
    {
        printf 'ref=%s\n' "$WHISPER_REF"
        printf 'commit=%s\n' "$(git -C "$WHISPER_SRC" rev-parse HEAD)"
        printf 'vulkan=%s\n' "$([[ -n "$VULKAN_FLAG" ]] && echo yes || echo no)"
        printf 'date=%s\n' "$(date -Iseconds)"
    } > "$WHISPER_SRC/.sayit-build-info" || true
    log "whisper-cli linked to $WHISPER_BIN"
else
    log "whisper-cli already present at $WHISPER_BIN — run './install.sh --rebuild' to update to $WHISPER_REF"
fi

# Verify a downloaded artifact against its pinned sha256 before activating it.
verify_sha256() {  # verify_sha256 <file> <sha256>
    printf '%s  %s\n' "$2" "$1" | sha256sum -c --status
}

# 3. Download the Whisper model (KB-Whisper, quantized q5_0)
mkdir -p "$MODEL_DIR"
if [[ $SKIP_MODEL -eq 1 ]]; then
    log "Skipping model download"
elif [[ ! -f "$MODEL_FILE" ]]; then
    command -v curl >/dev/null || die "curl missing — install it with your package manager"
    log "Downloading KB-Whisper $MODEL_SIZE (q5_0)"
    # -C - resumes an interrupted download from the kept .partial file.
    if ! curl -L --fail --progress-bar -C - -o "$MODEL_FILE.partial" "$MODEL_URL"; then
        die "Download failed — check your network and re-run the script to resume"
    fi
    log "Verifying model checksum"
    if ! verify_sha256 "$MODEL_FILE.partial" "$MODEL_SHA256"; then
        rm -f "$MODEL_FILE.partial"
        die "Checksum mismatch for the downloaded model — corrupted download or changed upstream file; re-run to retry"
    fi
    mv "$MODEL_FILE.partial" "$MODEL_FILE"
else
    log "Model already present at $MODEL_FILE"
fi

# 3b. Download the Silero VAD model (filters non-speech -> less hallucination)
if [[ $SKIP_MODEL -eq 1 ]]; then
    log "Skipping VAD model"
elif [[ ! -f "$VAD_FILE" ]]; then
    command -v curl >/dev/null || die "curl missing — install it with your package manager"
    log "Downloading Silero VAD model (~1 MB)"
    if ! curl -L --fail --progress-bar -C - -o "$VAD_FILE.partial" "$VAD_URL"; then
        warn "VAD download failed — VAD stays disabled until the file exists"
    elif ! verify_sha256 "$VAD_FILE.partial" "$VAD_SHA256"; then
        rm -f "$VAD_FILE.partial"
        warn "VAD model checksum mismatch — file discarded; VAD stays disabled"
    else
        mv "$VAD_FILE.partial" "$VAD_FILE"
    fi
else
    log "VAD model already present at $VAD_FILE"
fi

# 4. Create .env from the template if missing
if [[ ! -f "$REPO_ROOT/.env" ]]; then
    [[ -f "$REPO_ROOT/.env.example" ]] || die ".env.example not found — is the repo damaged?"
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    # Non-default model size: point MODEL_PATH at the downloaded file
    if [[ "$MODEL_SIZE" != "medium" ]]; then
        sed -i "s|^MODEL_PATH=.*|MODEL_PATH=\"$MODEL_FILE\"|" "$REPO_ROOT/.env"
    fi
    log "Created .env from template"
else
    log ".env already exists — left untouched"
    # Surface template settings missing from the existing .env, so upgrades
    # never silently run on in-script fallback defaults.
    MISSING_VARS=$(comm -23 \
        <(grep -oE '^[A-Za-z_]+=' "$REPO_ROOT/.env.example" | sort -u) \
        <(grep -oE '^[A-Za-z_]+=' "$REPO_ROOT/.env" | sort -u) \
        | tr -d '=' | xargs || true)
    if [[ -n "${MISSING_VARS:-}" ]]; then
        warn "New settings in .env.example missing from your .env: $MISSING_VARS"
        warn "Copy the ones you want from .env.example (defaults apply meanwhile)"
    fi
    if [[ "$MODEL_SIZE" != "medium" ]]; then
        log "To activate the $MODEL_SIZE model, set in .env:"
        log "  MODEL_PATH=\"$MODEL_FILE\""
        log "then restart the daemon: systemctl --user restart sayit-daemon.service"
    fi
fi

# 5. Seed the user wordlist from the example if missing
if [[ ! -f "$WORDLIST_FILE" ]]; then
    mkdir -p "$(dirname "$WORDLIST_FILE")"
    cp "$REPO_ROOT/config/wordlist.example.tsv" "$WORDLIST_FILE"
    log "Seeded wordlist at $WORDLIST_FILE"
else
    log "Wordlist already exists at $WORDLIST_FILE — left untouched"
fi

# 6. Verify that Vulkan sees a GPU
if command -v vulkaninfo >/dev/null; then
    GPU=$(vulkaninfo --summary 2>/dev/null | grep -E "deviceName" | head -1 || true)
    if [[ -n "$GPU" ]]; then
        log "Vulkan GPU: $GPU"
    else
        warn "No Vulkan GPU found — whisper.cpp falls back to CPU"
    fi
fi

log "Done. Try: ./bin/test-pipeline"
log "Then bind ./bin/sayit to a hotkey or mouse button — see README"
