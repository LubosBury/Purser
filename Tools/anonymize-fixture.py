#!/usr/bin/env python3
"""Replaces ASC ids and amounts of an already redacted fixture with synthetic values (M0 Task 0.16).

Usage: python3 -I Tools/anonymize-fixture.py <redacted-in.json> <out.json> [--path /v1/...] [--query 'a=b&limit=200']

The input is the output of Tools/redact-fixture.py (names, product ids, bundle id, SKU and offer codes already
replaced). This tool is the extra anonymization the project allows on top of it:
- Every value of an "id" key becomes "syn-" + the first 10 hex digits of HMAC-SHA256(local salt, id). The same id
  maps to the same value in every file recorded on this Mac, so references between fixtures stay consistent.
  Kept unchanged: ids of identifiers whose "type" is "territories", any 3-letter upper-case code and local ids "${...}".
- The ids in --path (the segment after each collection name, e.g. 123 in /v1/subscriptions/123/prices) are mapped
  the same way, so the app id in links such as /v1/apps/<id>/subscriptionGroups disappears too.
- Every occurrence of a mapped id inside any string value (links.self, links.next, related, ...) is replaced.
- customerPrice, proceeds and proceedsYear2 get values from a synthetic ladder (1.11, 2.11, 3.11, ...) that keeps the
  order and the equality of the original non-zero amounts within this file; zero stays zero.
The salt lives in build/fixtures-local/.anon-salt (gitignored; created on first use, mode 600).
Prints one JSON object {"amounts": m, "ids": n, "path": <mapped path>, "query": <mapped query>} on stdout.
Exit codes: 2 usage, 3 token or key in the input, 4 an original id is still present (nothing is written).
"""
import argparse
import hashlib
import hmac
import json
import os
import pathlib
import re
import secrets
import sys
from decimal import Decimal, InvalidOperation

ROOT = pathlib.Path(__file__).resolve().parent.parent
SALT_PATH = ROOT / "build" / "fixtures-local" / ".anon-salt"
AMOUNT_KEYS = {"customerPrice", "proceeds", "proceedsYear2"}
FORBIDDEN = ("Bearer ", "-----BEGIN")
SYNTHETIC_ID = re.compile(r"syn-[0-9a-f]{10}")
TERRITORY_CODE = re.compile(r"[A-Z]{3}")


def load_salt() -> bytes:
    if not SALT_PATH.exists():
        SALT_PATH.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(SALT_PATH.parent, 0o700)
        SALT_PATH.write_text(secrets.token_hex(32) + "\n", encoding="utf-8")
        os.chmod(SALT_PATH, 0o600)
    return bytes.fromhex(SALT_PATH.read_text(encoding="utf-8").strip())


def kept(value: str, sibling_type) -> bool:
    return sibling_type == "territories" or TERRITORY_CODE.fullmatch(value) is not None or value.startswith("${")


def collect_ids(node, found: set) -> None:
    if isinstance(node, dict):
        value = node.get("id")
        if isinstance(value, str) and value and not kept(value, node.get("type")):
            found.add(value)
        for child in node.values():
            collect_ids(child, found)
    elif isinstance(node, list):
        for child in node:
            collect_ids(child, found)


def path_ids(path: str) -> set:
    """'/v1/subscriptions/123/prices' -> {'123'}: every segment that follows a collection name."""
    parts = [part for part in path.split("/") if part]
    return {part for index, part in enumerate(parts) if index >= 2 and index % 2 == 0 and not kept(part, None)}


def amount(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return None
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        return None
    return number if number.is_finite() else None


def collect_amounts(node, found: set) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            number = amount(value) if key in AMOUNT_KEYS else None
            if number is not None and number != 0:
                found.add(number)
            else:
                collect_amounts(value, found)
    elif isinstance(node, list):
        for child in node:
            collect_amounts(child, found)


def rewrite(node, ladder: dict, pattern, mapping: dict):
    if isinstance(node, dict):
        result = {}
        for key, value in node.items():
            number = amount(value) if key in AMOUNT_KEYS else None
            if number is not None and number != 0:
                synthetic = ladder[number]
                result[key] = str(synthetic) if isinstance(value, str) else float(synthetic)
            else:
                result[key] = rewrite(value, ladder, pattern, mapping)
        return result
    if isinstance(node, list):
        return [rewrite(child, ladder, pattern, mapping) for child in node]
    if isinstance(node, str) and pattern is not None:
        return pattern.sub(lambda match: mapping[match.group(0)], node)
    return node


def main() -> int:
    parser = argparse.ArgumentParser(description="Anonymize ids and amounts of a redacted ASC fixture.")
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--path", default="")
    parser.add_argument("--query", default="")
    args = parser.parse_args()

    raw = pathlib.Path(args.source).read_text(encoding="utf-8")
    if any(marker in raw for marker in FORBIDDEN):
        print("refusing: input contains a token or a key", file=sys.stderr)
        return 3
    document = json.loads(raw)

    ids: set = set()
    collect_ids(document, ids)
    ids |= path_ids(args.path)
    salt = load_salt()
    mapping = {value: "syn-" + hmac.new(salt, value.encode("utf-8"), hashlib.sha256).hexdigest()[:10] for value in ids}
    # Longest first, one pass: "promo-1-usa" is replaced as a whole before "promo-1" could match inside it.
    pattern = re.compile("|".join(re.escape(value) for value in sorted(ids, key=len, reverse=True))) if ids else None

    amounts: set = set()
    collect_amounts(document, amounts)
    ladder = {value: Decimal(index + 1) + Decimal("0.11") for index, value in enumerate(sorted(amounts))}

    result = rewrite(document, ladder, pattern, mapping)
    if isinstance(result, dict):
        result["x-purser-fixture"] = ("recorded by Tools/record-fixture.sh; identifying strings redacted, "
                                      "ids and amounts made synthetic by Tools/anonymize-fixture.py")
    mapped_path = pattern.sub(lambda match: mapping[match.group(0)], args.path) if pattern else args.path
    mapped_query = pattern.sub(lambda match: mapping[match.group(0)], args.query) if pattern else args.query

    text = json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    leftover = SYNTHETIC_ID.sub("", text + mapped_path + "\n" + mapped_query)
    survivors = [value for value in ids if value in leftover]
    if survivors:
        print(f"refusing: {len(survivors)} original id(s) still present after anonymization", file=sys.stderr)
        return 4
    pathlib.Path(args.target).write_text(text, encoding="utf-8")
    print(json.dumps({"amounts": len(ladder), "ids": len(ids), "path": mapped_path, "query": mapped_query}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
