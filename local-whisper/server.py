"""
Local STT WebSocket sidecar for Sinestesia.

Drop-in replacement for ElevenLabs / Deepgram streaming STT. Listens on
ws://localhost:8002/transcribe, expects 16kHz Int16 LE PCM as binary frames,
emits JSON transcripts as text frames matching the protocol the backend
already understands:

    {"type": "transcript", "text": "...", "is_final": false}
    {"type": "transcript", "text": "...", "is_final": true}

Backends (WHISPER_BACKEND):
  - mlx                  mlx-whisper, Metal-accelerated Whisper on Apple Silicon (M1+)
  - torch                openai-whisper, PyTorch backend for ROCm/CUDA GPUs
  - faster-whisper       CTranslate2, CPU/CUDA fallback on Linux/Intel
  - nemotron-transcribe  NVIDIA Nemotron 3.5 Transcribe 30B-A4B through mlx-audio —
                         an OFFLINE speech LLM; the phrase buffering below is what
                         makes it usable live (README.md, "NVIDIA Nemotron")
  - nemotron-asr         NVIDIA nemotron-3.5-asr-streaming-0.6b through mlx-audio —
                         a cache-aware streaming RNNT, decoded as the audio arrives
  - silero-vad           Voice activity detection for phrase boundaries, every backend

Streaming pattern for the OFFLINE models (Whisper, Nemotron Transcribe), similar
to ElevenLabs Scribe v2 with VAD commit:
  - Buffer incoming PCM into a numpy float32 array
  - Every INTERIM_INTERVAL_MS, transcribe the un-committed buffer and emit
    as is_final=false (rolling preview)
  - Run Silero VAD on the buffer continuously; when silence > VAD_SILENCE_MS
    is detected after speech, transcribe the segment, emit as is_final=true,
    drop the committed audio from the buffer

The STREAMING model (nemotron-asr) decodes while the phrase is still being sung
instead — one RNNT session per phrase, partials as the words come out — and the
same VAD decides where the phrase ends and its final is emitted (handle_stream).
"""

import asyncio
import json
import logging
import os
import re
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import websockets
try:
    import torch
except Exception:
    torch = None

torch_whisper = None
WhisperModel = None
try:
    import mlx_whisper
except Exception:
    mlx_whisper = None

try:
    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio
except Exception:
    WhisperModel = None

try:
    import whisper as torch_whisper
except Exception:
    torch_whisper = None

# mlx-audio carries the NVIDIA Nemotron ports (Apple Silicon only). Optional:
# the Whisper backends do not need it.
try:
    from mlx_audio.stt import load as mlx_audio_load
except Exception:
    mlx_audio_load = None

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
NEMOTRON_TRANSCRIBE = "nemotron-transcribe"
NEMOTRON_ASR = "nemotron-asr"
DEFAULT_BACKEND = "mlx" if mlx_whisper is not None else "torch" if torch is not None else "faster-whisper"
WHISPER_BACKEND = os.environ.get("WHISPER_BACKEND", DEFAULT_BACKEND)
# Default to small, not medium: when SDXL Turbo + Gemma 12B are also sharing
# the Apple GPU, medium's ~400ms-per-interim load starves the other two and
# Director latency balloons from ~1.5s to ~6s. small (~150ms) leaves headroom.
# If you have a dedicated box for STT (no SDXL/Gemma), bump back to medium.
DEFAULT_MODELS = {
    "mlx": "mlx-community/whisper-small-mlx",
    # NVIDIA's official checkpoint: 67.5 GB of bf16 on disk, ~66 GB of memory
    # on MLX. A 48 GB Mac runs the 4-bit conversion instead (README.md).
    NEMOTRON_TRANSCRIBE: "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B",
    NEMOTRON_ASR: "mlx-community/nemotron-3.5-asr-streaming-0.6b",
}
MODEL_REPO = os.environ.get("WHISPER_MODEL", DEFAULT_MODELS.get(WHISPER_BACKEND, "small"))
FASTER_WHISPER_DEVICE = os.environ.get("FASTER_WHISPER_DEVICE", "cpu")
FASTER_WHISPER_COMPUTE_TYPE = os.environ.get("FASTER_WHISPER_COMPUTE_TYPE", "int8")
faster_model = None
TORCH_WHISPER_DEVICE = os.environ.get(
    "TORCH_WHISPER_DEVICE",
    "cuda" if torch is not None and torch.cuda.is_available() else "cpu",
)
torch_model = None
# Suggested choices (size / latency tradeoff on M4 Max):
#   mlx-community/whisper-tiny-mlx-q4     ~40MB  ~50ms/segment, weakest
#   mlx-community/whisper-base-mlx-q4     ~80MB  ~80ms/segment
#   mlx-community/whisper-small-mlx-q4    ~250MB ~150ms/segment, sweet spot
#   mlx-community/whisper-medium-mlx-q4   ~770MB ~400ms/segment, very strong
#   mlx-community/whisper-large-v3-mlx-q4 ~1.5GB ~1s/segment, slowest

# Auto-detect by default (like ElevenLabs did) so English / Portuguese / etc.
# all work. Set WHISPER_LANGUAGE=pt (or en, es, ...) to FORCE one language and
# skip detection entirely — useful if you KNOW the set list and want to avoid
# any chance of misdetection.
FORCE_LANGUAGE = os.environ.get("WHISPER_LANGUAGE") or None
LANGUAGE_LOCK_MIN_PROB = float(os.environ.get("WHISPER_LANGUAGE_LOCK_MIN_PROB", "0.55"))
LOW_CONFIDENCE_FALLBACK = os.environ.get("WHISPER_LANGUAGE_FALLBACK") or None

