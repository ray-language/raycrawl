#!/bin/sh
# Starts the fixture site (native binary, port 0), crawls it with sitemaps on, and stops it.
set -eu
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
./raycrawl testsite > "$OUT/site.txt" &
SITE=$!
trap '[ -n "$SITE" ] && kill "$SITE" 2>/dev/null; rm -rf "$OUT"' EXIT
i=0
while [ ! -s "$OUT/site.txt" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
BASE=$(head -1 "$OUT/site.txt")
echo "fixture site at $BASE"
./raycrawl robots "$BASE/private/secret.html" || true
./raycrawl crawl "$BASE/" --sitemaps --delay 0 --retries 2 --out pages.jsonl --quiet
echo "pages.jsonl: $(wc -l < pages.jsonl) lines"
