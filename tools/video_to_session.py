#!/usr/bin/env python3
"""Turn a performance VIDEO into a replay session JSON — fully offline.

Pipeline:  video --(ffmpeg)--> 16k mono wav --(faster-whisper, local, word
timestamps)--> synthetic growing-fragment events --> session JSON

The sibling of song_to_session.py, for the video-in/video-out flow
(`mix sinestesia.video`): same output contract, but no cloud STT, no API key,
no Demucs — a phone video of one singer is already voice-forward, and this
tool exists to be runnable on a machine with no keys at all.

Usage:
    tools/.venv/bin/python tools/video_to_session.py clip.mp4
    ... clip.mp4 --name minha-take --out /tmp --model small --lang pt

Needs: ffmpeg on PATH; faster-whisper in the running python (see tools/.venv,
created with `uv venv --python 3.12 tools/.venv &&
uv pip install --python tools/.venv/bin/python faster-whisper`).
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from session_events import build_events


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s.lower())
    return re.sub(r"[\s_]+", "-", s).strip("-")


def extract_audio(video: Path, out_dir: Path) -> Path:
    """ffmpeg → mono 16 kHz wav (what Whisper wants; also small enough to keep)."""
    wav = out_dir / f"{slugify(video.stem)}.wav"
    print(f"[1/3] extracting audio → {wav}", flush=True)
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(video),
         "-vn", "-ac", "1", "-ar", "16000", str(wav)],
        check=True,
    )
    return wav


def transcribe(wav: Path, lang: str, model_size: str) -> list[dict]:
    """Local faster-whisper with word timestamps → [{"text","start","end"}]."""
    from faster_whisper import WhisperModel

    print(f"[2/3] transcribing locally (faster-whisper {model_size}, "
          f"lang={lang or 'auto'}) …", flush=True)
    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    segments, info = model.transcribe(
        str(wav),
        language=lang or None,
        word_timestamps=True,
        vad_filter=True,
    )

    words: list[dict] = []
    for seg in segments:
        for w in seg.words or []:
            text = w.word.strip()
            if text:
                words.append({"text": text, "start": w.start, "end": w.end})

    if not words:
        sys.exit("Whisper returned no words — silent audio? wrong language?")
    print(f"      {len(words)} words, {words[-1]['end']:.0f}s "
          f"(detected language: {info.language}, p={info.language_probability:.2f})")
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", help="path to the performance video (mp4/mov/…)")
    ap.add_argument("--name", help="session name (default: slug of the filename)")
    ap.add_argument("--style", help="visual style to bake into the session")
    ap.add_argument("--out", help="output dir (default: alongside the video)")
    # Auto-detect by default: unlike the live stage (Brazilian repertoire,
    # ELEVEN_LANG=pt), an uploaded clip can be in any language, and forcing
    # pt on an English take mangles the words badly enough to break song
    # identification downstream ("let me see what spring is like" came back
    # as "o que o spring é como um jupiter mar").
    ap.add_argument("--lang", default="", help="ISO language (default: auto-detect)")
    ap.add_argument("--model", default="small",
                    help="faster-whisper model size (tiny/base/small/medium)")
    # Mirror the live STT: the backend commits an utterance after
    # ELEVEN_VAD_SILENCE (default 0.6s) of silence, so the replay should too.
    ap.add_argument("--gap", type=float, default=0.6,
                    help="silence (s) that commits an utterance")
    args = ap.parse_args()

    video = Path(args.video).expanduser()
    if not video.exists():
        sys.exit(f"not found: {video}")

    name = args.name or slugify(video.stem)
    out_dir = Path(args.out) if args.out else video.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    wav = extract_audio(video, out_dir)
    words = transcribe(wav, args.lang, args.model)
    events = build_events(words, args.gap)

    session = {
        "name": name,
        # The extracted wav, not the video: everything downstream that touches
        # "audio" (the replay exporter) wants an audio file it can probe.
        "audio": str(wav.resolve()),
        "video": str(video.resolve()),
    }
    if args.style:
        session["style"] = args.style
    session["events"] = events

    out_path = out_dir / f"{name}.json"
    out_path.write_text(json.dumps(session, indent=2, ensure_ascii=False) + "\n")

    finals = sum(1 for e in events if e["final"])
    print(f"[3/3] wrote {out_path}")
    print(f"      {len(events)} events ({finals} finals), {events[-1]['at_ms'] // 1000}s")


if __name__ == "__main__":
    main()
