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
// Flags: --manual-vad (EAP refuses it today), --segment N, --no-norm.
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

// The EAP servers REFUSE manual activity signals today ("Precondition
// check failed" on both models at the first activityEnd), so automatic
// VAD is the default; --manual-vad keeps the phrase-segment protocol
// ready for the day they honor it. Meanwhile the founder SANG at the
// AI Studio mic and walkie-talkie transcribed the lyrics almost
// perfectly — singing IS understood, so the earlier zero-activity run
// points at our audio (a quiet, artifact-laden Demucs stem), hence the
// loudness normalization below.
const autoVad = !args.includes('--manual-vad');
const segmentMs = Number(flag('segment', '8')) * 1000;

// The Live API wants 16 kHz mono PCM16. loudnorm lifts the input to
// speech-typical loudness first: a Demucs vocal stem can sit far below
// what a mic delivers, and a too-quiet signal never wakes the VAD.
const pcmPath = join(tmpdir(), `probe-${Date.now()}.pcm`);
const audioFilter = args.includes('--no-norm') ? 'anull' : 'loudnorm=I=-16:TP=-1.5';
execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', audioPath, '-af', audioFilter, '-ac', '1', '-ar', '16000', '-f', 's16le', pcmPath]);
const pcm = readFileSync(pcmPath);

// Prove the signal is actually there after conversion — a silent stream
// and a deaf server look identical from the outside.
const stats = execFileSync(
  'ffmpeg',
  ['-f', 's16le', '-ar', '16000', '-ac', '1', '-i', pcmPath, '-af', 'volumedetect', '-f', 'null', '-'],
  {stdio: ['ignore', 'ignore', 'pipe']},
).toString();
const vol = stats.match(/mean_volume: [^\n]+|max_volume: [^\n]+/g);
console.log(`audio after conversion: ${vol ? vol.join(', ') : 'volumedetect failed'}`);
rmSync(pcmPath);

const BYTES_PER_SEC = 16000 * 2;
const CHUNK_MS = 200;
const CHUNK_BYTES = (BYTES_PER_SEC * CHUNK_MS) / 1000;

const started = Date.now();
const stamp = () => {
  const s = (Date.now() - started) / 1000;
  return `[${String(Math.floor(s / 60)).padStart(2, '0')}:${(s % 60).toFixed(1).padStart(4, '0')}]`;
};

// EAP Live models live on the alpha channel — AI Studio speaks v1alpha
// to them, and a v1beta session can half-work (opens, then hears
// nothing). --api-version v1beta to compare.
const apiVersion = flag('api-version', 'v1alpha');
const ai = new GoogleGenAI({apiKey: process.env.GOOGLE_API_KEY, httpOptions: {apiVersion}});

let calls = 0;
let closed = false;

const session = await ai.live.connect({
  model,
  config: {
    responseModalities: [Modality.AUDIO],
    ...(autoVad ? {} : {realtimeInputConfig: {automaticActivityDetection: {disabled: true}}}),
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
    onopen: () => console.log(`${stamp()} session open (${model}, ${apiVersion})`),
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

      // Anything we didn't decode: dump it truncated, never swallow it — a
      // mute probe taught us nothing on its first run, and Object.keys
      // hid the contents of several message kinds on the second.
      if (!msg.toolCall && !msg.serverContent && !msg.setupComplete) {
        const raw = JSON.stringify(msg, (k, v) => (k === 'data' ? `<${(v?.length ?? 0)} bytes>` : v));
        console.log(`${stamp()} msg: ${raw?.slice(0, 300)}`);
      }
    },
    onerror: (e) => console.error(`${stamp()} error:`, e?.message ?? e),
    onclose: (e) => {
      closed = true;
      console.log(`${stamp()} closed`, e?.reason ?? '');
    },
  },
});

if (lyricsPath) {
  const lyrics = readFileSync(lyricsPath, 'utf8');
  // turnComplete: true — WITHOUT it the server sits waiting for more
  // client content before generating anything (EAP doc), which muted the
  // whole first probe run. At t=0 there is nothing to interrupt.
  session.sendClientContent({
    turns:
      `CONTEXT — the full lyrics of the song about to be performed (for interpretation; ` +
      `direct only what is actually sung). Do NOT respond to this message and do NOT direct ` +
      `anything yet — wait for the singing:\n${lyrics}`,
    turnComplete: true,
  });
  console.log(`${stamp()} lyrics injected as client content`);
}

// Stream at REAL-TIME pace: the whole point is measuring live latency, so
// the file must not arrive faster than a singer would sing it.
console.log(`${stamp()} streaming ${(pcm.length / BYTES_PER_SEC).toFixed(1)}s of audio in real time…`);

let sent = 0;
let inActivity = false;

for (let off = 0; off < pcm.length && !closed; off += CHUNK_BYTES) {
  if (!autoVad && !inActivity) {
    session.sendRealtimeInput({activityStart: {}});
    inActivity = true;
  }

  session.sendRealtimeInput({
    media: {data: pcm.subarray(off, off + CHUNK_BYTES).toString('base64'), mimeType: 'audio/pcm;rate=16000'},
  });

  sent += CHUNK_MS;

  // Close the activity at phrase-sized boundaries: an ended segment is a
  // completed utterance the model can react to, mid-song.
  if (!autoVad && inActivity && sent % segmentMs === 0) {
    session.sendRealtimeInput({activityEnd: {}});
    inActivity = false;
  }

  if (sent % 15000 === 0) {
    console.log(`${stamp()} …streaming (${sent / 1000}s sent, ${calls} draw_scene so far)`);
  }

  await new Promise((r) => setTimeout(r, CHUNK_MS));
}

if (closed) {
  console.log(`${stamp()} server closed the session mid-stream — stopping (${calls} draw_scene)`);
  process.exit(1);
}

if (!autoVad && inActivity) session.sendRealtimeInput({activityEnd: {}});

console.log(`${stamp()} audio done — waiting 8s for trailing calls`);
await new Promise((r) => setTimeout(r, 8000));
console.log(`${stamp()} total draw_scene calls: ${calls}`);
session.close();
