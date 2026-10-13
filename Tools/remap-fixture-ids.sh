#!/usr/bin/env bash
# Usage: Tools/remap-fixture-ids.sh <fixture.json> <map.txt>
# Input must already be redacted (Tools/record-fixture.sh or Tools/redact-fixture.py).
# map.txt: one "REAL_VALUE SYNTHETIC_VALUE" pair per line. Longer real values are replaced first, so an id that is a
# prefix of another id cannot corrupt it. Fails if any REAL_VALUE is still present or the result is not valid JSON.
set -euo pipefail
if [[ $# -ne 2 ]]; then echo "usage: $0 <fixture.json> <map.txt>" >&2; exit 64; fi
file="$1"; map="$2"
if grep -qE 'Bearer |-----BEGIN' "$file"; then echo "refusing: $file contains a secret marker" >&2; exit 3; fi
sorted="$(mktemp)"
trap 'rm -f "$sorted"' EXIT
awk 'NF == 2 { print length($1) " " $1 " " $2 }' "$map" | sort -rn | cut -d' ' -f2- > "$sorted"
while read -r real synthetic; do
  REAL="$real" SYN="$synthetic" perl -pi -e 's/\Q$ENV{REAL}\E/$ENV{SYN}/g' "$file"
done < "$sorted"
while read -r real _; do
  if grep -qF "$real" "$file"; then echo "still contains $real: $file" >&2; exit 1; fi
done < "$sorted"
jq empty "$file"
