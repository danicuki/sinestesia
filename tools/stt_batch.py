"""Batch speech-to-text with word timings — the two backends, one contract.

Both return the same shape: `[{"text", "start", "end"}, ...]` in seconds,
which `session_events.build_events` turns into a replay session.

Why two: the LIVE pipeline's `STT_PROVIDER` selects a REALTIME streaming
transcriber (a WebSocket fed PCM as it's sung). Turning a finished recording
into a session is a different job — it wants the whole file at once, with
per-word timestamps — so it needs its own backend choice. `pick_backend`
honours `STT_PROVIDER` anyway, because an operator who configured
ElevenLabs for the stage reasonably expects the same engine (and the same
account) to be used here, and Scribe's batch endpoint is more accurate than
a local whisper-small.

- `elevenlabs` — Scribe batch endpoint. Needs `ELEVENLABS_API_KEY` and
  `requests`. Better quality, costs a little, needs network.
- `whisper` — faster-whisper, local. Needs no key and no network; the only
  option on a machine with no credentials at all.
"""

import json
import os
import sys
from pathlib import Path

STT_URL = "https://api.elevenlabs.io/v1/speech-to-text"


def find_api_key(root: Path) -> str | None:
    """ELEVENLABS_API_KEY from the environment, or a dotenv-style .env."""
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key

    for env in (root / ".env", root / "backend" / ".env"):
        if env.exists():
            for line in env.read_text().splitlines():
                line = line.strip()
                if line.startswith("ELEVENLABS_API_KEY=") and not line.startswith("#"):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def pick_backend(explicit: str, root: Path) -> str:
    """Resolve which backend to use: explicit flag > STT_PROVIDER > what's available.

    `STT_PROVIDER=elevenlabs` with a key present picks Scribe; anything else
    (deepgram, local_whisper, unset, or elevenlabs with no key) falls to the
    local model, which is always available and never surprises anyone with a
    bill or a network dependency.
    """
    if explicit:
        return explicit

    provider = os.environ.get("STT_PROVIDER", "").strip().lower()
    if provider == "elevenlabs" and find_api_key(root):
        return "elevenlabs"

    return "whisper"


def transcribe_elevenlabs(
    audio: Path, lang: str, root: Path, model: str = "scribe_v1"
) -> list[dict]:
    import requests

    key = find_api_key(root)
    if not key:
        sys.exit("ELEVENLABS_API_KEY not set (env, .env, or backend/.env)")

    print(f"[2/3] transcribing with ElevenLabs ({model}, lang={lang or 'auto'}) …", flush=True)
    data = {"model_id": model, "timestamps_granularity": "word"}
    if lang:
        data["language_code"] = lang

    with open(audio, "rb") as fh:
        resp = requests.post(
            STT_URL,
            headers={"xi-api-key": key},
            data=data,
            files={"file": (audio.name, fh, "audio/wav")},
            timeout=300,
        )

    if resp.status_code != 200:
        sys.exit(f"ElevenLabs STT failed ({resp.status_code}): {resp.text[:400]}")

    words = [
        {"text": w["text"], "start": w["start"], "end": w["end"]}
        for w in resp.json().get("words", [])
        if w.get("type") == "word"
    ]
    if not words:
        sys.exit("STT returned no words (silent audio? wrong language?)")

    print(f"      {len(words)} words, {words[-1]['end']:.0f}s")
    return words


def transcribe_whisper(audio: Path, lang: str, model_size: str = "small") -> list[dict]:
    from faster_whisper import WhisperModel

    print(
        f"[2/3] transcribing locally (faster-whisper {model_size}, "
        f"lang={lang or 'auto'}) …",
        flush=True,
    )
    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    segments, info = model.transcribe(
        str(audio), language=lang or None, word_timestamps=True, vad_filter=True
    )

    words: list[dict] = []
    for seg in segments:
        for w in seg.words or []:
            text = w.word.strip()
            if text:
                words.append({"text": text, "start": w.start, "end": w.end})

    if not words:
        sys.exit("Whisper returned no words — silent audio? wrong language?")

    print(
        f"      {len(words)} words, {words[-1]['end']:.0f}s "
        f"(detected language: {info.language}, p={info.language_probability:.2f})"
    )
    return words


def transcribe(audio: Path, backend: str, lang: str, root: Path, model_size: str) -> list[dict]:
    if backend == "elevenlabs":
        return transcribe_elevenlabs(audio, lang, root)
    return transcribe_whisper(audio, lang, model_size)
