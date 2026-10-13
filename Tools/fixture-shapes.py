#!/usr/bin/env python3
"""Compares the JSON:API shape of a hand-made fixture with a recorded one (spike SC/S0).

Usage: python3 -I Tools/fixture-shapes.py <hand-made.json> <recorded.json>
For every resource type in either file it prints attribute and relationship names that exist only on one side.
Values are ignored; only the shape matters. Exit code 1 when the shapes differ.
"""
import json
import sys


def shapes(path: str) -> dict[str, tuple[set[str], set[str]]]:
    document = json.load(open(path, encoding="utf-8"))
    resources = []
    data = document.get("data")
    resources += data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
    resources += document.get("included", [])
    result: dict[str, tuple[set[str], set[str]]] = {}
    for resource in resources:
        attributes, relationships = result.setdefault(resource["type"], (set(), set()))
        attributes.update(resource.get("attributes", {}).keys())
        relationships.update(resource.get("relationships", {}).keys())
    return result


def main() -> int:
    hand, recorded = shapes(sys.argv[1]), shapes(sys.argv[2])
    differ = False
    for resource_type in sorted(set(hand) | set(recorded)):
        hand_attributes, hand_relationships = hand.get(resource_type, (set(), set()))
        rec_attributes, rec_relationships = recorded.get(resource_type, (set(), set()))
        lines = []
        if resource_type not in hand:
            lines.append("  type only in recorded")
        if resource_type not in recorded:
            lines.append("  type only in hand-made")
        for label, only in (("attributes only in hand-made", hand_attributes - rec_attributes),
                            ("attributes only in recorded", rec_attributes - hand_attributes),
                            ("relationships only in hand-made", hand_relationships - rec_relationships),
                            ("relationships only in recorded", rec_relationships - hand_relationships)):
            if only:
                lines.append(f"  {label}: {', '.join(sorted(only))}")
        print(f"{resource_type}: {'same shape' if not lines else 'DIFFERENT'}")
        for line in lines:
            print(line)
        differ = differ or bool(lines)
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
