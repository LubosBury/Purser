# Purser v1: design

> Status: v1 design, 2026-10-09. It came out of a brainstorming session with the project owner. The facts about the App Store Connect API are in [docs/research/asc-api-facts.md](../research/asc-api-facts.md); references in the text such as `[T1-03]` or `I4` point there.

## TL;DR

Purser is a native macOS app for one person who manages the prices of their iOS apps in App Store Connect: regular subscription prices, introductory offers, promotional offers and prices of one-time purchases (lifetime). Every change takes the same path: import or rule → diff against the live ASC state → check of Apple's rules → stronger confirmation for risky changes → write item by item → verification by reading back → a record in the append-only audit.

The ASC key never leaves the Mac. Every iOS app has its own, fully separate workspace. Development and verification happen on the author's own app [Juice: Fuel & EV Charge Log](https://apps.apple.com/app/juice-fuel-ev-charge-log/id6787720329) under a personal account, because the ASC API has no sandbox and every write goes to production.

## 1. Problem

App Store Connect is the only source of truth for prices and offers, but as a tool it has no diff before a write, no rule checks and no history. The four pains Purser addresses:

| Pain | How it shows |
|---|---|
| Effort | An intro offer is one record per subscription and territory [T1-08]. 175 territories × N subscriptions take hours of clicking in the ASC UI. |
| Errors | Offer prices are fixed amounts. When the regular price changes later, the offer is not recalculated [I6] and may end up more expensive than the regular price, so Apple does not show it. Rounding to a price point can break the promised discount. |
| Overview | You cannot see what is in effect where, what is scheduled and what changed outside the tool. |
| History | No record remains of who changed what, when and why. |

Third-party subscription tools can write only part of this to ASC: regular prices and a free trial of the same length everywhere. They do not write paid intro offers, promo offers or trial lengths that differ by territory. Purser does not build on any such tool.

## 2. Scope of v1

| In v1 | Outside v1 |
|---|---|
| Regular prices of auto-renewable subscriptions per territory, including `preserveCurrentPrice` | Offer codes, win-back offers |
| Introductory offers: free trial (also with a different length per territory), pay up front, pay as you go; the price from a rule ("x % of the regular price, down to a price point") or from a table | Localization, review screenshots, submitting for review (v2). Creating products (group, subscription, non-consumable purchase, availability in all territories) has been in v1 since 2026-10-11; prices and offers of new products are still set by plans |
| Promotional offers including prices per territory | Google Play (later; the core stays store-independent, the abstraction is not built up front) |
| Prices of one-time purchases (IAP, typically lifetime) | Approval by a second person, multiple users |
| Import from a Google Sheet or a CSV with column mapping | Any integration with third-party subscription tools |
| Catalog overview, drift watching, history and audit | Writes of plan type MONTHLY (only reading and the ratio check) [P2] |
| | Changes of territory availability |

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | A native macOS app (SwiftUI), no server | One user; the key stays on the Mac; no operations and hosting |
| D2 | The owner's name entered on first launch (stored in the Keychain, changeable in Settings behind Touch ID) as the audit actor; the original Sign in with Apple was dropped on 2026-10-12 because a Developer ID profile does not support it; Touch ID at launch and before every write; lock after 15 min of inactivity | An identity for the audit; protection of an unlocked Mac |
| D3 | Workspace = exactly one iOS app; no data, keys or settings are shared between workspaces | Writing to the wrong app must be impossible, not just unlikely |
| D4 | App Sandbox from the start; distribution through TestFlight (internal testing), possibly otherwise later | Security; room for later distribution |
| D5 | Nothing specific to one app in the code; mappings, per-app thresholds and import targets are workspace configuration | Purser can later be used for any app |
| D6 | No approval by a second person; risky changes require a stronger confirmation with a mandatory reason | One user |
| D7 | The price decision model (indexes, bands) lives outside Purser, typically in a Google Sheet; Purser imports only its output | Purser should not repeat the pricing model |
| D8 | Development and spikes on the app Juice (a personal account with subscriptions and a Paid Apps agreement); spikes on a test subscription group that is never submitted | ASC has no sandbox [T3-06] |
| D9 | Lifetime (IAP) is in v1 | Everything about iOS prices in one place |

## 4. Architecture

One SwiftUI app. The modules are separate Swift packages, each testable on its own.

