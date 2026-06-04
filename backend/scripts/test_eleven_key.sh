#!/usr/bin/env bash
# Verify ElevenLabs API key has correct scope by hitting the non-streaming
# /v1/speech-to-text endpoint. If this works, your key has STT permissions and
# the realtime issue is a protocol/param problem. If it fails with 401/403,
# your key/scope is the problem.
set -e

if [ -z "$ELEVENLABS_API_KEY" ]; then
  # try to load from .env
  if [ -f ../../.env ]; then
    export $(grep -E '^ELEVENLABS_API_KEY=' ../../.env | xargs)
  fi
fi

if [ -z "$ELEVENLABS_API_KEY" ]; then
  echo "ELEVENLABS_API_KEY not set"
  exit 1
fi

echo "Key: ${ELEVENLABS_API_KEY:0:12}..."

# Download a tiny sample audio (4s of speech)
SAMPLE=/tmp/sinestesia_test.mp3
if [ ! -f "$SAMPLE" ]; then
  echo "Downloading sample..."
  curl -s -o "$SAMPLE" https://storage.googleapis.com/cloud-samples-data/speech/brooklyn_bridge.flac
fi

echo "Calling POST https://api.elevenlabs.io/v1/speech-to-text ..."
curl -s -X POST https://api.elevenlabs.io/v1/speech-to-text \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v1" \
  -F "file=@$SAMPLE" \
  -w "\nHTTP %{http_code}\n" | head -40
