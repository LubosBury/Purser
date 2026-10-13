#!/usr/bin/env python3
"""Copies an ASC JSON response into a fixture with identifying strings replaced.

Usage: python3 -I Tools/redact-fixture.py <input.json> <output.json>
Ids, prices, dates, states and structure stay; names, product ids, bundle id, SKU and offer codes become
stable stand-in values ("redacted-productId-1"). Refuses input that contains a bearer token or a PEM key.
"""
import json
import sys

REDACT = {"bundleId", "sku", "name", "productId", "referenceName", "offerCode", "reviewNote", "description"}
FORBIDDEN = ("Bearer ", "-----BEGIN")


def main() -> int:
    source, target = sys.argv[1], sys.argv[2]
    raw = open(source, encoding="utf-8").read()
    if any(marker in raw for marker in FORBIDDEN):
        print("refusing: input contains a token or a key", file=sys.stderr)
        return 3
    document = json.loads(raw)
    mapping: dict[tuple[str, str], str] = {}

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in REDACT and isinstance(value, str):
                    slot = (key, value)
                    if slot not in mapping:
                        mapping[slot] = f"redacted-{key}-{sum(1 for k, _ in mapping if k == key) + 1}"
                    node[key] = mapping[slot]
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(document)
    if isinstance(document, dict):
        document["x-purser-fixture"] = "recorded by Tools/record-fixture.sh; identifying strings redacted"
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
