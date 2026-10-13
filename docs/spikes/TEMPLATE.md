# Spike <ID>: <name>

| Field | Value |
|---|---|
| Date (UTC) | |
| Done by | |
| Purser commit | output of `git rev-parse --short HEAD` |
| Workspace | Juice (app id from the workspace settings) |
| Products | the "Purser Spike" group: SpikeYearlyA, SpikeYearlyB, SpikeMonthly, PurserSpikeLifetime (asc id) |
| Key | team / individual, key id (never the .p8 content) |

## Question

What the spike verifies and which rule, constant or task it unblocks (a reference to spec §9 and the facts `[Tx-yy]`).

## Procedure

Numbered steps exactly as they happened: clicks in the ASC UI, terminal commands, requests (method, path with ids written as variables, e.g. `$SUB_A`, query; never a token or Juice's real ids and amounts).

## Observations

What actually happened: HTTP statuses, `X-Rate-Limit`, attribute values (without real ids and amounts; amounts only relatively, e.g. "lower than before the PATCH"), request counts, times, ASC error codes.

## Result

One to three sentences that answer the question.

## Effect on the code

- `AppleConstants`: `<name>`: old value → new value, or "no change".
- Module contracts: which one changed (and the commit), or "no change".
- The tests that pin the result.

## Fixtures

Files under `Packages/PurserCore/Tests/Fixtures/` from this spike (M0 `asc/recorded/`, spikes M2-M4 `spikes/<ID>/`): always after `Tools/redact-fixture.py` and `Tools/anonymize-fixture.py` (synthetic ids and amounts), without Authorization and without raw copies from `build/fixtures-local/`. Juice's real ids, amounts and names do not belong here, nor in the text of the record.

## Open points

What the spike did not answer and in which milestone or spike it will be resolved.
