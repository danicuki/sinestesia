# Video scripts

Two films, because they answer different questions. Trying to serve both in one
is why the first script felt wrong.

| | Film A — hackathon | Film B — marketing |
|---|---|---|
| Audience | Judges, sponsors, engineers | Artists, producers, fans |
| Question answered | *Is this real, and did you build it?* | *Do I want this at my show?* |
| Length | **≤ 4 min** (matches live judging) | 60–90 s |
| Register | Show the machine working | Show the feeling |
| Blockchain | Central | Barely mentioned |
| Priority | **P0 — required for submission** | P1 — after the deploy |

The rules deck is explicit: **less slides, more demo.** Both films should be
mostly screen and stage, not talking head.

---

# Film A — hackathon demo (≤ 4 min)

Judges see many submissions. Lead with the artifact, prove it is live, then
explain. Never open with architecture.

### 0:00–0:20 — Cold open, no narration
Real footage: a voice singing, and the painting growing on the projection behind
it. Let it play. No logo, no titles, no explanation.

Then one line of narration:
> "Everything you just saw was painted live, from that voice, while she sang."

### 0:20–0:50 — What it is
> "Sinestesia listens to a singer — the words and how they're sung — and paints
> one picture that grows across the whole song. Not a slideshow. One canvas that
> keeps building."

Show the live view: transcript arriving → the director's instruction → the new
element appearing on the canvas. Point at each on screen.

### 0:50–1:40 — The AI, and why it's verifiable *(0G)*
> "The director — the model deciding what to paint — runs on 0G's compute
> network, on a TEE-sealed model. Every response is signed, and we check that
> signature."

On screen: the **Verifiable AI badge** on the projection, with the model name.
Then show the honest part — it is the strongest thing in the film:
> "Three states, not two: verified, still settling on-chain, or settled but the
> provider couldn't sign it. We show which one it actually is."

Then the fallback:
> "If 0G is slow, it falls back to a local model so the show never stalls — and
> the badge tells you which one actually ran. The provenance records the model
> that produced every single prompt, not the one we configured."

### 1:40–2:40 — The artifact *(Sui + Walrus)*
> "When the song ends, we mint it."

Show it happening live: press mint → overlay → QR appears.
> "The image isn't the last frame. It's every beat of the song, in order —
> the whole painting assembling itself."

Then the provenance, the part most projects don't have:
> "The token carries a hash of the performance: the transcript, every director
> prompt with its timestamp and the model that wrote it. And we publish the
> preimage — so anyone can re-hash it and check it against the chain. A
> certificate you can actually open."

Show `/claim` — the certificate page — and point at **verified: true**.
> "Artwork on Walrus, master 1/1 to the artist, and anyone in the room scans the
> QR for a free print."

Scan the QR on a real phone on camera. Show the print arriving.

### 2:40–3:20 — Architecture, fast
One diagram, 20 seconds, then back to the running system:
> "Elixir backend, three parallel rails — speech, music features, and the
> director. Two sidecars: 0G for verifiable inference, Sui and Walrus for the
> mint. The blockchain work is a feature added on top of a project I've been
> building since June — it's the Extend Open Source track."

Say the diff out loud; judges are auditing it:
> "Everything from this weekend is in one branch you can diff."

### 3:20–4:00 — Close, honestly
> "It's live and deployed — link in the submission. The show itself runs local
> for latency."

End on the artwork, not on your face.

**If you have to cut:** lose the architecture section. Keep the badge, the QR
scan, and the certificate — those are the three things nobody else has.

---

# Film B — marketing (60–90 s)

No jargon. No chain names. The word "mint" probably doesn't appear.

### 0:00–0:15 — The hook
Dark venue. A voice starts. Behind the singer, a mark appears on a blank canvas.
No narration at all. Just the song and the painting starting.

### 0:15–0:45 — The promise
Cut between the artist singing and the painting growing — one element per line.
> "Your voice, painted while you sing it. One picture that grows with the song,
> so every performance looks like nothing else — and never looks the same twice."

### 0:45–1:10 — The keepsake
The audience with phones up. The finished painting on the screen.
> "When the song ends, the painting is finished — and everyone in the room can
> keep it. A real piece of that night, that only exists because they were there."

### 1:10–1:30 — Who it's for, and the ask
Two beats, matching the two landing pages:
> "For artists who want their show to be unforgettable. For festivals that want a
> moment people photograph."

Close on the wordmark and the URL. One call to action, not three.

---

## Production notes

- **Record the real thing.** The rules deck recommends CursorClip or ScreenKite
  for screen capture. Capture a genuine performance, not a reenactment — a real
  song produces better material than anything staged, and judges can tell.
- **Capture the phone scan on camera.** That single shot proves the audience
  loop works better than any explanation.
- **Audio matters most.** It is a music product. Bad audio undoes good visuals —
  record the vocal clean, not off a laptop mic.
- **Shoot Film A first.** It is the one that's required.
- Have a **backup recording** of a complete successful run before you rely on
  performing live to camera.
