#!/usr/bin/env bash
# Spike S1: sends <count> cheap GETs (GET /v1/territories?limit=1) as fast as <parallel> workers allow,
# with one GET-scoped token, and logs HTTP status, X-Rate-Limit and timing per request. Read-only.
# Usage: Tools/s1-burst.sh [count=400] [parallel=16]
# Environment: ASC_KEY_ID, ASC_P8_PATH, ASC_ISSUER_ID (team keys).
set -euo pipefail
cd "$(dirname "$0")/.."

count="${1:-400}"
parallel="${2:-16}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_P8_PATH:?set ASC_P8_PATH}"

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
swift Tools/mint-token.swift --key-id "$ASC_KEY_ID" --issuer-id "${ASC_ISSUER_ID:-}" --p8 "$ASC_P8_PATH" \
    --path /v1/territories --query 'limit=1' | sed 's/^/Authorization: Bearer /' > "$work/auth-header"
chmod 600 "$work/auth-header"
export S1_AUTH="$work/auth-header"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="docs/spikes/S1-burst-$stamp.log"
started="$(date +%s)"
seq 1 "$count" | xargs -P "$parallel" -I{} sh -c '
  curl -sS -o /dev/null -D - -w "status=%{http_code} seconds=%{time_total}\n" -H @"$S1_AUTH" \
    "https://api.appstoreconnect.apple.com/v1/territories?limit=1" \
  | tr -d "\r" | grep -i -e "^x-rate-limit:" -e "^status=" | tr "\n" " "; echo "at=$(date -u +%H:%M:%S)"
' > "$log"
finished="$(date +%s)"

elapsed=$(( finished - started ))
[[ "$elapsed" -gt 0 ]] || elapsed=1
ok="$(grep -c 'status=200' "$log" || true)"
limited="$(grep -c 'status=429' "$log" || true)"
other=$(( count - ok - limited ))
echo "requests=$count elapsed=${elapsed}s rate_per_minute=$(( count * 60 / elapsed )) ok=$ok rate_limited=$limited other=$other"
echo "first 429 at line: $(grep -n 'status=429' "$log" | head -1 | cut -d: -f1)"
echo "last X-Rate-Limit: $(grep -o -i 'x-rate-limit: [^ ]*' "$log" | tail -1)"
echo "log: $log"
