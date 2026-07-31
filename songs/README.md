# Song library

One JSON file per known song, managed by `Sinestesia.SongLibrary`
(`backend/lib/sinestesia/song_library.ex`) — not meant to be hand-edited as
the primary workflow, but plain enough that you can. Loaded/saved/imported
live via the `lyrics`-adjacent WS messages documented in `PROTOCOL.md`
("Song library").

```json
{
  "id": "aquarela",
  "title": "Aquarela do Brasil",
  "artist": "Toquinho",
  "style": null,
  "source_url": "https://www.letras.mus.br/toquinho/aquarela/",
  "lyrics_text": "Numa folha qualquer\n...",
  "added_at": "2026-08-01T00:00:00Z"
}
```

- `style`: a pinned visual style applied automatically when this song loads
  (before its lyrics, so the eager pre-render starts in the right style). Null
  means "use whatever the operator has set."
- `lyrics_text`: raw text, blank lines separate stanzas — the same format
  `Sinestesia.MusicalStructure.analyze/1` reads for verse/chorus detection.

`SONGS_DIR` overrides where this lives (default: here, resolved relative to
`backend/`'s working directory).
