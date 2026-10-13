# Spike SC: hand-written Codable client against OpenAPI 4.5.1

| Field | Value |
|---|---|
| Date (UTC) | 2026-10-10 (part 1); part 2 is added by task 0.17 |
| Done by | project owner |
| Purser commit | the commit of task 0.3 |
| Workspace | none (part 1 is an offline check); part 2 Juice |
| Products | part 2: the "Purser Spike" group |
| Key | part 2: team key, key id from the Juice workspace |

## Question

Is a hand-written Codable client enough for the ~20 operations Purser uses (spec §4 ASCClient, OQ2)?
Specifically: (1) does every method and path of the path list ([asc-api-paths.md](../research/asc-api-paths.md)) exist in the OpenAPI 4.5.1 specification and do the schemas carry the
attributes `LiveASCClient` reads; (2) do real Juice responses decode without an error (a full sync of the whole Juice catalog
in spike S0 ends `complete` and the redacted, anonymized responses of the "Purser Spike" group recorded in S0 pass
`RecordedFixturesTests`). A generator from the specification is used only if one of the answers is "no".

## Procedure

1. `make check-endpoints` (the script `Tools/check-asc-endpoints.py` downloads the specification zip to `Tools/.cache/`,
   finds `openapi.oas.json` in it and compares every `METHOD /path` line of K5 and the list of DTO attributes).
2. Negative check of the script: a temporary file with the K5 line `GET /v1/doesNotExist` must end with `MISSING` and exit code 1.
3. (task 0.17) `swift test --package-path Packages/PurserCore --filter '^ASCClientTests\.RecordedFixturesTests'`
   over the responses recorded in spike S0.

## Observations

Part 1 (task 0.3), zip `app-store-connect-openapi-specification.zip`, Last-Modified 2026-10-06, `info.version` 4.5.1:

| Check | Result |
|---|---|
| K5 paths (27 method + path combinations) | 27 OK, 0 MISSING |
| `GET /v1/inAppPurchasePriceSchedules/{id}/automaticPrices` | exists; only an observation in spike S10 and rule L2, the sync does not read it in v1 |
| DTO attributes (35) | 35 OK, 0 MISSING |
| `GET /v1/subscriptions/{id}/planAvailabilities` | exists; `monthlyPlanAvailable` is read from it (the fallback rule of K5 is not needed) |
| `SubscriptionPricePoint` | has no `planType` attribute; a price point's plan type = the value of `filter[planType]` in the request |
| Negative check | `MISSING GET /v1/doesNotExist`, exit 1 |

Part 2 (task 0.17): the table "recorded response → decoding result" from spike S0.

## Result

Part 1: every path and attribute that M0 to M4 use exists in specification 4.5.1; the hand-written client stays.
Part 2 is added by task 0.17.

## Effect on the code

- `AppleConstants`: no change.
- Contracts: no change (K5 matches the specification).
- Tests: `make check-endpoints` is part of the milestone checks; `RecordedFixturesTests` pins the recorded shapes.

## Fixtures

Part 1 none. Part 2: the files from spike S0 in `Packages/PurserCore/Tests/Fixtures/asc/recorded/` (only "Purser Spike" and territories,
redacted and anonymized; synthetic ids `syn-…` and amounts).

## Open points

Rule for a mismatch: a path reported as `MISSING` is first fixed in [asc-api-paths.md](../research/asc-api-paths.md) (a `docs:` commit),
and only then in `ASCPath` and in the tests.
