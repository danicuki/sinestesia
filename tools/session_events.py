"""Shared word-timings → session-events logic.

Extracted from song_to_session.py so video_to_session.py (local Whisper) and
song_to_session.py (ElevenLabs batch Scribe) build IDENTICAL event streams —
the replay harness treats both the same, and a segmentation tweak made in one
tool must not silently diverge from the other.

The contract: a list of word dicts `{"text", "start", "end"}` (seconds) in,
a list of session events `{"at_ms", "text", "final"}` out, mimicking what the
realtime STT emits live — growing partials per word, a `final` commit at each
phrase boundary — so the Director fires on the same fragments it sees on stage.
"""

SENTENCE_END = ".?!…"
PHRASE_END = ",;:" + SENTENCE_END  # sung lines usually end on a comma


def build_events(words: list[dict], gap_s: float) -> list[dict]:
    """Reconstruct the live STT stream from batch word timings.

    Batch transcription doesn't do VAD — consecutive word timings are tight
    even across breaths — so segmentation is on PUNCTUATION (commas/periods
    mark sung line-ends), with a silence > gap_s as a fallback for
    instrumental breaks."""
    events: list[dict] = []
    t0 = 0.0
    utter: list[str] = []
    prev_end = None

    def ms(t):
        return round((t - t0) * 1000)

    for i, w in enumerate(words):
        # A long silence (instrumental break) commits whatever was pending.
        if prev_end is not None and (w["start"] - prev_end) > gap_s and utter:
            events.append({"at_ms": ms(prev_end), "text": " ".join(utter), "final": True})
            utter = []

        utter.append(w["text"])
        is_last = i == len(words) - 1
        ends_phrase = w["text"].rstrip()[-1:] in PHRASE_END
        next_gap = is_last or (words[i + 1]["start"] - w["end"]) > gap_s
        commit_here = ends_phrase or next_gap

        # Growing partial: trailing "-" mid-phrase mimics the live mid-word cut.
        text = " ".join(utter) + ("" if commit_here else "-")
        events.append({"at_ms": ms(w["end"]), "text": text, "final": False})

        if commit_here:
            events.append({"at_ms": ms(w["end"]), "text": " ".join(utter), "final": True})
            utter = []
        prev_end = w["end"]

    if utter:
        events.append({"at_ms": ms(words[-1]["end"]), "text": " ".join(utter), "final": True})
    # at_ms must be monotonic for the replay clock; partial sorts before its
    # final at the same timestamp.
    events.sort(key=lambda e: (e["at_ms"], e["final"]))
    return events
