#!/usr/bin/env bash
# Install the optional Linux Turbo runtime. Does not switch or restart services.
# Usage: ./install-openvino.sh [--python PATH] [--model-source DIR]
# Exit 1 on unsupported runtime, failed download/checksum or failed model check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python=python3
source_dir=""
while (( $# )); do
    case "$1" in
        --help|-h)
            echo 'Usage: ./install-openvino.sh [--python PATH] [--model-source DIR]'
            echo 'Run install.sh first. Requires Python venv/pip and Intel GPU drivers.'
            echo 'Downloads about 1.6 GB of model files plus the isolated Python runtime.'
            echo '--model-source copies an existing model after verifying every checksum.'
            echo 'Reads OPENVINO_HOME, OPENVINO_DEVICE and VAD paths from .env.'
            echo 'Leaves the running service unchanged. Activate with ./bin/sayit-engine fast.'
            exit 0 ;;
        --python) python="${2:?--python requires a path}"; shift 2 ;;
        --model-source) source_dir="${2:?--model-source requires a directory}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ "$(uname -s)" == Linux ]] || { echo 'This installer supports Linux only.' >&2; exit 1; }
[[ -f "$REPO_ROOT/.env" ]] || { echo 'Run ./install.sh first.' >&2; exit 1; }
# shellcheck source=/dev/null
source "$REPO_ROOT/.env"
runtime="${OPENVINO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/sayit/openvino}"
# Replacing packages beneath a running Python process is not a safe upgrade.
main_pid=$(systemctl --user show sayit-daemon.service -p MainPID --value 2>/dev/null || true)
if [[ "$main_pid" =~ ^[1-9][0-9]*$ && -r "/proc/$main_pid/cmdline" ]]; then
    IFS= read -r -d '' executable < "/proc/$main_pid/cmdline" || true
    [[ "$executable" != "$runtime/venv/bin/python" ]] || {
        echo 'Switch to ./bin/sayit-engine accurate before upgrading the active runtime.' >&2
        exit 1
    }
fi
mkdir -p "$runtime"
exec 9>"$runtime/install.lock"
flock -n 9 || { echo 'An installation is already running.' >&2; exit 1; }
export CI=true PYTHONNOUSERSITE=1
unset PYTHONPATH
"$python" -m venv "$runtime/venv"
"$runtime/venv/bin/python" -m pip install --disable-pip-version-check \
    -r "$REPO_ROOT/engines/openvino/requirements.txt"
# Fail before downloading the large model when the requested device is absent.
"$runtime/venv/bin/python" - "${OPENVINO_DEVICE:-GPU}" <<'PY'
import sys
import openvino as ov
core = ov.Core()
try:
    core.get_property(sys.argv[1], "FULL_DEVICE_NAME")
except RuntimeError:
    raise SystemExit(f'Device {sys.argv[1]} unavailable; detected {core.available_devices}. See docs/OPENVINO.md.') from None
PY
download_args=(--destination "$runtime/model")
[[ -z "$source_dir" ]] || download_args+=(--source "$source_dir")
"$runtime/venv/bin/python" "$REPO_ROOT/engines/openvino/download.py" "${download_args[@]}"
"$REPO_ROOT/bin/sayit-openvino" --check
echo 'Turbo runtime verified. Activate with: ./bin/sayit-engine fast'
