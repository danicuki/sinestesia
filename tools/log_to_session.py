#!/usr/bin/env python3
"""Convert a Sinestesia backend log into replay session file(s).

Usage:
    python3 tools/log_to_session.py <backend.log> [--name my-song] [--out tests/sessions]

Reads the `[provider] int/FIN +Nms: text` transcript lines, anchors timestamps
to the first transcript, and writes one session JSON per song (the log is
split on "song reset" lines). The most recent `[style] ... → "X"` line seen
before a song's first transcript is recorded as that session's style.

The output files plug straight into the replay harness:
    STT_PROVIDER=replay REPLAY_FILE=tests/sessions/<name>-1.json mix run --no-halt
    # or headless:
    cd backend && mix sinestesia.replay ../tests/sessions/<name>-1.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

TRANSCRIPT_RE = re.compile(
    r"^(?P<h>\d{2}):(?P<m>\d{2}):(?P<s>\d{2})\.(?P<ms>\d{3})\s+\[\w+\]\s+"
    r"\[(?P<provider>\w+)\]\s+(?P<kind>int|FIN)\s+\+\d+ms:\s+(?P<text>.*)$"
)
STYLE_RE = re.compile(r"\[style\].*→\s+\"(?P<style>[^\"]+)\"")
RESET_RE = re.compile(r"song reset")

MIN_EVENTS = 5  # skip fragments of songs (e.g. a reset right after a false start)


def line_ms(m) -> int:
    return (
        int(m.group("h")) * 3_600_000
        + int(m.group("m")) * 60_000
        + int(m.group("s")) * 1_000
        + int(m.group("ms"))
    )


def parse(log_text: str):
    """Yield (style, events) per song segment."""
    sessions = []
    style = None
    events = []

    def close():
        nonlocal events
        if len(events) >= MIN_EVENTS:
            sessions.append((style, events))
        events = []

    for line in log_text.splitlines():
        # Strip the trailing logger metadata so the text regex can anchor on EOL.
        line = line.rsplit(" module=", 1)[0]

        if RESET_RE.search(line):
            close()
            continue

        sm = STYLE_RE.search(line)
        if sm and not events:  # style only applies if set before the song starts
            style = sm.group("style")
            continue

        tm = TRANSCRIPT_RE.match(line)
        if tm:
            events.append((line_ms(tm), tm.group("kind") == "FIN", tm.group("text").strip()))

    close()
    return sessions


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", help="backend log file")
    ap.add_argument("--name", default=None, help="base name for the sessions (default: log stem)")
    ap.add_argument("--out", default="tests/sessions", help="output directory")
    args = ap.parse_args()

    log_path = Path(args.log)
    base = args.name or log_path.stem
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    sessions = parse(log_path.read_text(encoding="utf-8", errors="replace"))
    if not sessions:
        sys.exit("no transcript lines found — is this a backend log with [provider] int/FIN lines?")

    for i, (style, events) in enumerate(sessions, start=1):
        t0 = events[0][0]
        doc = {
            "name": f"{base}-{i}" if len(sessions) > 1 else base,
            "source_log": log_path.name,
            **({"style": style} if style else {}),
            "events": [
                {"at_ms": t - t0, "text": text, "final": final}
                for (t, final, text) in events
            ],
        }
        out = out_dir / f"{doc['name']}.json"
        out.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        dur = events[-1][0] - t0
        print(f"wrote {out} ({len(events)} events, {dur // 1000}s, style={'yes' if style else 'no'})")


if __name__ == "__main__":
    main()