| Module | Responsibility | Depends on |
|---|---|---|
| **AppShell** | Windows, navigation, owner name, Touch ID through LocalAuthentication, choosing and switching the workspace, lock after inactivity | all |
| **ASCClient** | The HTTP layer to the ASC API: JWT ES256 (CryptoKit; a team key with `iss`, an individual key with `sub: "user"`), GET-scoped tokens for reading [T3-35], pacing by `X-Rate-Limit`, 5xx retry, error mapping. Hand-written Codable types for the ~20 operations used; an OpenAPI generator only as a fallback if the hand-written client hits a wall (spike SC). Refuses a request to a resource outside the workspace's app | - |
| **Catalog** | A local copy of the ASC state: subscriptions, prices, intros, promos, IAP schedules, price points. Versioned snapshots, row provenance, findings | ASCClient, Store |
| **Importer** | Google Sheets (OAuth for desktop, read only, `UNFORMATTED_VALUE`) and CSV; the column mapping stored in the workspace; matching a country name to a territory, currency check | - |
| **Planner** | Desired state (import, rule, form) → diff per cell → items (each = 1 request); snapping to price points; estimate of requests and time | Catalog |
| **Policy** | The rules of ch. 7 over a plan and over the catalog (invariants) | Catalog |
| **Executor** | Preflight, item-by-item write with a checkpoint, pauses and resume, verification | ASCClient, Catalog, Policy, Store |
| **Audit** | Append-only events (SQLite triggers), hash chain, export, daily fingerprint | Store |
| **Store** | GRDB/SQLite, one database per workspace, migrations | - |

**Storage and workspace separation.**
- Every workspace has its own directory in the app's container with a SQLite database. `workspaces.json` holds only the id, name, color and path.
- The ASC key (.p8), the Google token and the optional Slack webhook are in the Keychain under the workspace id. Two workspaces never share a Keychain item, even when the apps are under the same ASC account.
- Only one workspace is open at a time. Switching closes the other one's windows and asks for Touch ID.

**Key and tokens.**
- The key is stored in the Keychain as `ThisDeviceOnly`. The app enforces Touch ID (LocalAuthentication) at launch and before every apply; only then may ASCClient make a token for writing.
- For reading (nightly sync, catalog) only GET-restricted tokens are made [T3-35], so even the background path cannot write.
- For production apps the recommended key is an individual key of a user with the App Manager role limited to that app, the only documented way to limit a key to an app [T3-32, T3-33].

**In the background.** The nightly sync is started by a login item (SMAppService) sharing the App Group and the Keychain access group with the app. Spike SL verifies that this works in the sandbox; if it does not, the sync runs at launch and periodically while the app runs. During an apply the app does not let the Mac sleep.

**Notifications.** macOS notifications; optionally a Slack webhook per workspace (new findings, a finished or paused apply, the daily audit fingerprint).

## 5. Data model

A **cell** is the unit of diff, write, verification and drift watching.

| Write model | Cell key | Apple's limit |
|---|---|---|
| Subscription regular price | sub, territory, planType | at most 1 future change [T3-09]; current = the row with the latest `startDate` ≤ today [T3-04] |
| Intro offer | sub, territory, targetPlanType | at most 1 current + 1 future [T1-18]; only `endDate` can be changed [T1-03] |
| Promo offer | sub, offerCode (+ price set) | no dates [T2-05]; only prices can be changed [T2-03] |
| IAP price | iap (the whole schedule: base territory + manual prices) | POST replaces the whole schedule (spike S10) |

**planType is canonical in the key.** An observation stores the raw value, including a missing one; the cell key normalizes it (for a subscription without MONTHLY a missing value is UPFRONT). Spike S0 measures the real values [T1-04].

