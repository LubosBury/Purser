#!/usr/bin/env bash
# Records one App Store Connect GET response as a redacted, anonymized test fixture. Never stores Authorization.
# Usage: Tools/record-fixture.sh <fixture-rel-path> <GET-path>[?query] [query]
#   <fixture-rel-path>  path under Packages/PurserCore/Tests/Fixtures/ without ".json", e.g. asc/recorded/prices-spikeA
#   <GET-path>          /v1/... or /v2/...; the query goes after the first '?' or into the third argument, never both
# Environment: ASC_KEY_ID, ASC_P8_PATH (the downloaded .p8), ASC_ISSUER_ID (team keys; leave unset for individual keys).
# Writes Fixtures/<rel>.json and Fixtures/<rel>.meta.json only after Tools/redact-fixture.py and
# Tools/anonymize-fixture.py ran and no token, key or original id is left. The raw response and its meta stay only in
# build/fixtures-local/<rel>.json (gitignored), for chaining ids between calls and for local checks.
# Exit codes: 2 usage, 3 token or key in the output, 4 an original id survived; on 3 and 4 the fixture files and the raw
# copy of <rel> are removed.
# Example: Tools/record-fixture.sh asc/recorded/prices-spikeA /v1/subscriptions/123/prices 'include=subscriptionPricePoint,territory&limit=200'
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage() {
    echo "$1" >&2
    echo "usage: Tools/record-fixture.sh <fixture-rel-path> <GET-path>[?query] [query]" >&2
    exit 2
}

rel="${1:-}"
target="${2:-}"
extra_query="${3:-}"
[[ -n "$rel" && -n "$target" ]] || usage "missing arguments"
[[ "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || usage "fixture path may contain only letters, digits, '.', '_', '-' and '/'"
[[ "$rel" != /* ]] || usage "fixture path must be relative to Packages/PurserCore/Tests/Fixtures"
case "/$rel/" in
    *//*) usage "fixture path must not contain an empty segment" ;;
    */../*) usage "fixture path must not contain '..'" ;;
esac
if [[ "$target" == *\?* ]]; then
    endpoint="${target%%\?*}"
    query="${target#*\?}"
    [[ -z "$extra_query" ]] || usage "give the query either after '?' or as the third argument, not both"
else
    endpoint="$target"
    query="$extra_query"
fi
[[ "$endpoint" =~ ^/v[12]/ ]] || usage "path must start with /v1/ or /v2/"
case "$endpoint/" in
    *//* | */../*) usage "path must not contain an empty segment or '..'" ;;
esac
[[ -n "${ASC_KEY_ID:-}" ]] || usage "set ASC_KEY_ID"
[[ -n "${ASC_P8_PATH:-}" ]] || usage "set ASC_P8_PATH"

fixtures="Packages/PurserCore/Tests/Fixtures"
local_root="build/fixtures-local"
out="$fixtures/$rel"
raw="$local_root/$rel"
git check-ignore -q "$raw.json" || usage "$local_root is not gitignored (build/ must be in .gitignore); refusing to keep a raw copy"
mkdir -p "$(dirname "$out")" "$(dirname "$raw")"
chmod 700 "$local_root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail_clean() {
    rm -f "$out.json" "$out.meta.json" "$raw.json" "$raw.meta.json"
    echo "$2; nothing was kept" >&2
    exit "$1"
}

write_meta() {
    python3 -I - "$1" "$2" "$3" "$status" "$rate" <<'PY'
import datetime, json, sys
out, path, query, status, rate = sys.argv[1:6]
meta = {"path": path, "query": query, "status": int(status), "xRateLimit": rate,
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

# The GET-scoped token lives only in a private temp file passed to curl with -H @file, never in `ps` or the history.
swift Tools/mint-token.swift --key-id "$ASC_KEY_ID" --issuer-id "${ASC_ISSUER_ID:-}" --p8 "$ASC_P8_PATH" \
    --path "$endpoint" --query "$query" | sed 's/^/Authorization: Bearer /' > "$work/auth-header"
url="https://api.appstoreconnect.apple.com${endpoint}"
[[ -z "$query" ]] || url="${url}?${query}"
status="$(curl -sS -g -o "$work/body.json" -D "$work/headers.txt" -w '%{http_code}' -H @"$work/auth-header" "$url")"
rm -f "$work/auth-header"
rate="$(grep -i '^x-rate-limit:' "$work/headers.txt" | cut -d' ' -f2- | tr -d '\r' || true)"
rm -f "$work/headers.txt"

python3 -I Tools/redact-fixture.py "$work/body.json" "$work/redacted.json" \
    || fail_clean $? "Tools/redact-fixture.py refused the response"
mapped="$(python3 -I Tools/anonymize-fixture.py "$work/redacted.json" "$work/fixture.json" --path "$endpoint" --query "$query")" \
    || fail_clean $? "Tools/anonymize-fixture.py refused the response"
mapped_path="$(printf '%s' "$mapped" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["path"])')"
mapped_query="$(printf '%s' "$mapped" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["query"])')"
write_meta "$work/fixture.meta.json" "$mapped_path" "$mapped_query"

# Independent final check over both files: no token, no key, no original id from the response or the path.
python3 -I - "$work/body.json" "$endpoint" "$work/fixture.json" "$work/fixture.meta.json" <<'PY' \
    || fail_clean $? "final check failed"
import json, re, sys
raw_path, endpoint, *outputs = sys.argv[1:]
code = re.compile(r"[A-Z]{3}")
def keep(value, sibling_type):
    return sibling_type == "territories" or code.fullmatch(value) is not None or value.startswith("${")
ids = set()
def walk(node):
    if isinstance(node, dict):
        value = node.get("id")
        if isinstance(value, str) and value and not keep(value, node.get("type")):
            ids.add(value)
        for child in node.values():
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)
walk(json.load(open(raw_path, encoding="utf-8")))
parts = [part for part in endpoint.split("/") if part]
ids |= {part for index, part in enumerate(parts) if index >= 2 and index % 2 == 0 and not keep(part, None)}
text = "".join(open(path, encoding="utf-8").read() for path in outputs)
if "Bearer " in text or "-----BEGIN" in text:
    print("secret material found in the output", file=sys.stderr)
    sys.exit(3)
text = re.sub(r"syn-[0-9a-f]{10}", "", text)
survivors = [value for value in ids if value in text]
if survivors:
    print(f"{len(survivors)} original id(s) still present in the output", file=sys.stderr)
    sys.exit(4)
PY

mv "$work/fixture.json" "$out.json"
mv "$work/fixture.meta.json" "$out.meta.json"
# Raw copy for chaining ids and local checks; build/ is gitignored, so it never reaches the repository.
cp "$work/body.json" "$raw.json"
write_meta "$raw.meta.json" "$endpoint" "$query"
echo "HTTP $status -> $out.json (X-Rate-Limit: ${rate:-none}; raw copy only in $raw.json)"
