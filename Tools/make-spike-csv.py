#!/usr/bin/env python3
"""Builds the synthetic M3 spike price table (CSV) for Purser's CSV importer.

Inputs are ASC JSON:API documents recorded with Tools/record-fixture.sh:
  territories:  GET /v1/territories?limit=200
  prices (x3):  GET /v1/subscriptions/{id}/prices?include=subscriptionPricePoint,territory&limit=200
                (pass every page of one product after its flag)
and the importer's territory name map in its bundled format (contract K7):
  {"version": 1, "storefronts": {"<ASC storefront name>": "<CODE>"}, "aliases": {"<alias>": "<CODE>"}}.

Output: row 1 = header, data from row 2, one row per territory sorted by code.
  A Country | B Currency | C SpikeYearlyA regular (check) | D SpikeYearlyA intro PUF 1Y |
  E SpikeYearlyB regular (check) | F SpikeYearlyB intro PUF 1Y | G SpikeYearlyB free trial days |
  H SpikeMonthly new regular
Derived values are synthetic: fixed factors applied to the current regular prices of the spike products.
"""
import argparse
import csv
import datetime as dt
import json
import os
import sys
from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP

INTRO_FACTOR = Decimal("0.50")
MONTHLY_INCREASE_FACTOR = Decimal("1.10")
TRIAL_DAYS_CYCLE = (7, 14, 30)
CENT = Decimal("0.01")
HEADER = [
    "Country", "Currency", "SpikeYearlyA regular (check)", "SpikeYearlyA intro PUF 1Y",
    "SpikeYearlyB regular (check)", "SpikeYearlyB intro PUF 1Y", "SpikeYearlyB free trial days",
    "SpikeMonthly new regular",
]


class SpikeCSVError(Exception):
    pass


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def territories_from(doc):
    """{code: currency} from a /v1/territories document."""
    result = {}
    for item in doc.get("data", []):
        if item.get("type") != "territories":
            continue
        currency = (item.get("attributes") or {}).get("currency")
        if not currency:
            raise SpikeCSVError(f"territory {item.get('id')} has no currency")
        result[item["id"].upper()] = currency.upper()
    if not result:
        raise SpikeCSVError("territories document contains no territories")
    return result


def names_by_code(name_map):
    """{code: name} from the importer's name map (K7 format).

    A storefront name wins over an alias; among several names of one code the alphabetically first wins.
    Every name in the map resolves in Purser's importer, so the CSV imports with the bundled map.
    """
    if not isinstance(name_map, dict) or not isinstance(name_map.get("storefronts"), dict):
        raise SpikeCSVError('territory name map must be {"version", "storefronts", "aliases"} (contract K7)')
    aliases = name_map.get("aliases") or {}
    if not isinstance(aliases, dict):
        raise SpikeCSVError("territory name map: 'aliases' must be an object")
    result = {}
    for group in (name_map["storefronts"], aliases):
        by_code = {}
        for name, code in group.items():
            if not isinstance(code, str):
                raise SpikeCSVError(f"territory name map: the code of {name!r} must be a string")
            by_code.setdefault(code.upper(), []).append(name)
        for code, names in by_code.items():
            result.setdefault(code, sorted(names)[0])
    return result


def current_regular_prices(docs, today):
    """{territory: Decimal}: the UPFRONT row with the latest startDate <= today (null = oldest);
    on equal dates a non-preserved row wins. MONTHLY rows are ignored."""
    points = {}
    rows = []
    for doc in docs:
        for item in doc.get("included", []) or []:
            if item.get("type") == "subscriptionPricePoints":
                points[item["id"]] = Decimal(str(item["attributes"]["customerPrice"]))
        rows.extend(item for item in doc.get("data", []) if item.get("type") == "subscriptionPrices")
    best = {}
    for row in rows:
        attributes = row.get("attributes") or {}
        if attributes.get("planType") not in (None, "UPFRONT"):
            continue
        start = attributes.get("startDate")
        if start is not None and start > today:
            continue
        relationships = row.get("relationships") or {}
        territory = relationships["territory"]["data"]["id"].upper()
        point_id = relationships["subscriptionPricePoint"]["data"]["id"]
        if point_id not in points:
            raise SpikeCSVError(f"price point {point_id} is missing from 'included'")
        key = (start or "0000-00-00", 0 if attributes.get("preserved") else 1)
        if territory not in best or key > best[territory][0]:
            best[territory] = (key, points[point_id])
    return {territory: price for territory, (_, price) in best.items()}


def money(value):
    return str(value.quantize(CENT, rounding=ROUND_HALF_UP))


def intro_value(regular):
    """Half of the regular price, rounded DOWN to cents so that rule I5 never has to limit it."""
    return str((regular * INTRO_FACTOR).quantize(CENT, rounding=ROUND_DOWN))


def build_rows(territories, names, prices_a, prices_b, prices_monthly):
    rows, missing = [], []
    for index, code in enumerate(sorted(territories)):
        absent = [label for label, table in (("name", names), ("SpikeYearlyA", prices_a),
                                             ("SpikeYearlyB", prices_b), ("SpikeMonthly", prices_monthly))
                  if code not in table]
        if absent:
            missing.append(f"{code}: {', '.join(absent)}")
            continue
        a, b, m = prices_a[code], prices_b[code], prices_monthly[code]
        rows.append([
            names[code], territories[code],
            money(a), intro_value(a),
            money(b), intro_value(b),
            str(TRIAL_DAYS_CYCLE[index % len(TRIAL_DAYS_CYCLE)]),
            money(m * MONTHLY_INCREASE_FACTOR),
        ])
    if missing:
        raise SpikeCSVError("missing data for territories:\n  " + "\n  ".join(missing))
    return rows


def write_csv(rows, out):
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Synthetic M3 spike price table for Purser's CSV import.")
    parser.add_argument("--territories", required=True)
    parser.add_argument("--names", required=True)
    parser.add_argument("--prices-a", required=True, nargs="+")
    parser.add_argument("--prices-b", required=True, nargs="+")
    parser.add_argument("--prices-monthly", required=True, nargs="+")
    parser.add_argument("--today", default=dt.datetime.now(dt.timezone.utc).date().isoformat())
    parser.add_argument("--out", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        dt.date.fromisoformat(args.today)
        territories = territories_from(load_json(args.territories))
        names = names_by_code(load_json(args.names))
        prices = [current_regular_prices([load_json(path) for path in paths], args.today)
                  for paths in (args.prices_a, args.prices_b, args.prices_monthly)]
        rows = build_rows(territories, names, *prices)
    except (SpikeCSVError, ValueError, KeyError, OSError) as error:
        print(f"make-spike-csv: {error}", file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="") as out:
        write_csv(rows, out)
    print(f"make-spike-csv: wrote {len(rows)} territories to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