# The languages the SET is sung in, e.g. "pt,en,it,de". Whisper's language head
# scores all 99 languages, and on one or two seconds of SUNG audio the winner
# is often absurd: Hindi at 0.59 on an Italian verse locked a whole clip into
# Devanagari (STT bench, 2026-10-20). A show knows which languages it will
# hear; the argmax is taken within that set and the probability renormalized
# over it, so LANGUAGE_LOCK_MIN_PROB means "how sure, among OUR languages".
# Empty = any language (the library default). Ignored when WHISPER_LANGUAGE
# pins one. Nemotron Transcribe has no language head: the set becomes the
# labels of its language-identification prompt (nemotron_detect_language).
CANDIDATE_LANGUAGES = [l.strip() for l in os.environ.get("WHISPER_LANGUAGES", "").split(",") if l.strip()]

# Only a FINAL with at least this many words may lock the session's language.
# Interims never lock: the first seconds of a song are vocalizations and
# breath ("oh, oh, oh"), on which Whisper guesses English at 0.4–0.5 for any
# language — a renormalized 0.97 within the candidate set, and a whole song
# in the wrong language. A full phrase with real words is the regime where
# detection is reliable; three "oh"s are not a phrase.
MIN_LOCK_WORDS = int(os.environ.get("WHISPER_MIN_LOCK_WORDS", "4"))

# Whisper's language detection is unreliable on <1s of noisy audio (that's what
# produced the Cyrillic "Думафоля" garbage). We only auto-detect once the
# buffer has at least this much audio; until then we hold off on interims.
MIN_DETECT_SECS = float(os.environ.get("MIN_DETECT_SECS", "1.5"))

# 1200ms (was 600): each interim is a full re-transcription of the buffer, so
# halving the cadence halves Whisper's steady-state GPU load. The Director can
# only fire every 5s anyway, so more frequent interims buy nothing here.
INTERIM_INTERVAL_MS = int(os.environ.get("INTERIM_INTERVAL_MS", "1200"))
VAD_SILENCE_MS = int(os.environ.get("VAD_SILENCE_MS", "650"))
MIN_SPEECH_MS = int(os.environ.get("MIN_SPEECH_MS", "300"))
# A phrase this long without a breath is committed as-is (see handle): the
# alternative, dropping the oldest audio, silently loses sung words.
MAX_BUFFER_SECS = float(os.environ.get("MAX_BUFFER_SECS", "20"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8002"))

# Realtime decode budget. Whisper's library defaults are tuned for offline
# accuracy: a beam of 5, and when a pass looks degenerate (compression ratio
# above 2.4) it RE-DECODES at up to five higher temperatures. Sung vowels
# ("oh, oh, oh") trigger exactly that loop: measured on Atemlos durch die Nacht
# with `small` on CPU, each 4s buffer took 13s to decode (base: 1.3s) and the
# stage saw nothing for 40s. Greedy, one pass, capped tokens — same audio in
# about a second. The batch endpoint (/transcribe_file) keeps the offline
# defaults: there, quality is the point and nobody is waiting on stage.
WHISPER_BEAM_SIZE = int(os.environ.get("WHISPER_BEAM_SIZE", "1"))
WHISPER_TEMPERATURE_FALLBACK = os.environ.get("WHISPER_TEMPERATURE_FALLBACK", "0") in ("1", "true", "on")
# ~2 tokens per sung word; 20s of singing is well under 160 tokens, a
# repetition loop is not. Nemotron Transcribe gets the same cap: its report
# lists "generation loops" among the known failure modes.
WHISPER_MAX_NEW_TOKENS = int(os.environ.get("WHISPER_MAX_NEW_TOKENS", "160"))
TEMPERATURES = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] if WHISPER_TEMPERATURE_FALLBACK else [0.0]

# nemotron-asr: how far the streaming encoder looks ahead before it commits to
# a frame — one of the look-aheads the model was trained with. Lower = words
# appear sooner; NVIDIA's FLEURS numbers give up about one WER point from
# 1120 ms to 80 ms (Portuguese 5.5 → 6.3). A phrase's FINAL does not depend
# on it: the end of the phrase is flushed through the encoder (see flush).
NEMOTRON_LOOKAHEAD_MS = int(os.environ.get("NEMOTRON_LOOKAHEAD_MS", "560"))
LOOKAHEAD_FRAMES = {80: 0, 160: 1, 320: 3, 560: 6, 1120: 13}  # ms → right-context frames of 80 ms
# The streaming decoder spells a phrase word by word; its partials are
# coalesced to at most one every so many ms so the socket is not flooded.
STREAM_EMIT_MS = 150

# One decode at a time, in submission order. The receive loop never awaits a
# decode (see handle): audio keeps draining and VAD keeps running while the
# model works, so a slow pass costs latency on ONE transcript, not a stall of
# the whole stream.
DECODER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="whisper")

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
    # Language auto-detected from the audio so far. Updated on each final
    # (a full utterance, where detection is reliable). Interims reuse it so
    # they don't flicker. None until the first reliable detection.
    detected_language: Optional[str] = None
    # The interim decode in flight, if any — at most one; a new interim is
    # not scheduled while the previous one is still running.
    interim_task: Optional[asyncio.Task] = None
    # Finals in flight. asyncio keeps only weak references to tasks, so one
    # created and forgotten can be collected mid-decode; this set holds them
    # until they finish.
    finals: set = field(default_factory=set)
    # Bumped on every reset: a decode that started before the song change
    # describes audio the operator just threw away, and must not be emitted.
    generation: int = 0


