# Spike <ID>: <name>

| Field | Value |
|---|---|
| Date (UTC) | YYYY-MM-DD, start HH:MM, end HH:MM |
| Done by | owner name (the same as the actor in the audit) |
| Purser commit | output of `git rev-parse --short HEAD` |
| Workspace | Juice (app id from the workspace settings), production = no |
| Products and their state in ASC | the "Purser Spike" group: SpikeYearlyA (<state>), SpikeYearlyB (<state>), SpikeYearlyC (<state>), SpikeMonthly (<state>), PurserSpikeLifetime (<state>) |
| Key | team / individual, key id (never the .p8 content) |
| Write path | the DEBUG window "Spike console" → `SpikeProbe`; audit `httpSent`/`httpReceived` with refs `spike=<ID>`, `step=<ID>-<n>` |

## Questions

| # | Question | Facts / rule |
|---|---|---|
| Q1 | … | [T…], rule … |

## Procedure and observations

Each row = one request in the console (step `<ID>-<n>`). The time and status are also in History (the `httpSent`/`httpReceived` events with the same `step`); an `httpSent` without an `httpReceived` means a crash or a timeout and the request is verified by reading.

| Step | Request (method, path, query, template, variables) | Time UTC | Status | Observation (code, detail, returned attributes) | Fixture |
|---|---|---|---|---|---|
| <ID>-1 | … | … | … | … | spikes/<ID>/… |

## Conclusions

| Question | Answer | Confidence (H/M/L) |
|---|---|---|
| Q1 | … | H |

## Effect on the code

- AppleConstants: `<constant>` <old value> → <new value>, or "no change" with the reason
- FakeASC: <changed semantics and commit>, or "confirmed without change"
- ErrorClassifier / Reconciler / other: <change and commit>
- Contracts: <required change of a module contract>, or "none"

## Fixtures

Files in `Packages/PurserCore/Tests/Fixtures/spikes/<ID>/` (saved with the "Save response…" button and redacted with `python3 -I Tools/redact-fixture.py`).

## Cleanup

- Deleted: <rows, offers, console steps>
- State of the "Purser Spike" group after the spike: <what stayed in it and why>
