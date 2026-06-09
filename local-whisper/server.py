"""
Local Whisper STT WebSocket server for Sinestesia.

Drop-in replacement for ElevenLabs / Deepgram streaming STT. Listens on
ws://localhost:8002/transcribe, expects 16kHz Int16 LE PCM as binary frames,
emits JSON transcripts as text frames matching the protocol the backend
already understands:

    {"type": "transcript", "text": "...", "is_final": false}
    {"type": "transcript", "text": "...", "is_final": true}

Uses:
  - mlx-whisper       Metal-accelerated Whisper on Apple Silicon (M1+)
  - silero-vad        Voice activity detection for segment boundaries

Streaming pattern (similar to ElevenLabs Scribe v2 with VAD commit):
  - Buffer incoming PCM into a numpy float32 array
  - Every INTERIM_INTERVAL_MS, transcribe the un-committed buffer and emit
    as is_final=false (rolling preview)
  - Run Silero VAD on the buffer continuously; when silence > VAD_SILENCE_MS
    is detected after speech, transcribe the segment, emit as is_final=true,
    drop the committed audio from the buffer
"""

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import websockets
import mlx_whisper

# silero-vad ships as a small torch model wrapped in a simple Python API.
# It's CPU-light and gives sub-100ms latency on M-series.
from silero_vad import load_silero_vad, get_speech_timestamps

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("local-whisper")

# ──────────────────────────────────────────────────────────────────────────────
# Tunables — most can be overridden via env vars at server start
# ──────────────────────────────────────────────────────────────────────────────

SAMPLE_RATE = 16_000  # MUST match what the backend / browser sends
MODEL_REPO = os.environ.get("WHISPER_MODEL", "mlx-community/whisper-medium-mlx")
# Suggested choices (size / latency tradeoff on M4 Max):
#   mlx-community/whisper-tiny-mlx-q4     ~40MB  ~50ms/segment, weakest
#   mlx-community/whisper-base-mlx-q4     ~80MB  ~80ms/segment
#   mlx-community/whisper-small-mlx-q4    ~250MB ~150ms/segment, sweet spot
#   mlx-community/whisper-medium-mlx-q4   ~770MB ~400ms/segment, very strong
#   mlx-community/whisper-large-v3-mlx-q4 ~1.5GB ~1s/segment, slowest

# Default to Portuguese — without a hint, Whisper sometimes starts in
# Russian or Spanish on the first ambiguous chunk. Override via env if
# the singer switches to English mid-show.
LANGUAGE = os.environ.get("WHISPER_LANGUAGE", "pt") or None