def pcm16_to_float32(buf: bytes) -> np.ndarray:
    """Convert little-endian Int16 PCM bytes → float32 numpy array in [-1, 1]."""
    return np.frombuffer(buf, dtype="<i2").astype(np.float32) / 32768.0


def get_faster_model():
    global faster_model
    if WhisperModel is None:
        raise RuntimeError("faster-whisper is not installed")
    if faster_model is None:
        log.info(
            "loading faster-whisper model: %s on %s (%s)",
            MODEL_REPO,
            FASTER_WHISPER_DEVICE,
            FASTER_WHISPER_COMPUTE_TYPE,
        )
        faster_model = WhisperModel(
            MODEL_REPO,
            device=FASTER_WHISPER_DEVICE,
            compute_type=FASTER_WHISPER_COMPUTE_TYPE,
        )
    return faster_model


def get_torch_model():
    global torch_model
    if torch_whisper is None:
        raise RuntimeError("openai-whisper is not installed")
    if torch_model is None:
        log.info("loading torch Whisper model: %s on %s", MODEL_REPO, TORCH_WHISPER_DEVICE)
        torch_model = torch_whisper.load_model(MODEL_REPO, device=TORCH_WHISPER_DEVICE)
    return torch_model


def _restrict(probs: dict) -> tuple[Optional[str], Optional[float]]:
    """Best language within CANDIDATE_LANGUAGES, probability renormalized over
    the set. (None, None) when none of the candidates scored at all."""
    cands = {l: p for l, p in probs.items() if l in CANDIDATE_LANGUAGES}
    total = sum(cands.values())
    if not cands or total <= 0:
        return None, None
    lang = max(cands, key=cands.get)
    return lang, cands[lang] / total


_mlx_model = None


def detect_candidate_language(audio: np.ndarray) -> tuple[Optional[str], Optional[float]]:
    """Language detection restricted to CANDIDATE_LANGUAGES, on whichever
    backend is loaded. Only the first 30s window is scored (that is all
    Whisper's language head looks at anyway)."""
    global _mlx_model
    try:
        if WHISPER_BACKEND == "faster-whisper":
            _lang, _prob, all_probs = get_faster_model().detect_language(audio)
            return _restrict(dict(all_probs))

        if WHISPER_BACKEND == "torch":
            model = get_torch_model()
            mel = torch_whisper.log_mel_spectrogram(
                torch_whisper.pad_or_trim(audio.astype(np.float32)), n_mels=model.dims.n_mels
            ).to(model.device)
            _tokens, probs = model.detect_language(mel)
            return _restrict(probs if isinstance(probs, dict) else probs[0])

        # mlx: mirrors openai-whisper's API (frames-major mel).
        from mlx_whisper import audio as mlx_audio, decoding as mlx_decoding, load_models as mlx_load

        if _mlx_model is None:
            _mlx_model = mlx_load.load_model(MODEL_REPO)
        mel = mlx_audio.log_mel_spectrogram(audio, n_mels=_mlx_model.dims.n_mels)
        mel = mlx_audio.pad_or_trim(mel, mlx_audio.N_FRAMES, axis=-2)
        _tokens, probs = mlx_decoding.detect_language(_mlx_model, mel)
        return _restrict(probs if isinstance(probs, dict) else probs[0])
    except Exception:
        log.exception("candidate language detection failed — falling back to unrestricted detection")
        return None, None


# ── NVIDIA Nemotron through mlx-audio ────────────────────────────────────────
#
# Two very different models share the loader:
#   nemotron-transcribe  Nemotron 3.5 Transcribe 30B-A4B (34B total, ~4.3B
#                        active): a speech encoder feeding a Mamba/MoE LLM. An
#                        offline model — NVIDIA's report: "the released model
#                        ... does not provide native streaming transcription".
#                        It is driven exactly like Whisper here: the VAD cuts
#                        phrases, every interim is a full decode of the buffer.
#   nemotron-asr         nemotron-3.5-asr-streaming-0.6b: a cache-aware
#                        FastConformer-RNNT built for live audio, 40 locales,
#                        language auto-detected. Fed as it arrives — see
#                        handle_stream below.

_nemotron_model = None

# Nemotron Transcribe is prompted in words; nemotron-asr takes a locale key.
LANGUAGE_NAMES = {
    "pt": "Portuguese", "en": "English", "it": "Italian", "de": "German", "es": "Spanish",
    "fr": "French", "nl": "Dutch", "pl": "Polish", "ru": "Russian", "uk": "Ukrainian",
    "tr": "Turkish", "ar": "Arabic", "hi": "Hindi", "ja": "Japanese", "ko": "Korean",
    "zh": "Chinese", "vi": "Vietnamese", "sv": "Swedish", "da": "Danish", "nb": "Norwegian",
    "fi": "Finnish", "cs": "Czech", "hu": "Hungarian", "ro": "Romanian", "el": "Greek",
    "bg": "Bulgarian", "hr": "Croatian", "sk": "Slovak", "sl": "Slovenian", "lt": "Lithuanian",
    "lv": "Latvian", "et": "Estonian", "he": "Hebrew", "th": "Thai", "mt": "Maltese",
}
LOCALES = {
    "pt": "pt-BR", "en": "en-US", "it": "it-IT", "de": "de-DE", "es": "es-ES", "fr": "fr-FR",
    "nl": "nl-NL", "pl": "pl-PL", "ru": "ru-RU", "uk": "uk-UA", "tr": "tr-TR", "ar": "ar-AR",
    "hi": "hi-IN", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN", "vi": "vi-VN", "sv": "sv-SE",
    "da": "da-DK", "nb": "nb-NO", "fi": "fi-FI", "cs": "cs-CZ", "hu": "hu-HU", "ro": "ro-RO",
    "el": "el-GR", "bg": "bg-BG", "hr": "hr-HR", "sk": "sk-SK", "sl": "sl-SI", "lt": "lt-LT",
    "lv": "lv-LV", "et": "et-EE", "he": "he-IL", "th": "th-TH", "mt": "mt-MT",
}
# Markup the models emit and the stage must not read: <spk:0>, <ev:laugh>,
# <sty:...>, <|im_end|>, and the <pt-BR> language tag of nemotron-asr's auto mode.
TAG_RE = re.compile(r"<[^<>\n]{1,40}>")
LANG_TAG_RE = re.compile(r"<([a-z]{2,3}-[A-Z]{2})>")


