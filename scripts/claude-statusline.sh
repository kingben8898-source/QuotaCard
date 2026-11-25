#!/bin/sh
# Claude Code (/statusline) bridge for QuotaCard
INGEST="${QUOTA_CARD_INGEST:-$HOME/.quota-card/bin/quota-card-ingest}"
if [ -x "$INGEST" ]; then
  exec "$INGEST" --provider claude --print-statusline
fi
cat >/dev/null
