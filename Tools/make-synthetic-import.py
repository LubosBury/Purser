#!/usr/bin/env python3
"""Generates Packages/PurserCore/Tests/Fixtures/import/synthetic-175.csv.

Synthetic data only: three invented yearly subscriptions (Alpha, Beta, Gamma), one row per ASC storefront.
Names come from the bundled territory-names.json, currencies from the recorded ASC territories fixture.
Prices sit on a synthetic ladder k + 0.99 (k = 0..99); intro = highest ladder point <= 0.8 x regular.
"""
import csv
import json
import pathlib
from decimal import Decimal, ROUND_FLOOR

root = pathlib.Path(__file__).resolve().parent.parent / "Packages" / "PurserCore"
names = json.loads((root / "Sources/Importer/Resources/territory-names.json").read_text(encoding="utf-8"))["storefronts"]
asc = json.loads((root / "Tests/Fixtures/asc/territories.json").read_text(encoding="utf-8"))
currency = {r["id"]: r["attributes"]["currency"] for r in asc["data"]}


def intro(regular: Decimal) -> Decimal:
    cap = regular * Decimal("0.8")
    k = (cap - Decimal("0.99")).to_integral_value(rounding=ROUND_FLOOR)
    return k + Decimal("0.99")


trials = ["7", "ONE_MONTH", "14"]
out = root / "Tests/Fixtures/import/synthetic-175.csv"
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", encoding="utf-8", newline="") as f:
    w = csv.writer(f, lineterminator="\r\n")
    w.writerow(["Country", "Currency", "Alpha yearly", "Alpha intro -20%", "Beta yearly", "Beta intro -20%",
                "Gamma yearly", "Gamma intro -20%", "Alpha trial"])
    for i, (name, code) in enumerate(sorted(names.items(), key=lambda kv: kv[0])):
        a = Decimal(29 + i % 20) + Decimal("0.99")
        b = Decimal(49 + i % 30) + Decimal("0.99")
        g = Decimal(9 + i % 10) + Decimal("0.99")
        w.writerow([name, currency[code], a, intro(a), b, intro(b), g, intro(g), trials[i % 3]])
print(f"wrote {out}")