def language_name(code: str) -> str:
    return LANGUAGE_NAMES.get(code.lower(), code)


def locale_for(code: str) -> str:
    """'pt' → 'pt-BR'; a full locale ('pt-PT') is passed through."""
    return code if "-" in code else LOCALES.get(code.lower(), code)


def get_nemotron_model():
    """Load the configured Nemotron checkpoint once. `strict`: a checkpoint
    whose weights do not all land in the model would transcribe garbage with
    no error — better to die here, with the missing keys in the log."""
    global _nemotron_model
    if mlx_audio_load is None:
        raise RuntimeError(
            f"WHISPER_BACKEND={WHISPER_BACKEND} needs mlx-audio in this venv (Apple Silicon) — "
            "README.md, section 'NVIDIA Nemotron'"
        )
    if _nemotron_model is None:
        t0 = time.time()
        log.info("loading %s through mlx-audio: %s", WHISPER_BACKEND, MODEL_REPO)
        _nemotron_model = mlx_audio_load(os.path.expanduser(MODEL_REPO), strict=True)
        log.info("model loaded in %.0fs", time.time() - t0)
    return _nemotron_model


def nemotron_prompt(language: Optional[str]) -> str:
    """The verbatim-transcription instruction from NVIDIA's model card, with the
    language named once the session has locked one."""
    spoken = language_name(language) if language else "as spoken"
    return (
        f"Audio transcription. Language: {spoken}. Wording: verbatim, including fillers "
        "and repetitions. Formatting: punctuation and capitalization. Output: transcript only."
    )


def clean_markup(text: str) -> str:
    return re.sub(r"\s{2,}", " ", TAG_RE.sub("", text)).strip()


def nemotron_transcribe(audio: np.ndarray, language: Optional[str]) -> str:
    out = get_nemotron_model().generate(
        audio.astype(np.float32),
        task="asr",
        prompt=nemotron_prompt(language),
        max_tokens=WHISPER_MAX_NEW_TOKENS,
        temperature=0.0,
    )
    return clean_markup(out.text or "")


def nemotron_detect_language(audio: np.ndarray) -> Optional[str]:
    """Nemotron Transcribe has no language head, so the model is asked — with
    the answer restricted to the set the show is sung in, as WHISPER_LANGUAGES
    does for Whisper. The language-identification prompt is the model card's.
    One short extra decode per final, until the session locks a language."""
    if not CANDIDATE_LANGUAGES:
        return None
    labels = ", ".join(language_name(c) for c in CANDIDATE_LANGUAGES)
    out = get_nemotron_model().generate(
        audio.astype(np.float32),
        task="asr",
        prompt=(
            "Identify the spoken language. Respond with exactly one label from "
            f"{labels} and nothing else."
        ),
        max_tokens=8,
        temperature=0.0,
    )
    answer = clean_markup(out.text or "").lower()
    for code in CANDIDATE_LANGUAGES:
        if language_name(code).lower() in answer or answer.strip(" .") == code.lower():
            return code
    log.info("language id answer %r matches none of %s", answer, CANDIDATE_LANGUAGES)
    return None


