#!/usr/bin/env python3
"""Spike S0: counts planType / targetSubscriptionPlanType values in recorded fixtures.

Usage: python3 -I Tools/plan-type-census.py
Reads Packages/PurserCore/Tests/Fixtures/asc/recorded/*.json and prints, per resource type,
how many rows carry each value, including "<missing>" (attribute absent) and "<null>".
"""
import collections
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECORDED = ROOT / "Packages" / "PurserCore" / "Tests" / "Fixtures" / "asc" / "recorded"
FIELDS = {
    "subscriptionPrices": "planType",
    "subscriptionIntroductoryOffers": "targetSubscriptionPlanType",
    "subscriptionPromotionalOffers": "targetSubscriptionPlanType",
    "subscriptionPlanAvailabilities": "planType",
}


def main() -> int:
    counts: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    files = sorted(p for p in RECORDED.glob("*.json") if not p.name.endswith(".meta.json"))
    if not files:
        print(f"no recorded fixtures in {RECORDED}")
        return 1
    for path in files:
        document = json.loads(path.read_text(encoding="utf-8"))
        data = document.get("data")
        resources = data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
        for resource in resources:
            field = FIELDS.get(resource.get("type"))
            if not field:
                continue
            attributes = resource.get("attributes", {})
            if field not in attributes:
                value = "<missing>"
            elif attributes[field] is None:
                value = "<null>"
            else:
                value = attributes[field]
            counts[f"{resource['type']}.{field}"][value] += 1
    for key in sorted(counts):
        print(key)
        for value, number in counts[key].most_common():
            print(f"  {value}: {number}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
