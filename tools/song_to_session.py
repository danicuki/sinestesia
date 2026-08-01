#!/usr/bin/env python3
"""Turn a finished song (mp3/wav/...) into a replay session JSON.

Pipeline:  audio --(Demucs)--> isolated vocals --(ElevenLabs Scribe)-->
word timestamps --> synthetic growing-fragment events --> tests/sessions/<name>.json

The output plugs straight into the replay harness:
    cd backend && mix sinestesia.replay ../tests/sessions/<name>.json

Why isolate vocals first: the STT (and the live f0/melody extraction) are far
more accurate on a clean vocal stem than on the full mix.

Usage:
    python3 tools/song_to_session.py "song.mp3"
    python3 tools/song_to_session.py "song.mp3" --name dinda --style "watercolor"
    python3 tools/song_to_session.py vocals.wav --skip-separation   # already a vocal stem

Needs: ELEVENLABS_API_KEY in the environment or backend/.env; `demucs`
installed (python3 -m demucs); the `requests` package.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "tests" / "sessions"
STT_URL = "https://api.elevenlabs.io/v1/speech-to-text"


def load_api_key() -> str:
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key
    # Fall back to a dotenv-style .env (root or backend/).
    for env in (ROOT / ".env", ROOT / "backend" / ".env"):
        if env.exists():
            for line in env.read_text().splitlines():
                line = line.strip()
                if line.startswith("ELEVENLABS_API_KEY=") and not line.startswith("#"):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("ELEVENLABS_API_KEY not set (env, .env, or backend/.env)")


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s.lower())
    return re.sub(r"[\s_]+", "-", s).strip("-")


def separate_vocals(audio: Path) -> Path:
    """Run Demucs two-stems and return the path to vocals.wav."""
    out = Path(tempfile.mkdtemp(prefix="s2s_demucs_"))
    print(f"[1/3] separating vocals with Demucs (→ {out}) …", flush=True)
    subprocess.run(
        [sys.executable, "-m", "demucs", "--two-stems=vocals",
         "-d", os.environ.get("DEMUCS_DEVICE", "mps"),
         "-o", str(out), str(audio)],
        check=True,
    )
    # Demucs writes <out>/<model>/<track-stem>/vocals.wav
    hits = list(out.glob("*/*/vocals.wav"))
    if not hits:
        sys.exit("Demucs produced no vocals.wav — check the run above")
    print(f"      vocals: {hits[0]}")
    return hits[0]


def transcribe(vocals: Path, lang: str, model: str, cache: Path, refetch: bool) -> list[dict]:
    """ElevenLabs Scribe batch STT → list of word dicts with start/end (seconds).
    Caches the word list next to the output so re-running to tune --gap costs
    nothing (delete the cache or pass --refetch to force a new transcription)."""
    if cache.exists() and not refetch:
        print(f"[2/3] using cached transcription ({cache.name}) — --refetch to redo")
        return json.loads(cache.read_text())
    print(f"[2/3] transcribing with ElevenLabs ({model}, lang={lang or 'auto'}) …", flush=True)
    data = {"model_id": model, "timestamps_granularity": "word"}
    if lang:
        data["language_code"] = lang
    with open(vocals, "rb") as fh:
        resp = requests.post(
            STT_URL,
            headers={"xi-api-key": load_api_key()},
            data=data,
            files={"file": (vocals.name, fh, "audio/wav")},
            timeout=300,
        )
    if resp.status_code != 200:
        sys.exit(f"ElevenLabs STT failed ({resp.status_code}): {resp.text[:400]}")
    words = [w for w in resp.json().get("words", []) if w.get("type") == "word"]
    if not words:
        sys.exit("STT returned no words (silent stem? wrong language?)")
    cache.write_text(json.dumps(words, ensure_ascii=False))
    print(f"      {len(words)} words, {words[-1]['end']:.0f}s (cached → {cache.name})")
    return words


from session_events import build_events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", help="path to the song (mp3/wav/m4a/…) or a vocal stem")
    ap.add_argument("--name", help="session name (default: slug of the filename)")
    ap.add_argument("--style", help="visual style to bake into the session")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="output dir")
    ap.add_argument("--skip-separation", action="store_true",
                    help="input is already a clean vocal track; skip Demucs")
    ap.add_argument("--lang", default="pt", help="ISO language ('' = auto-detect)")
    ap.add_argument("--model", default="scribe_v1", help="ElevenLabs STT model")
    ap.add_argument("--refetch", action="store_true",
                    help="re-transcribe even if a cached word list exists")
    # Mirror the live STT: the backend commits an utterance after
    # ELEVEN_VAD_SILENCE (default 0.6s) of silence, so the replay should too.
    ap.add_argument("--gap", type=float, default=0.6,
                    help="silence (s) that commits an utterance (matches ELEVEN_VAD_SILENCE)")
    args = ap.parse_args()

    audio = Path(args.audio).expanduser()
    if not audio.exists():
        sys.exit(f"not found: {audio}")

    name = args.name or slugify(audio.stem)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    cache = out_dir / f".{name}.words.json"

    vocals = audio if (args.skip_separation or cache.exists() and not args.refetch) \
        else separate_vocals(audio)
    words = transcribe(vocals, args.lang, args.model, cache, args.refetch)
    events = build_events(words, args.gap)

    session = {
        "name": name,
        "audio": str(audio.resolve())
    }
    if args.style:
        session["style"] = args.style
    session["events"] = events

    out_path = out_dir / f"{name}.json"
    out_path.write_text(json.dumps(session, indent=2, ensure_ascii=False) + "\n")

    finals = sum(1 for e in events if e["final"])
    print(f"[3/3] wrote {out_path}")
    print(f"      {len(events)} events ({finals} finals), {events[-1]['at_ms'] // 1000}s")
    print(f"      replay: cd backend && mix sinestesia.replay ../{out_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
