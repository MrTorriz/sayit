#!/usr/bin/env python3
"""Switch the Linux user service, restoring its previous configuration on failure."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import urlopen

SERVICE = "sayit-daemon.service"


def systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


def systemd_path(path, executable=True):
    # Quoted ExecStart paths still expand specifiers and environment variables.
    value = str(path).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    value = value.replace("\n", "\\n").replace("\r", "\\r")
    return value.replace("$", "$$") if executable else value


def atomic_write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(contents)
    temporary.replace(path)


def health(port):
    try:
        with urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
            return json.load(response)
    except (OSError, ValueError):
        return None


def ready(mode, port, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        reply = health(port)
        if reply is not None:
            if mode == "fast" and reply.get("engine") == "openvino-turbo" and reply.get("ready"):
                return True
            if mode == "accurate" and reply.get("status") == "ok" and "engine" not in reply:
                return True
        time.sleep(0.2)
    return False


def switch(mode, repo, port, config, run):
    dropin = config / "systemd/user/sayit-daemon.service.d/20-openvino.conf"
    service = config / "systemd/user" / SERVICE
    run.mkdir(parents=True, exist_ok=True)
    with (run / "sayit-engine.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Finish the current dictation or engine switch first.") from None
        if (run / "sayit.session").exists() or (run / "sayit.starting").exists():
            raise RuntimeError("Finish the current dictation before switching engines.")
        previous = dropin.read_bytes() if dropin.exists() else None
        created_service = False
        try:
            systemctl("cat", SERVICE)
        except subprocess.CalledProcessError:
            template = (repo / "config/systemd" / SERVICE).read_text()
            path = systemd_path(repo)
            # The template's WorkingDirectory and executable must also support spaces.
            template = template.replace("WorkingDirectory=%h/path/to/sayit", f'WorkingDirectory="{systemd_path(repo, executable=False)}"')
            template = template.replace("ExecStart=%h/path/to/sayit/bin/sayit-daemon", f'ExecStart="{path}/bin/sayit-daemon"')
            atomic_write(service, template.encode())
            created_service = True
        try:
            if mode == "fast":
                launcher = systemd_path(repo / "bin/sayit-openvino")
                atomic_write(dropin, f'[Service]\nExecStart=\nExecStart="{launcher}"\n'.encode())
            else:
                dropin.unlink(missing_ok=True)
            systemctl("daemon-reload")
            systemctl("restart", SERVICE)
            if not ready(mode, port):
                raise RuntimeError("Requested engine did not become ready.")
            systemctl("enable", SERVICE)
        except (Exception, KeyboardInterrupt):
            if previous is None:
                dropin.unlink(missing_ok=True)
            else:
                atomic_write(dropin, previous)
            if created_service:
                systemctl("stop", SERVICE)
                service.unlink(missing_ok=True)
            systemctl("daemon-reload")
            if not created_service:
                systemctl("restart", SERVICE)
            raise RuntimeError("Engine switch failed; previous configuration restored. Check journalctl --user -u sayit-daemon.service.") from None
    print(f"Sayit ready: {mode}. Starts automatically after login.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--port", type=int, default=9876)
    parser.add_argument("mode", choices=("fast", "accurate", "status"))
    args = parser.parse_args()
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    run = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
    if args.mode == "status":
        dropin = config / "systemd/user/sayit-daemon.service.d/20-openvino.conf"
        print("Configured:", "fast" if dropin.exists() else "accurate")
        reply = health(args.port)
        if reply and reply.get("engine") == "openvino-turbo":
            print("Running: Whisper Turbo / OpenVINO")
        elif reply and reply.get("status") == "ok":
            print("Running: whisper.cpp / configured GGML model")
        else:
            raise SystemExit("Daemon is not ready.")
    else:
        try:
            switch(args.mode, args.repo.resolve(), args.port, config, run)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            raise SystemExit(str(error)) from None


if __name__ == "__main__":
    main()
