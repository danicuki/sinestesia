#!/bin/sh
# Start the 0G sidecar alongside the backend.
#
# The sidecar is deliberately NOT required for the show to run: if it fails to
# start (unfunded wallet, provider offline), the Director's fallback chain moves
# on to a cloud model and the visuals keep coming — the on-screen badge simply
# reports which model actually ran. So we start it, log loudly if it dies, and
# let the backend be the process that owns the container's lifetime.
set -eu

if [ -n "${ZG_PRIVATE_KEY:-}" ]; then
  echo "[entrypoint] starting 0G sidecar on :${ZG_PORT:-8788}"
  (
    cd /app/zerog || exit 0
    # Compiled at build time (see Dockerfile) — plain JS, no TS loader needed.
    node dist/server.js 2>&1 | sed 's/^/[0g] /' &
  )
else
  echo "[entrypoint] ZG_PRIVATE_KEY unset — skipping 0G sidecar."
  echo "[entrypoint] Director will use its fallback chain; no verification badge."
fi

echo "[entrypoint] starting backend on :${PORT:-4000}"
exec /app/backend/bin/sinestesia start