| Table | Key fields |
|---|---|
| workspace (1 row) | keyKind (team / individual), issuerId (team only), keyId, appId, bundleId, name, color, production (bool), import mapping (versioned; including the nominal discount for discount targets) |
| sync_run | trigger (nightly / manual / plan / preflight / verify), Complete / Partial / Failed, request count, list of (sub, kind) loaded in full |
| product | ascId, productId, type (sub / iap), period, state, availability including plan availability, group, firstSync |
| observation | kind (PRICE / INTRO / PROMO / PROMO_PRICE / IAP_SCHEDULE), ascId, canonical cell, raw attributes + hash, firstSync, lastSync, provenance, expired |
| price_point | product, territory, planType, pointId, price, currency, fetchedAt |
| plan | origin (IMPORT / INTRO / PROMO / IAP / FIX / WITHDRAW), spec (product and territory filter, CANARY), import (raw values, sha256, mapping version), binding (keyKind, issuerId, keyId, appId, bundleId), product states from the preflight, baseSync, state, endReason, planHash, verdictHash, reason, confirmation level, appBuild, estimate of requests and minutes, replanOf |
| item (= 1 request) | seq, op (POST / DELETE / PATCH_END / PATCH_PRICES / SCHEDULE_REPLACE), cell, before (the cell's state after the predecessors from dependsOn), target, naturalKey, dependsOn, rules, state, attempts, ascId, error, verifiedAt, effectiveAt, supersededBy, flags (NO_OFFER, LOST_SCHEDULED_CHANGE) |
| finding | type, rule, cell, fingerprint, firstSync, lastSync, plan, ack + reason |
| offer_code_registry | offerCode, product, first seen (every code ever used [O1]) |
| audit_event | seq, ts, type, actor (the owner's name; for records before 2026-10-12 the Apple user id), references, payload, prevHash, hash |

**Snapshots as version ranges.** An unchanged row gets `lastSync = N`; a new or changed one is inserted again; nothing is deleted. A cell's history is a query over `observation`. A disappearance is evaluated only for a (product, kind) loaded in full in that sync_run, so a preflight, a verify or an incomplete sync never produces a false finding. An expected disappearance is `expired` without a finding (an intro after its `endDate`, a non-preserved price row replaced by a newer one); whether Apple hides such rows at all is verified by S4a and S6 [T3-05].

**Row provenance.**

| Provenance | When |
|---|---|
| BASELINE | the workspace's first sync; all rows of a product that appeared for the first time |
| PURSER | the ascId or naturalKey matches a Purser item |
| APPLE | a change of an IAP price in a territory without a manual price (Apple generates it from the base and adjusts it for FX and taxes) |
| EXTERNAL | anything else: Apple does not change subscription prices [T3-25], so a person in ASC or another tool changed them |

| Finding | When |
|---|---|
| EXTERNAL | a row appeared, changed or disappeared (other than expired) and neither a Purser item nor the APPLE provenance explains it |
| SCHEDULE_BROKEN | a row scheduled by Purser disappeared without an explanation, or does not match the target after it took effect |
| INVARIANT | the live state breaks a rule marked * in ch. 7, whoever caused it (for example an intro more expensive than the regular price) |

**Idempotence.** ASC has no idempotency key, so the state is read and compared with the item's natural key. A fresh read is mandatory for an InFlight item and after a timeout, a 5xx or a 409.

| Operation | Natural key |
|---|---|
| POST regular price | sub + territory + planType + startDate + pointId + preserved |
| POST intro | sub + territory + planType + mode + duration + pointId + startDate (null startDate = the day of creation; S4a refines it) |
| PATCH_END | ascId + endDate |
| DELETE | ascId missing = done |
| POST promo | offerCode |
| PATCH_PRICES | ascId + hash of the whole price set |
| SCHEDULE_REPLACE (IAP) | iap + hash of the whole schedule |

**Audit.** `RAISE(ABORT)` triggers forbid UPDATE and DELETE; `hash = sha256(prevHash ‖ row)`. Every write has an HTTP_SENT event before it is sent and an HTTP_RECEIVED event after the response. The `Authorization` header is never stored, only the keyId and jti. The export is JSONL with chain verification; the daily fingerprint of the chain head (seq + hash, no prices) optionally goes to Slack.

## 6. Life cycle of a change

### Plan states

| State | Entry | Where next |
|---|---|---|
| Draft | The Planner loads the affected products, computes the diff, runs the policy | Draft (re-plan, new hash), Applying, Cancelled |
| Applying | Touch ID, preflight, confirmation over a fresh verdict. Substate Paused (USER, QUIT, SLEEP, CRASH, NETWORK, RATE, AGREEMENT, AUTH, SYSTEMIC) | Draft (confirmation refused, 0 writes), Stale, Scheduled, Effective, PartiallyApplied, Cancelled |
| Stale | the first preflight (nothing was InFlight or Done) found a difference or a new BLOCK; nothing was written | Draft (from the stored import), Cancelled |
| Scheduled | everything written and verified, but some date is in the future | Effective; PartiallyApplied (+ SCHEDULE_BROKEN); Cancelled (SUPERSEDED / WITHDRAWN) when no item is left |
| Effective | every item other than Superseded/Withdrawn is in effect; verified by a sync after max(date) + 1 day (a later start in APAC [T1-17]) | end |
| PartiallyApplied | at least 1 write went through and something is Failed / Stale / Skipped / Mismatch, or an abort after a write | Closed by one of the three actions below |
| Closed | the user's decision over PartiallyApplied; endReason REPLANNED / WITHDRAWN / ABANDONED | end |
| Cancelled | cancelled, or an abort after which reading back the InFlight items showed 0 writes | end |

| Action on PartiallyApplied | What it does |
|---|---|
| Replan the rest | a new Draft from the fresh ASC state and the stored import (the sheet again only on explicit choice); leaves out cells whose expected state belongs to a newer plan |
| Roll back written | a WITHDRAW plan for the Done items with a future date, if R6 still allows it |
| Close | mandatory reason |

Only one plan per workspace may be in Applying. Overlapping plans are pushed to Stale by their own preflight; no locks are needed. Items are tracked until they take effect, even after Closed.

### Item states

| State | When |
|---|---|
| Pending | waiting; ends Stale (before no longer holds) or Skipped (a predecessor did not go through) |
| InFlight | HTTP_SENT is in the audit before the request leaves |
| Done | the write is confirmed, or the target was found by reading (reconciled) |
| Failed | an error with no further attempt |
| Mismatch | 3 reads over ~5 min do not find the target; the nightly sync reads again and returns Done if it finds it (late verified) |
| Superseded / Withdrawn | the row was removed by a later Purser item; no finding is created |
| Effective | the operation is in effect: POST = the row is current; PATCH_END = after the date the row is not current; DELETE = the row is missing; promo and IAP = right after verify |

### Executor

| Step | What it does |
|---|---|
| 1. Unlock | Touch ID, once per apply session |
| 2. Preflight without writing | binding A1 and a live `GET /v1/apps/{id}`; product states [P7] are stored in the plan; the first `X-Rate-Limit`; reading the affected products; policy again |
| 2a. First start | nothing was InFlight or Done: any difference from `before` = plan Stale, 0 writes |
| 2b. Resume | in each cell only the first unexecuted item of the chain is checked. Pending: live state = before, otherwise Stale and the dependents Skipped. InFlight: target found = Done, live state = before = back to Pending, otherwise Stale. The plan stays Applying |
| 3. Confirmation | C0 / C1 / C2 over the fresh verdict; if verdictHash differs from the Draft, the difference is highlighted |
| 4. Write | product by product; right before sending, the deadlines R4, R6, I7 again (a breach = Stale); the target already exists = Done; live state = before → HTTP_SENT, request, HTTP_RECEIVED, Done |
| 5. Verify | reading the product back → verifiedAt, or Mismatch |

**Pacing.** By `user-hour-rem`, a ceiling of 300 req/min until the result of S1, 10 % of the budget for verify [T3-26, T3-28]. The Mac is kept awake, a heartbeat every 10 s; a plan in Applying with an old heartbeat is Paused(CRASH) after launch, Paused(SLEEP) after wake. An abort first reads back all InFlight items.

| Pause | Resume |
|---|---|
| RATE, NETWORK | by itself, in the same apply session, after reading the affected product |
| USER, QUIT, SLEEP, CRASH, AUTH, AGREEMENT, SYSTEMIC | Touch ID + preflight 2b |

| Signal | Action |
|---|---|
| timeout, crash or outage after HTTP_SENT | the item stays InFlight and a fresh read resolves it; never a blind retry |
| 429 | Paused(RATE), wait 1-2-4-8-15 min, then on by itself (Apple sends no Retry-After) [T3-26] |
| 5xx | fresh read, at most 3 attempts, then Failed |
| 401 | a new JWT once (the token is also renewed preventively, it is valid for 20 min at most) [T3-35]; repeatedly Paused(AUTH) |
| 403 REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED, 409 "Pricing change is not allowed" | Paused(AGREEMENT) and a prompt to accept the agreement [I8] |
| another 403 | Paused(AUTH) |
| 409 "Must delete future price change" | item Stale [T3-10] |
| 409 "Only future price changes can be deleted" | DELETE Failed, the paired POST Skipped [T3-11] |
| another 409 or 422 | fresh read: target found = Done, otherwise Failed; the raw error goes to the audit |
| the same error 3× in a row or on > 5 % of the items | Paused(SYSTEMIC) |

### Order of steps within one cell

| Situation | Order | When the second step fails |
|---|---|---|
| Replacing a scheduled regular price | DELETE → POST [T3-10] | the cell keeps the current price, flag LOST_SCHEDULED_CHANGE, repeating is safe |
| A live intro on an approved subscription | PATCH_END to D → POST from D, D ≥ today+2; a live intro is never deleted. Only after spike S4b, otherwise only a CANARY plan (I7) | the old intro runs until D; flag NO_OFFER and a daily notification |
| A future intro, or an intro on an unsubmitted subscription | DELETE → POST | the customer sees nothing |
| Regular price + intro in one territory | for a decrease the intro first, for an increase the regular price first [T1-15, T2-13] | the second step Skipped; so the intro never stays ≥ the regular price |
| Regular price decrease + PAYG promo | PATCH_PRICES of the promo first, then the regular price [O5] | the regular price Skipped |

### How to undo a change

| Type | Operation | Before it takes effect | After it takes effect |
|---|---|---|---|
| Regular price | schedule / replace | WITHDRAW = DELETE, at the latest 48 h before the start [T3-11] | only by a new change; a decrease cannot be undone [T3-16] |
| Intro | create | DELETE | PATCH_END; whoever bought the intro has it in full |
| Intro | end | move the endDate (going back to null is verified by S4a) | create a new one |
| Promo | create / delete | DELETE; the code is burned forever [O1] | Apple does not document the effect on customers in the middle of the offer [O6] |
| Promo | reprice | PATCH back to the price set from `before` | the same |
| IAP price | replace the schedule | SCHEDULE_REPLACE back to `before` | the same; a one-time purchase has no existing subscribers |

## 7. Rules (policy)

**Levels.**
- **BLOCK:** scope PLAN = the plan cannot be started; scope CELL = the cell is excluded from the plan, stays visible and is in the audit.
- **C0** at every apply: summary, Touch ID, explicit ticking of the list of excluded cells.
- **C1** in addition: type the app's name. Required in a workspace marked as production.
- **C2** in addition: a mandatory reason (≥ 20 characters) and ticking every risk class with its cell count. It replaces approval by a second person (D6).
- **WARN:** shown and logged.
- **STRUCT:** the code cannot build such a request at all; a unit test guards it.
- **\*** = the rule also runs every night over the catalog and the result is an INVARIANT finding.

| ID | Rule | Level · scope | Source |
|---|---|---|---|
| A1 | A plan is bound to keyKind + keyId (+ issuerId) + appId + bundleId; the preflight compares them with the workspace and with a live `GET /v1/apps/{id}`; on a mismatch the Executor refuses | BLOCK · PLAN | D3, T3-33 |
| A2 | An apply in a production workspace | C1 | D3 |
| A3 | Only one plan per workspace may be in Applying | BLOCK · PLAN | |
| A4 | The preflight reads again, computes the diff and runs the policy (ch. 6) | BLOCK · PLAN | |
| A5 | A product in a state other than READY_TO_SUBMIT, MISSING_METADATA, DEVELOPER_ACTION_NEEDED, APPROVED | BLOCK · PLAN | P7, T3-08 |
| A6* | A territory outside the product's availability | BLOCK · CELL | T1-05 |
| A7 | The plan shows the number of requests and minutes and warns when it exceeds the rest of the hourly budget | WARN | T3-26 |
| A8 | 409 "Pricing change is not allowed" or a 403 about the agreement at run time: pause and prompt | pause | I8 |
| A9 | ASCClient refuses a request to a resource that does not belong to the workspace's app | STRUCT | D3 |
| S1 | Every imported row matches exactly one territory by the bundled map of ASC names (NFC, ’ → ', case-insensitive); no duplicates | BLOCK · PLAN | D7 |
| S2 | The import's currency = the territory's currency in ASC | BLOCK · PLAN | T3-22 |
| S3 | A value read as UNFORMATTED is a number > 0 | BLOCK · PLAN | |
| S4 | Snapping to a price point of the same product + territory + planType: the regular price to the nearest point, intro, promo and discounts down. The point does not exist: BLOCK; a deviation > 2 %: WARN; > 10 %: BLOCK | BLOCK · CELL / WARN | I3, T1-16 |
| R1 | A regular price POST always sends planType and preserveCurrentPrice; for an increase preserve is chosen in the plan with no default, for a decrease it is always false. Intro and promo send targetSubscriptionPlanType according to the result of S0 | STRUCT | P1, T3-14 |
| R2 | Writes of plan type MONTHLY | BLOCK · PLAN | P2 |
| R3* | If the subscription has MONTHLY: 1.0 ≤ 12 × monthly / upfront ≤ 1.5 | BLOCK · CELL | P2 |
| R4 | startDate ≥ today+2 (UTC) for a regular price on an approved subscription and for a new intro on an approved subscription; a regular price is never null on a subscription that already has a price; checked again right before sending (S5 refines the deadline) | BLOCK · CELL | P4, T3-12, T1-17 |
| R5 | The cell already has a scheduled change: a DELETE + POST pair marked "replaces the change from <date>" | C2 | P3, T3-10 |
| R6 | Replacing or deleting a scheduled change less than 48 h before its start; checked again right before sending | BLOCK · CELL | P3, T3-11 |
| R7 | A regular price decrease; I4, I5, O5 are verified again against the new price | C2 | P5, T3-16 |
| R8 | An increase with preserveCurrentPrice = false | C2 | T3-14 |
| R9 | Consent estimate per storefront: CERTAIN (AUT, DEU, POL, KOR), POSSIBLE (> 50 %), CUMULATIVE (an increase in the same cell within 12 months) | WARN | P6, T3-17, T3-18 |
| I1 | The territory is always sent; no inline `PATCH /v1/subscriptions` | STRUCT | I1, I9 |
| I2 | Mode, duration and number of periods match the subscription period, also for a trial duration per territory | BLOCK · CELL | I2 |
| I3 | A paid intro has a price point of the same product + territory + planType; a free trial has none | STRUCT | I3 |
| I4* | The intro is cheaper than the regular price on every day of its remaining validity [max(start, today), end): that is, than the current price and than every scheduled change that starts before the intro ends. When planning, over the state after the plan | BLOCK · CELL | I4 |
| I5* | The discount measured against the lowest regular price in the same window as I4 is not smaller than the nominal one. Target = the highest price point ≤ min(the import's value, (1 − nominal) × regular price); the diff marks the limit "limited by I5". Deeper by > 5 pp: WARN | BLOCK · CELL / WARN | D7, I4 |
| I6 | At most 1 current + 1 future intro; ending or deleting is explicit in the plan before the POST | BLOCK · CELL | I5, T1-18 |
| I7 | A live intro is not deleted, it is replaced by PATCH_END to D + POST from D (D ≥ today+2). Until spike S4b confirms it, only a CANARY plan may run (1 territory per product, C2); its Effective unlocks the rest | BLOCK · PLAN | T1-18, T1-21 |
| I8 | A regular price change in a cell with a paid intro: the plan must contain a replacement of the intro with the same date, or leave it out with a reason | BLOCK · CELL / C2 | I6, T1-30 |
| I9 | One intro per customer and subscription group; Korea requires consent when moving to the full price | WARN | I7, T1-24, T1-26 |
| O1 | The offerCode has never appeared before (registry); Purser suggests the form `<base>_v<n>` | BLOCK · PLAN | O1 |
| O2 | At most 10 promos per subscription | BLOCK · PLAN | O2 |
| O3 | A price for every territory where the subscription is available | BLOCK · PLAN | O3 |
| O4 | A free trial row without a price point, a paid one with it (verified by S7) | STRUCT | O4 |
| O5* | A PAYG promo cheaper than the regular price now and after every scheduled decrease; a PUF promo ≥ the regular price: WARN | BLOCK · PLAN / WARN | O5 |
| O6 | PATCH always sends the whole price set and reads all of it back; repricing or deleting an offer | C2 | O6 |
| O7 | A change other than price = a new offer with a new code; the old one is deleted only by a later plan after ticking "the app no longer uses <code>" | C2 | O7 |
| L1 | An IAP schedule is always sent whole: base territory, all manual prices including future ones; the diff shows the whole schedule before and after | STRUCT | §1.4 |
| L2 | Territories without a manual price follow the price generated from the base territory; the plan lists them and points out that FX and taxes of manual prices are the user's to watch | WARN | §1.4 |
| L3 | An IAP price decrease of more than 30 % | C2 | D6 |

The constants of Apple's rules are in the code and every plan stores its appBuild; changing a threshold = a new build, never a setting outside the audit. What is specific to an app (mapping, nominal discounts, the production flag) is workspace configuration and every change of it goes to the audit.

| Deliberately outside v1 | Why it is safe |
|---|---|
| Local consent thresholds | R9 already warns above 50 % |
| MONTHLY writes | R2 blocks them, R3 watches the ratio |
| Cross-product checks beyond I4/I5 | the decision model is outside Purser (D7) |
| Effect on subscribers | Purser has no data for it |
| Cancelling preserve | only the ASC UI can do it |

## 8. Screens and flows

**Always visible:** a full-width banner in the workspace's color with the app's name, key type and id and app id. A production workspace has a red banner. The banner is also on the confirmation sheet.

| Screen | What it shows | Actions |
|---|---|---|
| First launch | Name for the audit, then Touch ID | - |
| Workspace picker | the list of apps (name and color only) | open, create |
| Catalog | product selection and 175 rows: territory, currency, current price, scheduled change (date, preserve), current and future intro (mode, duration, price, % of regular), number of promos, provenance, findings, flags, snapshot age | Sync; a cell opens the history of its rows and the items that touched it |
| Findings | grouped rule × product (for example "I4 intro ≥ regular price · 148 cells") | a repair plan with a pre-filled spec; acknowledge with a reason |
| New plan | tabs: Import (sheet / CSV), Intro, Promo, IAP; product and territory filter; the CANARY flag | Build plan |
| Plan | header (binding, product states, base age, operation counts, requests and minutes, nearest date); policy panel; diff (territory, currency, before → after, delta %, the import's value, after snapping, effective discount, % of regular, start, flags; a "flagged only" filter); during an apply the progress, `user-hour-rem`, ETA, pause reason | Re-plan, Cancel, Apply, Pause / Resume / Abort, Roll back; on PartiallyApplied the three actions of ch. 6 |
| History | plans by state, audit, chain state, last fingerprint | Export JSONL, Verify chain |
| Workspace settings | key (type, .p8 import to the Keychain), app id, color, production, Google account, import mapping, Slack webhook, sync time | - |

**Flows.**
1. **Import from a table.** New plan → Import. Purser offers the workspace's stored mapping: country column, currency column and for every target a pair "product × price type" (regular price, intro PUF/PAYG/trial, promo, IAP) with a column and, for discounts, the nominal discount. The user ticks which targets are written; the others only check, their differences are shown in the Import check section and are never written. A filter narrows the products and territories (canary). S1-S4 errors are visible right at the rows. The result is a plan in Draft.
2. **Intro.** Products, mode, duration (for a trial also per territory), start, territories (all available by default). Price: the rule "x % of the regular price valid during the intro, down", a table territory → price or duration, or a free trial.
3. **Promo.** Code (O1 is checked while typing), prices from a rule or a table, a coverage indicator (for example 175/175). Deleting the old offer is a plan of its own.
4. **IAP.** Base territory and manual prices from an import or a table; a diff of the whole schedule.
5. **Regular price change.** The Planner adds intro replacements with the same startDate (I8) and offers to reprice PAYG promos (O5).
6. **Review and apply.** Items are not edited by hand; a change = editing the source and Re-plan. Apply: Touch ID → preflight → confirmation C0/C1/C2 → write; progress on the same screen; a notification when it finishes or pauses.
7. **Drift.** After the nightly sync a notification only about new findings; in Findings a repair plan, or acknowledge with a reason.
8. **Resume after an interruption.** A banner "Apply paused (CRASH) at 212/525"; resume = Touch ID + preflight 2b; finished items are not written again.

**Outside v1:** dashboards, manual editing of items, a view across workspaces, a menu bar item, export of a plan to CSV.

## 9. Spikes, testing, rollout

**The Juice test environment (D8).** A manually created subscription group "Purser Spike" (SpikeYearlyA, SpikeYearlyB, SpikeMonthly; SpikeYearlyC without a price for the "first price" spikes) and one test IAP; never submitted for review. A group of its own protects Juice's customers: a spike intro does not affect which intro they are eligible for [T1-24]. Every spike records fixtures (without `Authorization`) and its result becomes a named constant in the code (for example `MinLeadDays`). Spikes on an approved subscription always send preserveCurrentPrice = true and run only on a subscription without preserved price rows.

| # | Spike | Unblocks |
|---|---|---|
| SA | Sign in with Apple in a sandboxed app distributed through TestFlight; checking the sign-in state at launch (historical, see D2) | sign-in |
| SC | Hand-written Codable client: every path used exists in specification 4.5.1 (a script) and the recorded Juice responses decode; a generator only on failure | ASCClient |
| SK | Keychain in the sandbox: storing the .p8, sharing with the login item through the access group; a GET-scoped token for the background sync | key, nightly sync |
| SL | A login item (SMAppService) in the sandbox shares the App Group container with the app | nightly sync |
| S0 | Read only: JWT, the real `X-Rate-Limit`, a full load of Juice; which planType and targetSubscriptionPlanType existing rows return | M0, canonical planType, R1 |
| S1 | Reading > 300 requests/min | pacing |
| S2 | A request without planType / preserveCurrentPrice / targetSubscriptionPlanType and reading back the values Apple fills in | R1 |
| S3 | What ASC rejects: PAYG ≥ regular price, a foreign price point, a trial with a price point, an unavailable territory | I2-I4, A6 |
| S4a | An unsubmitted subscription: PUF without a startDate and without a territory; an overlap and a third offer; DELETE vs PATCH endDate = today; going back to endDate null; does a row stay in the list after its endDate passes? | first write, expired |
| S4b | An approved Juice subscription with a live intro: PATCH_END to D + POST of an identical intro from D; reads on D−1, D, D+1 (does the old intro end on D, or D−1?) | I7 |
| S5 | startDate today / past / null / +1 / +2; the time zone of "today" | R4 |
| S6 | POST with a pending change; DELETE right before the start; does the previous non-preserved row disappear after startDate? | R5, R6, expired |
| S7 | Promo: PATCH of only some territories (replace, or merge?); trial rows; the same code on another subscription | O3, O4, O6 |
| S8 | 50 items on Juice: SIGKILL in the middle, between DELETE and POST and between PATCH_END and POST; sleep, network off, a forced 429 | M2 exit |
| S9 | An individual key of an App Manager limited to the app does not see the account's other apps | key recommendation for production |
| S10 | IAP schedule: reading, replacing the whole schedule, behaviour of territories without a manual price | L1, L2 |
| DTS | A question to Apple: what happens to customers when a promo is deleted or repriced, and to a live PAYG intro after a regular price decrease | wording of O5, O6 |

**Tests.**
- **Unit:** import of a fixture table (unformatted, "Korea, Republic of", "Côte d’Ivoire"); snapping up and down including the I5 limit; diff against golden files; for every rule one test that satisfies it and one that breaks it; the state transition table.
- **FakeASC:** a single stub at the HTTP transport level (the `HTTPTransport` protocol), an in-memory model that enforces the behaviour confirmed by spikes, replays the recorded fixtures including the 409, 429, 5xx variants and accepts both JWT shapes.
- **Crash property test:** the Executor is killed at a random point and then resumes. It holds that: the final state = the target, no duplicate record, every HTTP_SENT has a read. Fixed cases: a crash after 212/525, between DELETE → POST, between PATCH_END → POST.
- **Golden:** a catalog snapshot with a deliberately introduced error (an intro more expensive than the regular price in 148 cells) gives an I4 finding with 148 cells.
- **Audit:** UPDATE and DELETE fail; the chain passes verification; the string "Bearer" is in no row and no export.

**Milestones.**

| M | Content | Exit criterion |
|---|---|---|
| M0 | App skeleton, sign-in (SA), workspaces, Keychain (SK), ASCClient (SC), Store, Audit, Catalog, read-only sync; S0, S1 | the Juice catalog matches the ASC UI; a full sync < 200 GET; the S0 result recorded as a constant |
| M1 | Importer, Planner, Policy including invariants, Findings, the Plan screen; apply turned off | the import of the fixture table gives the expected number of items, 0 BLOCK; the golden I4 finding matches |
| M2 | Executor, confirmations C0-C2, pauses, abort, Slack fingerprint; S2-S8 on Juice | all S8 drills end with state = target and 0 duplicates |
| M3 | First live writes on Juice: an intro on the Purser Spike group (canary 1 territory → 1 product × 175 → the rest); after the OQ1 decision, S4b on an approved subscription | Effective, 0 Mismatch |
| M4 | Promo (after S7), IAP (after S10), regular price change with intro replacements; nightly sync (SL) | Effective on Juice for all four write models |
| M5 | TestFlight build; a second workspace (a production app) created by configuration only; S9 | the first plan on the production app passes the preflight without code changes |

## 10. Open questions

| # | Question | Recommendation |
|---|---|---|
| OQ1 | May spikes S4b, S5 and S6 run on one approved Juice subscription? Without it the first live intro ending happens on the production app. | Yes: S4b replaces a live intro with an identical one, S5 and S6 change the price to the same price point with preserve = true on a subscription without preserved prices; the customer notices nothing. Choose a subscription with a live intro and few subscribers. |
| OQ2 | The Swift client: generated, or hand-written? | Decided in the plan: a hand-written client for ~20 operations, verified against the specification and the recorded responses (SC). |
| OQ3 | The nightly sync from a login item, or only while the app runs? | Spike SL decides; v1 works without it too. |
