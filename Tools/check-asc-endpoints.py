#!/usr/bin/env python3
"""Checks every METHOD + path of docs/research/asc-api-paths.md against Apple's App Store Connect OpenAPI spec.

Run with `python3 -I Tools/check-asc-endpoints.py` (or `make check-endpoints`) from the repository root.
The spec zip is cached in Tools/.cache/. Use --refresh to download it again.
Prints OK/MISSING per endpoint and per DTO attribute; exits 1 when anything is missing.
A MISSING endpoint is fixed first in docs/research/asc-api-paths.md, then in the code.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import zipfile

SPEC_URL = "https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip"
PINNED_VERSION = "4.5.1"
ROOT = pathlib.Path(__file__).resolve().parent.parent
PATHS_DOC = ROOT / "docs" / "research" / "asc-api-paths.md"
CACHE = ROOT / "Tools" / ".cache"
ZIP_PATH = CACHE / "app-store-connect-openapi-specification.zip"

# Attributes LiveASCClient reads (Sources/ASCClient/LiveASCClient+Reading.swift, LiveASCClient+Metadata.swift,
# LiveASCClient+ProductAssets.swift).
# Schema name -> attribute names.
ATTRIBUTES = {
    "App": ["bundleId", "name"],
    "Territory": ["currency"],
    "SubscriptionGroup": ["referenceName"],
    "Subscription": ["name", "productId", "state", "subscriptionPeriod", "familySharable", "reviewNote", "groupLevel"],
    "SubscriptionPlanAvailability": ["planType"],
    "SubscriptionPrice": ["startDate", "preserved", "planType"],
    "SubscriptionPricePoint": ["customerPrice", "proceeds"],
    "SubscriptionIntroductoryOffer": ["startDate", "endDate", "duration", "offerMode", "numberOfPeriods", "targetSubscriptionPlanType"],
    "SubscriptionPromotionalOffer": ["duration", "name", "numberOfPeriods", "offerCode", "offerMode", "targetSubscriptionPlanType"],
    "InAppPurchaseV2": ["name", "productId", "inAppPurchaseType", "state", "familySharable", "reviewNote"],
    "InAppPurchasePrice": ["startDate", "endDate", "manual"],
    "InAppPurchasePricePoint": ["customerPrice", "proceeds"],
    "SubscriptionAvailability": ["availableInNewTerritories"],
    "InAppPurchaseAvailability": ["availableInNewTerritories"],
    "SubscriptionAppStoreReviewScreenshot": ["fileName", "fileSize", "imageAsset", "assetDeliveryState", "uploadOperations"],
    "InAppPurchaseAppStoreReviewScreenshot": ["fileName", "fileSize", "imageAsset", "assetDeliveryState", "uploadOperations"],
    "SubscriptionVersion": ["version", "state"],
    "InAppPurchaseVersion": ["version", "state"],
    "SubscriptionGroupVersion": ["version", "state"],
    "SubscriptionLocalizationV2": ["name", "locale", "description"],
    "InAppPurchaseLocalizationV2": ["name", "locale", "description"],
    "SubscriptionGroupLocalizationV2": ["name", "locale", "customAppName"],
}

ENDPOINT_PATTERN = re.compile(r"`(GET|POST|PATCH|DELETE) (/v[0-9]+/[^`\s]+)`")


def documented_endpoints(text: str) -> list[tuple[str, str]]:
    seen: list[tuple[str, str]] = []
    for method, path in ENDPOINT_PATTERN.findall(text):
        if (method, path) not in seen:
            seen.append((method, path))
    return seen


def load_spec(refresh: bool) -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    if refresh or not ZIP_PATH.exists():
        print(f"Downloading {SPEC_URL}")
        # curl uses the macOS trust store; python.org builds of urllib often lack root certificates.
        partial = ZIP_PATH.with_suffix(".part")
        subprocess.run(["curl", "-fsSL", "--max-time", "120", "-o", str(partial), SPEC_URL], check=True)
        partial.replace(ZIP_PATH)
    with zipfile.ZipFile(ZIP_PATH) as archive:
        names = [n for n in archive.namelist() if n.endswith(".json") and "__MACOSX" not in n]
        if not names:
            sys.exit("No JSON document inside the spec zip")
        return json.loads(archive.read(names[0]))


def resolve(spec: dict, schema: dict) -> dict:
    while isinstance(schema, dict) and "$ref" in schema:
        schema = spec["components"]["schemas"][schema["$ref"].rsplit("/", 1)[-1]]
    return schema


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true", help="download the spec zip again")
    parser.add_argument("--paths", type=pathlib.Path, default=PATHS_DOC, help="markdown file listing the endpoints")
    args = parser.parse_args()

    spec = load_spec(args.refresh)
    version = spec.get("info", {}).get("version", "?")
    print(f"OpenAPI spec version {version} (the path list is pinned to {PINNED_VERSION})")
    if version != PINNED_VERSION:
        print(f"NOTE: spec version differs from {PINNED_VERSION}; read Apple's release notes before changing the path list.")

    missing = 0
    paths = spec["paths"]
    for method, path in documented_endpoints(args.paths.read_text(encoding="utf-8")):
        ok = path in paths and method.lower() in paths[path]
        missing += 0 if ok else 1
        print(f"{'OK     ' if ok else 'MISSING'} {method} {path}")

    schemas = spec["components"]["schemas"]
    for schema_name, attributes in ATTRIBUTES.items():
        schema = schemas.get(schema_name)
        present = set(resolve(spec, schema.get("properties", {}).get("attributes", {})).get("properties", {})) if schema else set()
        for attribute in attributes:
            ok = attribute in present
            missing += 0 if ok else 1
            print(f"{'OK     ' if ok else 'MISSING'} attribute {schema_name}.{attribute}")

    print(f"{missing} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