def transcribe(audio: np.ndarray, language: Optional[str], detect: bool = False) -> tuple[str, Optional[str], Optional[float]]:
    """Run the offline model on the given mono float32 audio.
    Returns (text, detected_language, probability). `language=None` triggers
    auto-detect (within CANDIDATE_LANGUAGES when set); pass an explicit code
    to skip detection. `detect` is the final's flag: the Whisper backends
    detect on every decode regardless, Nemotron Transcribe only when asked,
    since for it detection is a second decode. Errors are swallowed so a bad
    chunk doesn't kill the session."""
    if len(audio) < int(0.2 * SAMPLE_RATE):
        return "", None, None
    detected_prob = None

    if WHISPER_BACKEND == NEMOTRON_TRANSCRIBE:
        try:
            text = nemotron_transcribe(audio, language)
            detected = language
            if language is None and detect and len(text.split()) >= MIN_LOCK_WORDS:
                detected = nemotron_detect_language(audio)
            # No probability: an answer from the set locks (maybe_learn_language).
            return text, detected, None
        except Exception:
            log.exception("nemotron transcribe failed on %d-sample audio", len(audio))
            return "", None, None

    if language is None and CANDIDATE_LANGUAGES:
        language, detected_prob = detect_candidate_language(audio)
        if language is not None:
            text, _lang, _prob = transcribe(audio, language)
            return text, language, detected_prob
    try:
        if WHISPER_BACKEND == "mlx":
            # mlx-whisper decodes greedily only (no beam search implemented);
            # the temperature list and the token cap are what apply here.
            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=MODEL_REPO,
                language=language,
                word_timestamps=False,
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                temperature=tuple(TEMPERATURES),
                sample_len=WHISPER_MAX_NEW_TOKENS,
                verbose=False,
            )
            return (result.get("text") or "").strip(), result.get("language"), None

        if WHISPER_BACKEND == "torch":
            result = get_torch_model().transcribe(
                audio.astype(np.float32),
                language=language,
                fp16=TORCH_WHISPER_DEVICE == "cuda",
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                word_timestamps=False,
                temperature=tuple(TEMPERATURES),
                # beam_size=None is greedy in openai-whisper; a 1-wide beam
                # would run the (slower) beam decoder for the same result.
                beam_size=WHISPER_BEAM_SIZE if WHISPER_BEAM_SIZE > 1 else None,
                sample_len=WHISPER_MAX_NEW_TOKENS,
                verbose=False,
            )
            return (result.get("text") or "").strip(), result.get("language"), None

        segments, info = get_faster_model().transcribe(
            audio,
            language=language,
            vad_filter=False,
            condition_on_previous_text=False,
            no_speech_threshold=0.55,
            word_timestamps=False,
            beam_size=WHISPER_BEAM_SIZE,
            temperature=TEMPERATURES,
            max_new_tokens=WHISPER_MAX_NEW_TOKENS,
            language_detection_threshold=LANGUAGE_LOCK_MIN_PROB,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
        detected = getattr(info, "language", None)
        probability = getattr(info, "language_probability", None)

        if (
            language is None
            and LOW_CONFIDENCE_FALLBACK
            and detected
            and probability is not None
            and probability < LANGUAGE_LOCK_MIN_PROB
        ):
            log.info(
                "language %s confidence %.2f below %.2f; retrying as %s",
                detected,
                probability,
                LANGUAGE_LOCK_MIN_PROB,
                LOW_CONFIDENCE_FALLBACK,
            )
            segments, info = get_faster_model().transcribe(
                audio,
                language=LOW_CONFIDENCE_FALLBACK,
                vad_filter=False,
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                word_timestamps=False,
                beam_size=WHISPER_BEAM_SIZE,
                temperature=TEMPERATURES,
                max_new_tokens=WHISPER_MAX_NEW_TOKENS,
            )
            text = " ".join(segment.text.strip() for segment in segments).strip()
            return text, LOW_CONFIDENCE_FALLBACK, 1.0

        return text, detected, probability
    except Exception:
        log.exception("transcribe failed on %d-sample audio", len(audio))
        return "", None, None


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


def is_hallucinated(text: str) -> bool:
    """Whisper degenerates into repeated tokens on silence/noise (e.g. the
    classic 'E E E E E ...' or 'Thank you. Thank you.'). Drop those so they
    don't poison the Director's bootstrap with garbage."""
    words = text.split()
    if len(words) < 6:
        return False
    unique = set(w.lower() for w in words)
    # If 6+ words collapse to 1-2 distinct tokens, it's a repetition loop.
    return len(unique) <= 2


async def emit(ws, text: str, is_final: bool):
    if not text:
        return
    if is_hallucinated(text):
        log.info("⊘ dropped hallucination: %r", text[:60])
        return
    msg = json.dumps({"type": "transcript", "text": text, "is_final": is_final})
    await ws.send(msg)
    log.info("→ %s: %r", "FIN" if is_final else "int", text)


def resolve_language(session: Session) -> Optional[str]:
    """Which language code to feed mlx-whisper. FORCE_LANGUAGE wins; otherwise
    use what we've detected so far (None = let Whisper auto-detect)."""
    if FORCE_LANGUAGE:
        return FORCE_LANGUAGE
    return session.detected_language


def maybe_learn_language(session: Session, detected: Optional[str], probability: Optional[float]):
    """Cache the detected language the first time we get one (and not forcing)."""
    if FORCE_LANGUAGE or not detected:
        return
    if probability is not None and probability < LANGUAGE_LOCK_MIN_PROB:
        log.info(
            "language candidate %s ignored at confidence %.2f (< %.2f)",
            detected,
            probability,
            LANGUAGE_LOCK_MIN_PROB,
        )
        return
    if session.detected_language != detected:
        if probability is None:
            log.info("language detected: %s", detected)
        else:
            log.info("language detected: %s (confidence %.2f)", detected, probability)
        session.detected_language = detected


async def decode(audio: np.ndarray, language: Optional[str], detect: bool = False):
    """transcribe() on the single decode worker, without blocking the loop."""
    return await asyncio.get_event_loop().run_in_executor(DECODER, transcribe, audio, language, detect)


async def finalize(ws, session: Session, utterance: np.ndarray, lang: Optional[str], generation: int):
    """Decode a committed utterance and emit it as final (unless the song
    changed meanwhile). Finals are full utterances, so auto-detect is
    reliable here and the result locks the session's language."""
    text, detected, probability = await decode(utterance, lang, detect=True)
    if session.generation != generation:
        return
    if len(text.split()) >= MIN_LOCK_WORDS:
        maybe_learn_language(session, detected, probability)
    elif detected and session.detected_language is None:
        log.info("language %s not locked: only %d word(s) in this phrase", detected, len(text.split()))
    await emit(ws, text, is_final=True)


async def interim(ws, session: Session, snapshot: np.ndarray, lang: Optional[str], generation: int):
    """Decode the uncommitted buffer and emit it as a rolling preview. Detects
    the language for its own decode when none is locked yet, but never locks
    it — see MIN_LOCK_WORDS."""
    text, detected, probability = await decode(snapshot, lang)
    if session.generation != generation:
        return
    if text and text != session.last_interim_text:
        await emit(ws, text, is_final=False)
        session.last_interim_text = text


def commit(ws, session: Session, cut_sample: int, now: float, why: str) -> None:
    """Close the utterance at `cut_sample`: hand it to the decoder and start
    the next one from the remainder. Runs in the receive loop, returns at
    once — the decode happens on the worker."""
    utterance = session.audio[:cut_sample].copy()
    session.audio = session.audio[cut_sample:]
    session.last_interim_text = ""
    session.last_interim_at = now
    session.speech_started = False
    # An interim still in flight describes the audio just committed — its
    # preview would arrive AFTER the final it previews. Drop it.
    if session.interim_task and not session.interim_task.done():
        session.interim_task.cancel()
    if why:
        log.info("committing %.1fs: %s", len(utterance) / SAMPLE_RATE, why)
    task = asyncio.create_task(
        finalize(ws, session, utterance, resolve_language(session), session.generation)
    )
    session.finals.add(task)
    task.add_done_callback(session.finals.discard)


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

                # Check for end-of-utterance via VAD.
                segments = vad_speech_segments(session.audio, vad_model)
                buffer_dur = len(session.audio) / SAMPLE_RATE
                if segments:
                    session.speech_started = True
                    last = segments[-1]
                    trailing_silence_s = buffer_dur - last["end"]
                    if trailing_silence_s * 1000 >= VAD_SILENCE_MS:
                        # A full utterance: everything up to where speech ended.
                        commit(ws, session, int(last["end"] * SAMPLE_RATE), now, "")
                        continue

                # No breath long enough for MAX_BUFFER_SECS (a gapless chorus,
                # a held note into the next line): commit what we have rather
                # than drop the oldest audio, which loses sung words silently.
                if buffer_dur >= MAX_BUFFER_SECS:
                    if session.speech_started:
                        commit(ws, session, len(session.audio), now, f"no pause for {MAX_BUFFER_SECS:.0f}s")
                    else:
                        session.audio = session.audio[-int(2 * SAMPLE_RATE):]  # silence: keep a tail
                    continue

                # Periodic interim while speech is in progress — at most one
                # decode in flight; if the previous preview is still running,
                # this tick is skipped rather than queued behind it.
                if session.speech_started and (
                    (now - session.last_interim_at) * 1000 >= INTERIM_INTERVAL_MS
                ) and (session.interim_task is None or session.interim_task.done()):
                    lang = resolve_language(session)

                    # Don't auto-detect on a short buffer — that's what produced
                    # the Cyrillic garbage. Wait until we have enough audio (or
                    # until a final has already locked in the language).
                    if lang is None and buffer_dur < MIN_DETECT_SECS:
                        session.last_interim_at = now
                    else:
                        session.last_interim_at = now
                        session.interim_task = asyncio.create_task(
                            interim(ws, session, session.audio.copy(), lang, session.generation)
                        )

            else:
                # Text frame — control message. The backend sends {"type":"reset"}
                # when the operator starts a new song, so we drop the buffered
                # audio and re-detect the language for the new performance.
                try:
                    ctrl = json.loads(message)
                except (ValueError, TypeError):
                    log.debug("non-JSON text frame: %r", message)
                    ctrl = {}

                if ctrl.get("type") == "reset":
                    session.generation += 1
                    if session.interim_task and not session.interim_task.done():
                        session.interim_task.cancel()
                    session.audio = np.zeros(0, dtype=np.float32)
                    session.detected_language = None
                    session.last_interim_text = ""
                    session.last_interim_at = 0.0
                    session.speech_started = False
                    log.info("session reset — buffer cleared, language detection reset")

    except websockets.exceptions.ConnectionClosed as e:
        log.info("client disconnected (%s)", e.code)
    except Exception:
        log.exception("handler crashed")
        raise


# ── The streaming model: nemotron-asr ────────────────────────────────────────
#
# An RNNT session takes PCM as it arrives and spells the words out while the
# phrase is still being sung; nothing is re-decoded. What the sidecar adds is
# the phrase: Silero VAD still says where it ends, and at that point the
# session is CLOSED — the encoder flushes the frames its look-ahead was holding
# back, the remaining words come out, and that text is the final. The next
# phrase starts a new session, so a phrase begins without the previous one as
# left context; sung phrases are separated by the breath the VAD cut on, so
# that context was mostly silence anyway. One session per phrase also keeps
# every private detail of the decoder (frame positions, caches) out of here:
# the sidecar only ever calls feed / step / close / done / cancel.


@dataclass
class Phrase:
    """One RNNT session and the text it has produced so far."""

    session: object
    text: str = ""
    last_emit: float = 0.0
    pump: Optional[asyncio.Task] = None


@dataclass
class Stream:
    """Per-connection state of the streaming backend."""

    phrase: Optional[Phrase] = None  # None while the next session is being made
    backlog: list = field(default_factory=list)  # PCM that arrived meanwhile
    # Audio since the last commit, for the VAD only — the model already has it.
    audio: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    speech_started: bool = False
    language: Optional[str] = None  # the <xx-YY> tag the model emitted in auto mode
    generation: int = 0
    tasks: set = field(default_factory=set)


def new_stream_session():
    """A fresh RNNT session for the next phrase. Construction does model work,
    so it runs on the decoder thread like everything else that touches MLX."""
    model = get_nemotron_model()
    right = LOOKAHEAD_FRAMES.get(NEMOTRON_LOOKAHEAD_MS)
    if right is None:
        raise ValueError(f"NEMOTRON_LOOKAHEAD_MS={NEMOTRON_LOOKAHEAD_MS}: use one of {sorted(LOOKAHEAD_FRAMES)}")
    # mlx-audio's session takes the multilingual checkpoint's look-ahead from
    # the model's default (its transcription_delay_ms applies to the English
    # checkpoint only), so the default is set to ours before each session.
    model.default_att_context_size = [model.default_att_context_size[0], right]
    language = locale_for(FORCE_LANGUAGE) if FORCE_LANGUAGE else "auto"
    return model.create_streaming_session(language=language)


def drain(session, steps: int = 48) -> list[str]:
    """Advance the decoder over whatever audio is queued; returns the new text
    deltas. A step evaluates at most 32 joint outputs (blanks included), so
    48 steps cover several seconds of audio — far more than arrives between
    two feeds — and cost nothing once the queue is empty."""
    out: list[str] = []
    for _ in range(steps):
        out.extend(session.step(max_decode_tokens=32))
    return out


def flush(session, max_steps: int = 4000) -> list[str]:
    """End of phrase: close the input and decode what the look-ahead was still
    holding back. Returns the remaining deltas."""
    session.close()
    out: list[str] = []
    steps = 0
    while not session.done and steps < max_steps:
        out.extend(session.step(max_decode_tokens=64))
        steps += 1
    return out


def absorb(st: Stream, text: str, deltas: list[str]) -> str:
    """Append the decoder's deltas to a phrase, noting the language tag it
    emits in auto mode and dropping every piece of markup."""
    raw = text + "".join(deltas)
    for match in LANG_TAG_RE.finditer(raw):
        if st.language != match.group(1):
            st.language = match.group(1)
            log.info("language detected: %s", st.language)
    return clean_markup(raw)


async def handle_stream(ws):
    log.info("client connected from %s (streaming %s)", ws.remote_address, MODEL_REPO)
    st = Stream()
    vad_model = load_silero_vad()
    loop = asyncio.get_event_loop()

    def keep(task: asyncio.Task) -> asyncio.Task:
        # asyncio keeps only weak references to tasks (see Session.finals).
        st.tasks.add(task)
        task.add_done_callback(st.tasks.discard)
        return task

    async def pump(phrase: Phrase, generation: int):
        try:
            deltas = await loop.run_in_executor(DECODER, drain, phrase.session)
        except Exception:
            log.exception("streaming decode failed")
            return
        if not deltas:
            return
        phrase.text = absorb(st, phrase.text, deltas)
        now = time.monotonic()
        if (
            st.phrase is phrase
            and st.generation == generation
            and phrase.text
            and (now - phrase.last_emit) * 1000 >= STREAM_EMIT_MS
        ):
            phrase.last_emit = now
            await emit(ws, phrase.text, is_final=False)

    def schedule_pump():
        phrase = st.phrase
        if phrase is not None and (phrase.pump is None or phrase.pump.done()):
            phrase.pump = keep(asyncio.create_task(pump(phrase, st.generation)))

    async def finish(phrase: Phrase, generation: int):
        """Flush the closed phrase on the decoder thread and emit its final.
        The flush is queued behind any drain in flight for the same session,
        so that drain's words land in phrase.text before the final is read."""
        try:
            deltas = await loop.run_in_executor(DECODER, flush, phrase.session)
        except Exception:
            log.exception("streaming flush failed")
            deltas = []
        if st.generation != generation:
            return
        await emit(ws, absorb(st, phrase.text, deltas), is_final=True)

    async def open_session(generation: int):
        try:
            session = await loop.run_in_executor(DECODER, new_stream_session)
        except Exception:
            log.exception("could not start a streaming session")
            return
        if st.generation != generation:
            DECODER.submit(session.cancel)
            return
        for chunk in st.backlog:
            session.feed(chunk)
        st.backlog = []
        st.phrase = Phrase(session=session)
        schedule_pump()

    def commit(cut_sample: int, why: str):
        """Close the phrase here, decode its tail on the worker, start the next
        one — the receive loop never waits for the model."""
        phrase, st.phrase = st.phrase, None
        st.audio = st.audio[cut_sample:]
        st.speech_started = False
        if why:
            log.info("committing phrase: %s", why)
        if phrase is not None:
            keep(asyncio.create_task(finish(phrase, st.generation)))
        # Created after `finish`, so its model work queues behind the flush.
        keep(asyncio.create_task(open_session(st.generation)))

    keep(asyncio.create_task(open_session(st.generation)))

    try:
        async for message in ws:
            if isinstance(message, (bytes, bytearray)):
                chunk = pcm16_to_float32(bytes(message))
                if chunk.size == 0:
                    continue
                if st.phrase is None:
                    st.backlog.append(chunk)
                else:
                    try:
                        st.phrase.session.feed(chunk)
                    except Exception as e:  # the session's 30 s queue limit, or a closed input
                        log.warning("feed failed (%s) — closing the phrase", e)
                        commit(len(st.audio), "feed failed")
                        st.backlog.append(chunk)
                        continue
                    schedule_pump()
                st.audio = np.concatenate([st.audio, chunk])

                segments = vad_speech_segments(st.audio, vad_model)
                buffer_dur = len(st.audio) / SAMPLE_RATE
                if segments:
                    st.speech_started = True
                    last = segments[-1]
                    if (buffer_dur - last["end"]) * 1000 >= VAD_SILENCE_MS:
                        commit(int(last["end"] * SAMPLE_RATE), "")
                        continue

                if buffer_dur >= MAX_BUFFER_SECS:
                    if st.speech_started:
                        commit(len(st.audio), f"no pause for {MAX_BUFFER_SECS:.0f}s")
                    else:
                        st.audio = st.audio[-int(2 * SAMPLE_RATE):]  # silence: keep a tail

            else:
                try:
                    ctrl = json.loads(message)
                except (ValueError, TypeError):
                    log.debug("non-JSON text frame: %r", message)
                    ctrl = {}

                if ctrl.get("type") == "reset":
                    st.generation += 1
                    phrase, st.phrase = st.phrase, None
                    st.backlog = []
                    st.audio = np.zeros(0, dtype=np.float32)
                    st.speech_started = False
                    st.language = None
                    if phrase is not None:
                        DECODER.submit(phrase.session.cancel)  # on the decoder thread, after any drain
                    keep(asyncio.create_task(open_session(st.generation)))
                    log.info("session reset — phrase dropped, language detection reset")

    except websockets.exceptions.ConnectionClosed as e:
        log.info("client disconnected (%s)", e.code)
    except Exception:
        log.exception("handler crashed")
        raise
    finally:
        phrase, st.phrase = st.phrase, None
        if phrase is not None:
            DECODER.submit(phrase.session.cancel)


# ── Batch transcription (HTTP) ───────────────────────────────────────────────
#
# The WebSocket above is the LIVE path: PCM in, partials out, no word timings.
# Turning a finished recording into a replay session (`mix sinestesia.video`)
# needs the opposite — the whole file at once, with per-word timestamps.
#
# It lives here rather than in a separate tool because this is where the model
# already is: one process, one warm model, reachable by the same Elixir
# backend over the host/port it already knows. The transport is a plain HTTP
# POST of the raw wav bytes (no multipart to parse, no new dependency) served
# on LOCAL_WHISPER_BATCH_PORT by a stdlib handler in a daemon thread.
# (A dedicated port, not BIND_PORT+1: that lands on 8003, which is the local
# SDXL sidecar's default — the two run side by side in an offline setup.)
# It is faster-whisper whatever the realtime backend: the Nemotron ports give
# no word timestamps.


def transcribe_words(audio: np.ndarray, language: Optional[str]) -> list[dict]:
    """Whole-file transcription with word timings, for offline session building."""
    segments, _info = get_faster_model().transcribe(
        audio,
        language=language,
        vad_filter=True,
        word_timestamps=True,
    )

    words: list[dict] = []
    for seg in segments:
        for w in seg.words or []:
            text = w.word.strip()
            if text:
                words.append({"text": text, "start": w.start, "end": w.end})
    return words


class _BatchHandler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (stdlib naming)
        parsed = urlparse(self.path)
        if parsed.path != "/transcribe_file":
            self.send_error(404, "only /transcribe_file")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self.send_error(400, "empty body (expected raw wav bytes)")
            return

        raw = self.rfile.read(length)
        query = parse_qs(parsed.query)
        language = (query.get("language") or [None])[0] or None

        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as fh:
                fh.write(raw)
                fh.flush()
                # decode_audio gives the mono float32 at SAMPLE_RATE that the
                # model wants, whatever the input wav's layout happened to be.
                audio = decode_audio(fh.name, sampling_rate=SAMPLE_RATE)
            t0 = time.time()
            words = transcribe_words(audio, language)
            log.info(
                "batch: %d words from %.0fs of audio in %.1fs",
                len(words),
                len(audio) / SAMPLE_RATE,
                time.time() - t0,
            )
            body = json.dumps({"words": words}).encode()
        except Exception as e:  # noqa: BLE001 — report, never kill the server
            log.exception("batch transcription failed")
            self.send_error(500, str(e)[:200])
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the module logger already reports what matters


BATCH_PORT = int(os.environ.get("LOCAL_WHISPER_BATCH_PORT", "8012"))


def start_batch_server(port: int) -> None:
    server = ThreadingHTTPServer((BIND_HOST, port), _BatchHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("batch transcription on http://%s:%d/transcribe_file", BIND_HOST, port)


def warm_up() -> None:
    """Load the model and run one second of silence through it, so the first
    real phrase is not the one that pays for loading. A Nemotron checkpoint
    that cannot load dies HERE, loudly — transcribe() swallows errors so a bad
    chunk cannot kill a show, which would hide a broken model until stage time."""
    if WHISPER_BACKEND in (NEMOTRON_TRANSCRIBE, NEMOTRON_ASR):
        get_nemotron_model()
    if WHISPER_BACKEND == NEMOTRON_ASR:
        session = new_stream_session()
        session.feed(np.zeros(SAMPLE_RATE, dtype=np.float32))
        flush(session)
    else:
        _ = transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), FORCE_LANGUAGE)


async def main():
    log.info("using STT backend: %s", WHISPER_BACKEND)
    log.info("loading model: %s", MODEL_REPO)
    warm_up()
    mode = f"forced={FORCE_LANGUAGE}" if FORCE_LANGUAGE else "auto-detect"
    if WHISPER_BACKEND == NEMOTRON_ASR:
        mode += f", {NEMOTRON_LOOKAHEAD_MS} ms look-ahead"
    log.info("model loaded and warmed (language: %s)", mode)

    start_batch_server(BATCH_PORT)

    handler = handle_stream if WHISPER_BACKEND == NEMOTRON_ASR else handle
    log.info("listening on ws://%s:%d/transcribe", BIND_HOST, BIND_PORT)
    async with websockets.serve(
        handler,
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
