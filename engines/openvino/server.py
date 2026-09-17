#!/usr/bin/env python3
"""Local OpenVINO dictation server compatible with Sayit's text requests.

Usage: server.py --model DIR --vad-model FILE --whisper-lib FILE [--port 9876]
Audio stays in memory; stdout/stderr never contain transcribed text.
"""
import os

# OpenVINO's documented CI switch disables its import/conversion telemetry.
os.environ["CI"] = "true"

import argparse
import ctypes as ct
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
import math
import sys
import wave

MAX_BODY = 64 * 1024 * 1024


def parse_request(content_type, body):
    if not content_type.lower().startswith("multipart/form-data;"):
        raise ValueError("multipart required")
    message = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: " + content_type.encode("ascii") + b"\r\n\r\n" + body
    )
    if not message.is_multipart():
        raise ValueError("invalid multipart")
    fields = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name in fields:
            raise ValueError("duplicate field")
        fields[name] = part.get_payload(decode=True)
    audio = fields.pop("file", None)
    if audio is None:
        raise ValueError("missing audio")
    fields = {key: value.decode("utf-8") for key, value in fields.items()}
    if fields.get("response_format", "text") != "text":
        raise ValueError("text response required")
    return audio, fields


def read_wave(audio):
    with wave.open(io.BytesIO(audio)) as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000, 1, 2):
            raise ValueError("16 kHz mono s16 WAV required")
        frames = wav.readframes(wav.getnframes())
        if len(frames) != wav.getnframes() * 2:
            raise ValueError("truncated WAV")
    return frames


class VadParams(ct.Structure):
    _fields_ = [("n_threads", ct.c_int), ("use_gpu", ct.c_bool), ("gpu_device", ct.c_int)]


class SpeechGate:
    """Silero from the installed whisper.cpp ABI; reset state per request.

    Detect speech without cutting the recording, preserving quiet word endings.
    """
    def __init__(self, library, model):
        self.lib = ct.CDLL(library)
        self.lib.whisper_version.argtypes = []
        self.lib.whisper_version.restype = ct.c_char_p
        version = self.lib.whisper_version().decode("ascii")
        # These versions use the three-field VAD context struct below. Refuse
        # unreviewed ABIs instead of passing a guessed struct to native code.
        if version not in ("1.8.4", "1.9.2"):
            raise RuntimeError(f"Unsupported libwhisper VAD ABI: {version}; see docs/OPENVINO.md")
        self.lib.whisper_vad_init_from_file_with_params.argtypes = [ct.c_char_p, VadParams]
        self.lib.whisper_vad_init_from_file_with_params.restype = ct.c_void_p
        self.lib.whisper_vad_detect_speech.argtypes = [ct.c_void_p, ct.POINTER(ct.c_float), ct.c_int]
        self.lib.whisper_vad_detect_speech.restype = ct.c_bool
        self.lib.whisper_vad_n_probs.argtypes = [ct.c_void_p]
        self.lib.whisper_vad_n_probs.restype = ct.c_int
        self.lib.whisper_vad_probs.argtypes = [ct.c_void_p]
        self.lib.whisper_vad_probs.restype = ct.POINTER(ct.c_float)
        self.ctx = self.lib.whisper_vad_init_from_file_with_params(
            os.fsencode(model), VadParams(4, False, 0)
        )
        if not self.ctx:
            raise RuntimeError("VAD initialization failed")

    def has_speech(self, data, threshold):
        if not len(data):
            return False
        if not self.lib.whisper_vad_detect_speech(
            self.ctx, data.ctypes.data_as(ct.POINTER(ct.c_float)), len(data)
        ):
            raise RuntimeError("VAD inference failed")
        count = self.lib.whisper_vad_n_probs(self.ctx)
        probabilities = self.lib.whisper_vad_probs(self.ctx)
        return any(probabilities[i] >= threshold for i in range(count))


class Transcriber:
    def __init__(self, args):
        import numpy as np
        import openvino_genai as genai
        self.np = np
        self.gate = SpeechGate(args.whisper_lib, args.vad_model)
        self.pipe = genai.WhisperPipeline(args.model, args.device, CACHE_DIR=args.cache,
                                         PERFORMANCE_HINT="LATENCY")
        # Compile kernels before accepting dictations. Discard the result.
        warmup = dict(task="transcribe", max_new_tokens=8)
        if args.language != "auto":
            warmup["language"] = "<|" + args.language + "|>"
        self.pipe.generate(np.zeros(16000, dtype=np.float32), **warmup)

    def transcribe(self, audio, fields):
        data = self.np.frombuffer(read_wave(audio), dtype="<i2").astype(self.np.float32) / 32768
        threshold = float(fields.get("vad_threshold", "0.30"))
        if not math.isfinite(threshold) or not 0 <= threshold <= 1:
            raise ValueError("invalid VAD threshold")
        language = fields.get("language", "sv")
        if language != "auto" and (not language.isalpha() or len(language) not in (2, 3)):
            raise ValueError("invalid language")
        if not self.gate.has_speech(data, threshold):
            return ""
        args = dict(task="transcribe", return_timestamps=False, num_beams=1,
                    max_new_tokens=440)
        # An empty string is not equivalent to no prompt in this runtime:
        # it adds a previous-transcript prefix and can trigger repetitions.
        if fields.get("prompt"):
            args["initial_prompt"] = fields["prompt"]
        if language != "auto":
            args["language"] = "<|" + language + "|>"
        result = self.pipe.generate(data, **args)
        return str(result).strip()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_):
        pass

    def reply(self, status, body, content_type="text/plain; charset=utf-8"):
        body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/health"):
            self.reply(200, json.dumps({"engine": "openvino-turbo", "ready": True}), "application/json")
        else:
            self.reply(404, "not found")

    def do_POST(self):
        if self.path != "/inference":
            self.reply(404, "not found")
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_BODY:
                self.reply(413, "invalid request size")
                return
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError("incomplete request")
            audio, fields = parse_request(self.headers.get("Content-Type", ""), body)
            text = self.server.transcriber.transcribe(audio, fields)
        except (ValueError, UnicodeError, wave.Error, EOFError):
            self.reply(400, "invalid audio or parameters")
            return
        except Exception:
            # A non-200 response makes Sayit use its existing local CLI fallback.
            print("OpenVINO request failed; client may use local fallback", file=sys.stderr, flush=True)
            self.reply(503, "transcription unavailable")
            return
        self.reply(200, text)


class LocalHTTPServer(HTTPServer):
    # The installed whisper-server uses SO_REUSEPORT, not SO_REUSEADDR.
    # Match it so switching back does not wait for old connections to expire.
    allow_reuse_port = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--vad-model", required=True)
    parser.add_argument("--whisper-lib", required=True)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--device", default="GPU")
    parser.add_argument("--language", default="sv")
    parser.add_argument("--check", action="store_true", help="load and warm up, then exit without listening")
    parser.add_argument("--port", type=int, default=9876)
    args = parser.parse_args()
    transcriber = Transcriber(args)
    if args.check:
        print("OpenVINO model and VAD ready", flush=True)
        return
    # One inference at a time: neither model state nor VAD state can overlap.
    with LocalHTTPServer(("127.0.0.1", args.port), Handler) as server:
        server.transcriber = transcriber
        print("OpenVINO dictation ready on loopback", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