INTERIM_INTERVAL_MS = int(os.environ.get("INTERIM_INTERVAL_MS", "600"))
VAD_SILENCE_MS = int(os.environ.get("VAD_SILENCE_MS", "650"))
MIN_SPEECH_MS = int(os.environ.get("MIN_SPEECH_MS", "300"))
MAX_BUFFER_SECS = float(os.environ.get("MAX_BUFFER_SECS", "20"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8002"))

# ──────────────────────────────────────────────────────────────────────────────


@dataclass
class Session:
    """Per-connection rolling state."""

    # All audio since the last final commit, as float32 in [-1, 1] mono 16kHz.
    audio: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    last_interim_at: float = 0.0
    last_interim_text: str = ""
    last_speech_end: Optional[float] = None  # seconds offset in `audio` where speech ended
    speech_started: bool = False


def pcm16_to_float32(buf: bytes) -> np.ndarray:
    """Convert little-endian Int16 PCM bytes → float32 numpy array in [-1, 1]."""
    return np.frombuffer(buf, dtype="<i2").astype(np.float32) / 32768.0


def transcribe(audio: np.ndarray) -> str:
    """Run mlx-whisper on the given mono float32 audio. Returns flattened text.
    Errors are swallowed so a bad chunk doesn't kill the session."""
    if len(audio) < int(0.2 * SAMPLE_RATE):
        return ""
    try:
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=MODEL_REPO,
            language=LANGUAGE,
            word_timestamps=False,
            condition_on_previous_text=False,
            no_speech_threshold=0.55,
            verbose=False,
        )
        return (result.get("text") or "").strip()
    except Exception:
        log.exception("transcribe failed on %d-sample audio", len(audio))
        return ""


def vad_speech_segments(audio: np.ndarray, vad_model) -> list[dict]:
    """Return Silero VAD's view of speech regions in `audio`. Empty = silence."""
    if len(audio) < int(0.25 * SAMPLE_RATE):
        return []
    try:
        return get_speech_timestamps(
            audio,
            vad_model,
            sampling_rate=SAMPLE_RATE,
            min_silence_duration_ms=200,
            min_speech_duration_ms=int(MIN_SPEECH_MS),
            return_seconds=True,
        )
    except Exception:
        log.exception("VAD failed on %d-sample audio", len(audio))
        return []


async def emit(ws, text: str, is_final: bool):
    if not text:
        return
    msg = json.dumps({"type": "transcript", "text": text, "is_final": is_final})
    await ws.send(msg)
    log.info("→ %s: %r", "FIN" if is_final else "int", text)


async def handle(ws):
    log.info("client connected from %s", ws.remote_address)
    session = Session()
    vad_model = load_silero_vad()

    try:
        async for message in ws:
            now = time.monotonic()

            if isinstance(message, (bytes, bytearray)):
                chunk = pcm16_to_float32(bytes(message))
                if chunk.size == 0:
                    continue
                session.audio = np.concatenate([session.audio, chunk])

                # Cap the buffer so we don't run unbounded if VAD never commits.
                max_samples = int(MAX_BUFFER_SECS * SAMPLE_RATE)
                if len(session.audio) > max_samples:
                    drop = len(session.audio) - max_samples
                    session.audio = session.audio[drop:]
                    log.warning("buffer overflow, dropped %d samples", drop)

                # Check for end-of-utterance via VAD.
                segments = vad_speech_segments(session.audio, vad_model)
                if segments:
                    session.speech_started = True
                    last = segments[-1]
                    buffer_dur = len(session.audio) / SAMPLE_RATE
                    trailing_silence_s = buffer_dur - last["end"]
                    if trailing_silence_s * 1000 >= VAD_SILENCE_MS:
                        # We have a full utterance. Transcribe everything up to
                        # last["end"], emit as final, drop committed audio.
                        cut_sample = int(last["end"] * SAMPLE_RATE)
                        utterance = session.audio[:cut_sample]
                        text = await asyncio.get_event_loop().run_in_executor(
                            None, transcribe, utterance
                        )
                        await emit(ws, text, is_final=True)
                        session.audio = session.audio[cut_sample:]
                        session.last_interim_text = ""
                        session.last_interim_at = now
                        session.speech_started = False
                        continue

                # Periodic interim while speech is in progress.
                if session.speech_started and (
                    (now - session.last_interim_at) * 1000 >= INTERIM_INTERVAL_MS
                ):
                    audio_snapshot = session.audio.copy()
                    text = await asyncio.get_event_loop().run_in_executor(
                        None, transcribe, audio_snapshot
                    )
                    if text and text != session.last_interim_text:
                        await emit(ws, text, is_final=False)
                        session.last_interim_text = text
                    session.last_interim_at = now

            else:
                # Text frame — control message (ignore for now, future use).
                log.debug("text frame from client: %r", message)

    except websockets.exceptions.ConnectionClosed as e:
        log.info("client disconnected (%s)", e.code)
    except Exception:
        log.exception("handler crashed")
        raise


async def main():
    log.info("loading model: %s", MODEL_REPO)
    # Warm the model so the first transcript isn't penalized.
    _ = mlx_whisper.transcribe(
        np.zeros(SAMPLE_RATE, dtype=np.float32),
        path_or_hf_repo=MODEL_REPO,
        language=LANGUAGE,
        verbose=False,
    )
    log.info("model loaded and warmed")

    log.info("listening on ws://%s:%d/transcribe", BIND_HOST, BIND_PORT)
    async with websockets.serve(
        handle,
        BIND_HOST,
        BIND_PORT,
        max_size=10 * 1024 * 1024,
        # Disable keepalive ping — we're on localhost (no NAT timeouts) and
        # Mint.WebSocket on the Elixir side doesn't auto-respond to pings,
        # which caused the server to time us out at exactly 40s. The audio
        # stream itself is constant traffic that proves the conn is alive.
        ping_interval=None,
        ping_timeout=None,
    ):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("bye")
