#!/bin/bash
# Capture setup — sorts Kalshi orderbook capture files (.ndjson.gz) into the
# layout the twin's replay expects: $KALSHI_CAPTURE_DIR/events/<ticker>/*.ndjson.gz
# (default ~/data/kalshi-orderbook). The ticker is read from each file's first
# record, so it works no matter how the files are currently named or arranged.
# Usage: bash capture-setup.sh <dir-or-file> [more...]
set -u
DEST="${KALSHI_CAPTURE_DIR:-$HOME/data/kalshi-orderbook}"
[ $# -ge 1 ] || { echo "usage: bash capture-setup.sh <dir-or-file> [more...]"; exit 1; }

placed=0 skipped=0 bad=0
while IFS= read -r f; do
  first=$(gzip -dc "$f" 2>/dev/null | head -1)
  if [ -z "$first" ]; then echo "✗ cannot decompress $f (not gzip, or empty) — skipping"; bad=$((bad+1)); continue; fi
  ticker=$(printf '%s\n' "$first" | grep -o '"market_ticker":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$ticker" ]; then echo "✗ no market_ticker in $f — skipping"; bad=$((bad+1)); continue; fi
  dir="$DEST/events/$ticker"
  dest="$dir/$(basename "$f")"
  if [ "$f" -ef "$dest" ] || [ -f "$dest" ]; then skipped=$((skipped+1)); continue; fi
  mkdir -p "$dir"
  cp "$f" "$dest" || { echo "✗ copy failed: $f"; bad=$((bad+1)); continue; }
  placed=$((placed+1))
done < <(find "$@" -name '*.ndjson.gz' -type f 2>/dev/null)

total=$(find "$DEST/events" -name '*.ndjson.gz' -type f 2>/dev/null | wc -l | tr -d ' ')
markets=$(ls "$DEST/events" 2>/dev/null | wc -l | tr -d ' ')
echo "✓ $placed placed, $skipped already in place, $bad skipped — $markets markets / $total files under $DEST/events"
[ "$markets" -gt 0 ] || { echo "✗ no captures found — pass the folder holding your .ndjson.gz files"; exit 1; }

# If the twin is up, confirm it sees them.
if curl -sf localhost:8080/_rystic/version >/dev/null 2>&1; then
  n=$(curl -sf localhost:8080/_replay/markets | grep -o '"' | wc -l)
  if [ "$n" -gt 2 ]; then
    echo "✓ twin sees the captures — open the Replay card in the UI (or POST /_replay/start) to play one"
  else
    echo "⚠ twin is running but lists no replay markets — restart it so it picks up $DEST"
    echo "  (if you use a custom location, start it with KALSHI_CAPTURE_DIR=$DEST ./kalshi-twin)"
  fi
else
  echo "→ next: start the twin (./kalshi-twin), then check localhost:8080/_replay/markets"
fi
