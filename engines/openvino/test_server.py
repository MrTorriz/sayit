#!/usr/bin/env python3
"""Protocol and audio validation tests; no model, GPU or microphone needed."""
import io
import socket
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import wave
from server import Handler, HTTPServer, LocalHTTPServer, Transcriber, parse_request, read_wave


def multipart(audio, extra=b""):
    return (b'--test\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
            b'Content-Type: audio/wav\r\n\r\n' + audio + b'\r\n' + extra + b'--test--\r\n')


def wav(rate=16000):
    data = io.BytesIO()
    with wave.open(data, "wb") as out:
        out.setparams((1, 2, rate, 0, "NONE", "none"))
        out.writeframes(b"\0" * 3200)
    return data.getvalue()


class Protocol(unittest.TestCase):
    def test_port_can_be_rebound_by_original_server_immediately(self):
        with LocalHTTPServer(("127.0.0.1", 0), Handler) as server:
            port = server.server_port
            worker = threading.Thread(target=server.handle_request)
            worker.start()
            with urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
                response.read()
            worker.join(timeout=5)
        with socket.socket() as original:
            original.setsockopt(socket.SOL_SOCKET,
                                getattr(socket, "SO_REUSEPORT", socket.SO_REUSEADDR), 1)
            original.bind(("127.0.0.1", port))

    def test_unicode_prompt_is_literal(self):
        extra = ('--test\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n'
                 '@namn med åäö\r\n').encode()
        audio, fields = parse_request("multipart/form-data; boundary=test", multipart(wav(), extra))
        self.assertEqual(fields["prompt"], "@namn med åäö")
        self.assertEqual(read_wave(audio), b"\0" * 3200)

    def test_rejects_truncated_wave(self):
        with self.assertRaises(ValueError):
            read_wave(wav()[:-2])

    def test_rejects_wrong_sample_rate(self):
        with self.assertRaises(ValueError):
            read_wave(wav(48000))

    def test_rejects_duplicate_audio(self):
        body = multipart(wav()).replace(b'--test--\r\n', multipart(wav()))
        with self.assertRaises(ValueError):
            parse_request("multipart/form-data; boundary=test", body)

    def test_rejects_non_multipart(self):
        with self.assertRaises(ValueError):
            parse_request("text/plain", b"hello")

    def test_empty_prompt_does_not_trigger_previous_transcript_prefix(self):
        import numpy as np
        from types import SimpleNamespace
        calls = []
        def generate(_data, **kwargs):
            calls.append(kwargs)
            return "repeated repeated" if kwargs.get("initial_prompt") == "" else "Rätt text."
        engine = Transcriber.__new__(Transcriber)
        engine.np = np
        engine.gate = SimpleNamespace(has_speech=lambda *_: True)
        engine.pipe = SimpleNamespace(generate=generate)
        self.assertEqual(engine.transcribe(wav(), {"prompt": ""}), "Rätt text.")
        engine.transcribe(wav(), {"prompt": "@egna namn"})
        self.assertEqual(calls[-1]["initial_prompt"], "@egna namn")
        self.assertEqual(engine.transcribe(wav(), {"prompt": ""}), "Rätt text.")
        self.assertNotIn("initial_prompt", calls[-1])

    def request_with(self, callback):
        class Engine:
            transcribe = staticmethod(callback)
        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            server.transcriber = Engine()
            worker = threading.Thread(target=server.handle_request)
            worker.start()
            try:
                req = Request(f"http://127.0.0.1:{server.server_port}/inference",
                              multipart(wav()), {"Content-Type": "multipart/form-data; boundary=test"})
                with urlopen(req, timeout=5) as response:
                    return response.status, response.read()
            finally:
                worker.join(timeout=5)

    def test_silence_is_empty_success(self):
        self.assertEqual(self.request_with(lambda *_: ""), (200, b""))

    def test_unicode_response(self):
        self.assertEqual(self.request_with(lambda *_: "Rätt ord."), (200, "Rätt ord.".encode()))

    def test_failure_allows_existing_cli_fallback(self):
        def fail(*_):
            raise RuntimeError("internal details must not reach the client")
        with self.assertRaises(HTTPError) as raised:
            self.request_with(fail)
        self.assertEqual(raised.exception.code, 503)
        self.assertEqual(raised.exception.read(), b"transcription unavailable")
        raised.exception.close()


if __name__ == "__main__":
    unittest.main()
