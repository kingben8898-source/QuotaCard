#!/bin/sh
# Antigravity CLI (/statusline) bridge for QuotaCard
INGEST="${QUOTA_CARD_INGEST:-$HOME/.quota-card/bin/quota-card-ingest}"
if [ -x "$INGEST" ]; then
  exec "$INGEST" --provider antigravity --print-statusline
fi
cat >/dev/null
