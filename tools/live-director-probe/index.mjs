// Probe: can Gemini's Live Audio EAP models act as a LISTENING DIRECTOR?
//
// The bet: walkie-talkie collapses Sinestesia's realtime chain
// (mic → STT → Director → prompt) into ONE streaming session — the model
// hears the singing directly and fires async draw_scene() function calls,
// scheduled SILENT so it never speaks. This probe simulates the stage:
// it streams a local audio file (the cached Demucs vocal stem is ideal)
// at REAL-TIME pace and logs every draw_scene with a wall-clock stamp, so
// you can hold the log against the lyrics and judge the two unknowns:
//
//   1. does it understand SUNG words (not just speech)?
//   2. how far behind the sung line does each direction land?
//
// Usage (needs an API key from an EAP-granted GCP project):
//
//   cd tools/live-director-probe && npm install
//   GOOGLE_API_KEY=... node index.mjs ~/Library/Caches/sinestesia/media-*/htdemucs/source/vocals.wav
//   GOOGLE_API_KEY=... node index.mjs vocals.wav --model clever-chatter --lyrics letra.txt
//
// --lyrics injects the full lyric sheet mid-session via send_client_content
// (supported throughout the session in this EAP) — the preloaded-song
// context the live pipeline would provide.

import {GoogleGenAI, Modality} from '@google/genai';
import {execFileSync} from 'node:child_process';
import {readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const args = process.argv.slice(2);
const audioPath = args.find((a) => !a.startsWith('--'));
const flag = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : dflt;
};

if (!audioPath || !process.env.GOOGLE_API_KEY) {
  console.error('usage: GOOGLE_API_KEY=... node index.mjs <audio-file> [--model walkie-talkie] [--lyrics file.txt]');
  process.exit(1);
}

const model = `models/${flag('model', 'walkie-talkie')}`;
const lyricsPath = flag('lyrics', null);

// The Live API wants 16 kHz mono PCM16; ffmpeg converts whatever we have.
const pcmPath = join(tmpdir(), `probe-${Date.now()}.pcm`);
execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', audioPath, '-ac', '1', '-ar', '16000', '-f', 's16le', pcmPath]);
const pcm = readFileSync(pcmPath);
rmSync(pcmPath);

const BYTES_PER_SEC = 16000 * 2;
const CHUNK_MS = 200;
const CHUNK_BYTES = (BYTES_PER_SEC * CHUNK_MS) / 1000;

const started = Date.now();
const stamp = () => {
  const s = (Date.now() - started) / 1000;
  return `[${String(Math.floor(s / 60)).padStart(2, '0')}:${(s % 60).toFixed(1).padStart(4, '0')}]`;
};

const ai = new GoogleGenAI({apiKey: process.env.GOOGLE_API_KEY});

let calls = 0;

const session = await ai.live.connect({
  model,
  config: {
    responseModalities: [Modality.AUDIO],
    outputAudioTranscription: {},
    // What the model HEARS, verbatim — answers the sung-word-comprehension
    // question even if it never fires a tool call.
    inputAudioTranscription: {},
    systemInstruction:
      'You are the silent visual director of a live music performance. You LISTEN to the ' +
      'singer and, for each sung line or phrase, immediately call draw_scene with one vivid, ' +
      'concrete scene direction (15-30 words, English): subject, action, light — expressing ' +
      'what the line MEANS, never illustrating metaphors literally. Interpret songs in any ' +
      'language. NEVER speak or produce audio commentary. Only call draw_scene.',
    tools: [
      {
        functionDeclarations: [
          {
            name: 'draw_scene',
            description: 'Paint the next scene of the live visual. Call once per sung line/phrase.',
            // walkie-talkie defaults to NON_BLOCKING (async) — exactly what
            // a director needs: keep listening while the scene renders.
            parameters: {
              type: 'OBJECT',
              properties: {
                direction: {type: 'STRING', description: 'the scene direction'},
              },
              required: ['direction'],
            },
          },
        ],
      },
    ],
  },
  callbacks: {
    onopen: () => console.log(`${stamp()} session open (${model})`),
    onmessage: (msg) => {
      if (msg.toolCall?.functionCalls?.length) {
        for (const fc of msg.toolCall.functionCalls) {
          calls += 1;
          console.log(`${stamp()} draw_scene #${calls}: ${fc.args?.direction ?? JSON.stringify(fc.args)}`);
          // SILENT scheduling: acknowledge without inviting the model to
          // narrate the result out loud.
          session.sendToolResponse({
            functionResponses: [
              {id: fc.id, name: fc.name, response: {result: 'rendered'}, scheduling: 'SILENT'},
            ],
          });
        }
      }

      const heardIn = msg.serverContent?.inputTranscription?.text;
      if (heardIn) console.log(`${stamp()} heard: ${JSON.stringify(heardIn)}`);

      const spoke = msg.serverContent?.outputTranscription?.text;
      if (spoke) console.log(`${stamp()} (model spoke: ${JSON.stringify(spoke)})`);

      if (msg.serverContent?.interrupted) console.log(`${stamp()} (interrupted)`);
      if (msg.serverContent?.turnComplete) console.log(`${stamp()} (turnComplete)`);

      // Anything we didn't decode: name its shape, never swallow it — a
      // mute probe taught us nothing on its first run.
      if (!msg.toolCall && !msg.serverContent && !msg.setupComplete) {
        console.log(`${stamp()} msg: ${JSON.stringify(Object.keys(msg))}`);
      }
    },
    onerror: (e) => console.error(`${stamp()} error:`, e?.message ?? e),
    onclose: (e) => console.log(`${stamp()} closed`, e?.reason ?? ''),
  },
});

if (lyricsPath) {
  const lyrics = readFileSync(lyricsPath, 'utf8');
  // turnComplete: true — WITHOUT it the server sits waiting for more
  // client content before generating anything (EAP doc), which muted the
  // whole first probe run. At t=0 there is nothing to interrupt.
  session.sendClientContent({
    turns: `CONTEXT — the full lyrics of the song about to be performed (for interpretation; direct only what is actually sung):\n${lyrics}`,
    turnComplete: true,
  });
  console.log(`${stamp()} lyrics injected as client content`);
}

// Stream at REAL-TIME pace: the whole point is measuring live latency, so
// the file must not arrive faster than a singer would sing it.
console.log(`${stamp()} streaming ${(pcm.length / BYTES_PER_SEC).toFixed(1)}s of audio in real time…`);

let sent = 0;

for (let off = 0; off < pcm.length; off += CHUNK_BYTES) {
  session.sendRealtimeInput({
    media: {data: pcm.subarray(off, off + CHUNK_BYTES).toString('base64'), mimeType: 'audio/pcm;rate=16000'},
  });

  sent += CHUNK_MS;
  if (sent % 15000 === 0) {
    console.log(`${stamp()} …streaming (${sent / 1000}s sent, ${calls} draw_scene so far)`);
  }

  await new Promise((r) => setTimeout(r, CHUNK_MS));
}

console.log(`${stamp()} audio done — waiting 8s for trailing calls`);
await new Promise((r) => setTimeout(r, 8000));
console.log(`${stamp()} total draw_scene calls: ${calls}`);
session.close();
