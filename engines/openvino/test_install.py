#!/usr/bin/env python3
"""Model integrity and engine transitions without downloads or systemd changes."""
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import download
import manage

REAL_READY = manage.ready


class ModelInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.target = self.root / "target"
        self.data = b"model fixture"
        self.entry = {"file": "model.bin", "bytes": len(self.data),
                      "sha256": hashlib.sha256(self.data).hexdigest()}
        self.manifest = {"files": [self.entry], "repo": "example/model", "revision": "pinned"}
        (self.source / "model.bin").write_bytes(self.data)

    def test_copy_and_cached_model_are_both_verified(self):
        download.install(self.target, self.manifest, self.source)
        with patch.object(download, "urlopen", side_effect=AssertionError("unexpected network")):
            download.install(self.target, self.manifest)
        self.assertEqual((self.target / "model.bin").read_bytes(), self.data)

    def test_corrupt_cache_is_replaced_from_valid_source(self):
        self.target.mkdir()
        (self.target / "model.bin").write_bytes(b"x" * len(self.data))
        download.install(self.target, self.manifest, self.source)
        self.assertEqual((self.target / "model.bin").read_bytes(), self.data)

    def test_corrupt_download_never_replaces_existing_file(self):
        import io
        self.target.mkdir()
        (self.target / "model.bin").write_bytes(b"previous")
        with patch.object(download, "urlopen", return_value=io.BytesIO(b"corrupt")):
            with self.assertRaisesRegex(ValueError, "checksum"):
                download.install(self.target, self.manifest)
        self.assertEqual((self.target / "model.bin").read_bytes(), b"previous")
        self.assertFalse((self.target / "model.bin.partial").exists())

    def test_invalid_source_is_rejected(self):
        (self.source / "model.bin").write_bytes(b"incorrect")
        with self.assertRaisesRegex(ValueError, "checksum"):
            download.install(self.target, self.manifest, self.source)
        self.assertFalse((self.target / "model.bin").exists())

    def test_manifest_paths_cannot_escape_destination(self):
        self.entry["file"] = "../outside"
        with self.assertRaisesRegex(ValueError, "filename"):
            download.install(self.target, self.manifest, self.source)

    def test_shipped_manifest_pins_every_file(self):
        manifest = json.loads(Path(__file__).with_name("model-provenance.json").read_text())
        self.assertRegex(manifest["revision"], r"^[0-9a-f]{40}$")
        self.assertGreater(len(manifest["files"]), 10)
        for entry in manifest["files"]:
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(entry["bytes"], 0)


class EngineSwitch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo with spaces"
        self.config = self.root / "config"
        self.run = self.root / "run"
        self.run.mkdir()
        self.dropin = self.config / "systemd/user/sayit-daemon.service.d/20-openvino.conf"
        self.other = self.dropin.with_name("10-custom.conf")
        self.other.parent.mkdir(parents=True)
        self.other.write_text("[Service]\nNice=5\n")
        template = self.repo / "config/systemd/sayit-daemon.service"
        template.parent.mkdir(parents=True)
        template.write_text('[Service]\nWorkingDirectory=%h/path/to/sayit\nExecStart=%h/path/to/sayit/bin/sayit-daemon\n[Install]\nWantedBy=default.target\n')
        self.ctl = patch.object(manage, "systemctl", return_value="").start()
        self.ready = patch.object(manage, "ready", return_value=True).start()
        self.addCleanup(patch.stopall)

    def switch(self, mode):
        manage.switch(mode, self.repo, 9876, self.config, self.run)

    def test_success_persists_mode_and_preserves_unrelated_overrides(self):
        self.switch("fast")
        self.assertIn(f'ExecStart="{self.repo}/bin/sayit-openvino"', self.dropin.read_text())
        self.assertEqual(self.other.read_text(), "[Service]\nNice=5\n")
        self.ctl.assert_any_call("enable", manage.SERVICE)
        self.switch("accurate")
        self.assertFalse(self.dropin.exists())
        self.assertTrue(self.other.exists())

    def test_failed_switch_restores_previous_dropin_exactly(self):
        original = b"[Service]\nExecStart=\nExecStart=/previous/launch.sh\n"
        self.dropin.write_bytes(original)
        self.ready.return_value = False
        with self.assertRaisesRegex(RuntimeError, "restored"):
            self.switch("accurate")
        self.assertEqual(self.dropin.read_bytes(), original)
        self.ctl.assert_any_call("restart", manage.SERVICE)

    def test_failed_fast_start_restores_native_mode(self):
        self.ready.return_value = False
        with self.assertRaises(RuntimeError):
            self.switch("fast")
        self.assertFalse(self.dropin.exists())

    def test_recording_and_transcribing_block_engine_switch(self):
        with (self.run / "sayit-engine.lock").open("w") as held:
            fcntl.flock(held, fcntl.LOCK_SH)
            with self.assertRaisesRegex(RuntimeError, "dictation"):
                self.switch("fast")
        self.ctl.assert_not_called()

    def test_session_marker_also_blocks_older_clients(self):
        (self.run / "sayit.session").touch()
        with self.assertRaisesRegex(RuntimeError, "dictation"):
            self.switch("fast")
        self.ctl.assert_not_called()

    def test_first_use_installs_a_service_with_quoted_paths(self):
        def ctl(*args):
            if args[0] == "cat":
                raise subprocess.CalledProcessError(1, "systemctl")
            return ""
        self.ctl.side_effect = ctl
        self.switch("fast")
        service = self.config / "systemd/user" / manage.SERVICE
        self.assertIn(f'WorkingDirectory="{self.repo}"', service.read_text())
        self.assertIn(f'ExecStart="{self.repo}/bin/sayit-daemon"', service.read_text())

    def test_failed_first_use_removes_only_the_created_service(self):
        def ctl(*args):
            if args[0] == "cat":
                raise subprocess.CalledProcessError(1, "systemctl")
            return ""
        self.ctl.side_effect = ctl
        self.ready.return_value = False
        with self.assertRaises(RuntimeError):
            self.switch("fast")
        self.assertFalse((self.config / "systemd/user" / manage.SERVICE).exists())
        self.assertFalse(self.dropin.exists())
        self.assertTrue(self.other.exists())

    def test_health_must_match_requested_engine(self):
        cases = [
            ("fast", {"status": "ok"}, False),
            ("accurate", {"engine": "openvino-turbo", "ready": True}, False),
            ("fast", {"engine": "openvino-turbo", "ready": True}, True),
            ("accurate", {"status": "ok"}, True),
            ("fast", {"engine": "openvino-turbo", "ready": False}, False),
        ]
        for mode, reply, expected in cases:
            with self.subTest(mode=mode, reply=reply):
                with patch.object(manage, "health", return_value=reply), \
                     patch.object(manage.time, "sleep"), \
                     patch.object(manage.time, "monotonic", side_effect=[0, 0, 2]):
                    self.assertEqual(REAL_READY(mode, 9876, timeout=1), expected)


if __name__ == "__main__":
    unittest.main()
