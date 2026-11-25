#!/bin/sh
# Passive stdin JSON forwarder for OpenAI Codex CLI rateLimits payloads
# Example: <your-codex-rate-limit-json-command> | ~/.quota-card/scripts/codex-ingest.sh
INGEST="${QUOTA_CARD_INGEST:-$HOME/.quota-card/bin/quota-card-ingest}"
if [ -x "$INGEST" ]; then
  exec "$INGEST" --provider codex
fi
echo "quota-card-ingest not found at $INGEST" >&2
exit 1
