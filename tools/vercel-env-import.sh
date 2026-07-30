#!/usr/bin/env bash
# Bulk-import a .env file into a linked Vercel project.
#
# The Vercel CLI has no "import a whole file" command — `vercel env add` takes
# one variable at a time. But `--value` makes it non-interactive, so we can loop.
#
#   ./tools/vercel-env-import.sh sui/mint/.env production
#   ./tools/vercel-env-import.sh .env.production production,preview
#
# Run it from the directory of the project you linked (or pass --cwd through
# VERCEL_CWD). Existing variables are overwritten (--force).
#
# Lines that are blank or start with # are skipped. Values may be quoted.
set -euo pipefail

ENV_FILE="${1:-.env}"
TARGETS="${2:-production}"

if [ ! -f "$ENV_FILE" ]; then
  echo "No such file: $ENV_FILE" >&2
  exit 1
fi

if [ ! -d .vercel ] && [ -z "${VERCEL_CWD:-}" ]; then
  echo "This directory isn't linked to a Vercel project (no .vercel/)." >&2
  echo "Run 'vercel link' here first." >&2
  exit 1
fi

# Never push local-only wiring to the cloud: these point at the show laptop and
# would silently break the deployment (or the QR codes) if uploaded.
SKIP_KEYS="MINT_PORT ZG_PORT MINT_SIDECAR_URL ZEROG_SIDECAR_URL"

count=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$(printf '%s' "$line" | tr -d '[:space:]')" in
    ''|'#'*) continue ;;
  esac

  key=${line%%=*}
  value=${line#*=}
  key=$(printf '%s' "$key" | xargs)              # trim
  value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  value=${value%\"}; value=${value#\"}           # strip surrounding quotes
  value=${value%\'}; value=${value#\'}

  [ -z "$key" ] && continue

  skip=false
  for s in $SKIP_KEYS; do
    [ "$key" = "$s" ] && skip=true
  done
  if [ "$skip" = true ]; then
    echo "  skip  $key (local-only)"
    continue
  fi

  for target in $(printf '%s' "$TARGETS" | tr ',' ' '); do
    if vercel env add "$key" "$target" --value "$value" --force --yes >/dev/null 2>&1; then
      echo "  ok    $key -> $target"
      count=$((count + 1))
    else
      echo "  FAIL  $key -> $target" >&2
    fi
  done
done < "$ENV_FILE"

echo "Imported $count variable(s). Redeploy for them to take effect: vercel --prod"
