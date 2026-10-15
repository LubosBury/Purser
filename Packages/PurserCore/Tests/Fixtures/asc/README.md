# App Store Connect response fixtures

The files in this folder are **hand-written** from the OpenAPI 4.5.1 schemas for the synthetic app "Fruit Journal"
(app id `6400000001`, subscriptions `6500000001` and `6500000002`, IAP `6600000001`). They describe no real app.
Every file carries the key `"x-purser-fixture"`, which the JSON:API decoder ignores.

| File | Endpoint (K5) | State |
|---|---|---|
| `app.json` | `GET /v1/apps/{id}` | hand-written, replace with the shape from S0 |
| `territories.json` | `GET /v1/territories` | hand-written, extended to 175 territories in M1 (the currencies are a manual estimate, not recorded data), replace with the version recorded in S0 |
| `subscriptionGroups.json` | `GET /v1/apps/{id}/subscriptionGroups` | hand-written, replace with the shape from S0 |
| `subscriptions.json` | `GET /v1/subscriptionGroups/{id}/subscriptions` | hand-written, replace with the shape from S0 |
| `subscriptionAvailability-<id>.json` | `GET /v1/subscriptions/{id}/subscriptionAvailability` | hand-written, replace with the shape from S0 |
| `availableTerritories-<id>.json` | `GET /v1/subscriptionAvailabilities/{id}/availableTerritories` | hand-written, replace with the shape from S0 |
| `planAvailabilities-<id>.json` | `GET /v1/subscriptions/{id}/planAvailabilities` | hand-written, replace with the shape from S0 |
| `subscriptionPrices.json` | `GET /v1/subscriptions/{id}/prices` | hand-written, replace with the shape from S0 |
| `introductoryOffers.json` | `GET /v1/subscriptions/{id}/introductoryOffers` | hand-written, replace with the shape from S0 |
| `promotionalOffers.json` | `GET /v1/subscriptions/{id}/promotionalOffers` | hand-written, replace with the shape from S0 |
| `promotionalOfferPrices.json` | `GET /v1/subscriptionPromotionalOffers/{id}/prices` | hand-written, replace with the shape from S0 |
| `subscriptionPricePoints.json` | `GET /v1/subscriptions/{id}/pricePoints` | hand-written, replace with the shape from S0 |
| `inAppPurchasesV2.json` | `GET /v1/apps/{id}/inAppPurchasesV2` | hand-written, replace with the shape from S0 |
| `iapPriceSchedule.json` | `GET /v2/inAppPurchases/{id}/iapPriceSchedule` | hand-written, replace with the shape from S0 |
| `iapBaseTerritory.json` | `GET /v1/inAppPurchasePriceSchedules/{id}/baseTerritory` | hand-written, replace with the shape from S0 |
| `iapManualPrices.json` | `GET /v1/inAppPurchasePriceSchedules/{id}/manualPrices` | hand-written, replace with the shape from S0 |
| `iapPricePoints.json` | `GET /v2/inAppPurchases/{id}/pricePoints` | hand-written, replace with the shape from S0 |
| `subscriptionVersions-6500000001.json` | `GET /v1/subscriptions/{id}/versions` with `include=localizations` | hand-written in L1 (versions 1 retired, 2 live, 3 editable), replace with a recorded response |
| `inAppPurchaseVersions-6600000001.json` | `GET /v2/inAppPurchases/{id}/versions` with `include=localizations` | hand-written in L1, replace with a recorded response |
| `subscriptionGroupVersions-7000000001.json` | `GET /v1/subscriptionGroups/{id}/versions` with `include=localizations` | hand-written in L1 (version 2 waiting for review), replace with a recorded response |

**Recorded responses** (spike S0) are in `recorded/` (recorded by `Tools/record-fixture.sh asc/recorded/<name> <path> [query]`):
`<name>.json` is the response body after redaction (`Tools/redact-fixture.py` replaces names, product ids, bundle ids, SKUs, reference
names, offer codes, review notes, descriptions and custom app names) and anonymization (`Tools/anonymize-fixture.py`: every id except territory codes is a synthetic `syn-…`,
the same id has the same replacement in every file; `customerPrice`, `proceeds` and `proceedsYear2` come from the synthetic
ladder `1.11, 2.11, …` with the order preserved), `<name>.meta.json` holds the path (with synthetic ids), the query, the HTTP status
and the `X-Rate-Limit` header. Only the products of the "Purser Spike" group and the territory list are recorded, never production subscriptions.
The `Authorization` header is never stored; `Tools/record-fixture.sh` writes nothing if the output would contain `Bearer `,
`-----BEGIN` or any original id. Raw responses stay only in the gitignored `build/fixtures-local/`.

When the shape of a recorded response differs from the hand-written one (`python3 -I Tools/fixture-shapes.py <hand-written> recorded/<recorded>`),
change the hand-written fixture to the same shape with synthetic values and change the state in the table to "shape verified in S0 (<date>)".
