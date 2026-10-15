# Spike SL10n: localized metadata in versions and cloning (Q1–Q6)

| Field | Value |
|---|---|
| Date (UTC) | YYYY-MM-DD, start HH:MM, end HH:MM |
| Done by | owner name (the same as the actor in the audit) |
| Purser commit | output of `git rev-parse --short HEAD` |
| Workspace | Juice (app id from the workspace settings), production = no |
| Products and their state in ASC | the "Purser Spike" group: SpikeYearlyA (<state>), SpikeYearlyB (<state>), SpikeYearlyC (<state>), SpikeMonthly (<state>), PurserSpikeLifetime (<state>) |
| Key | team / individual, key id (never the .p8 content) |
| Write path | the DEBUG window "Spike console" → `SpikeProbe`; audit `httpSent`/`httpReceived` with refs `spike=SL10n`, `step=SL10n-<n>` |

## Questions

| # | Question | Facts / rule |
|---|---|---|
| Q1 | Does a never-submitted subscription, IAP and group have version 1 in `PREPARE_FOR_SUBMISSION`? | spec §8; `MetadataVersionState.role` |
| Q2 | Create and modify a localization through v2 in that version: what is returned, in which state, and does the version change state? | spec §8; `FakeASC+Localizations.swift`, `WriteResponses.localizationRow` |
| Q3 | What does `POST` of a version do while an editable version exists (409 expected)? Code and detail. | spec §7, §8; L3 `createMetadataVersion` |
| Q4 | Apple's text limits (subscription and IAP name and description, group name and custom app name) and the accepted locale codes (an unknown code, too long a text, how characters are counted) | rules N2, N3; `AppleConstants.localizationLocales`, `localizationLimits` |

Q5, Q5b and Q6 (cloning: the review screenshot cycle, an uncommitted reservation, a clone into the same group) are in the section "Q5–Q6: cloning" at the end of this file.

## Procedure and observations

Before the first step: Sync in the sidebar, then open the Spike console (Debug menu); the console fills `VER_YA`, `LOC_YA_EN_US`, `VER_GROUP`, `LOC_GROUP_EN_US`, `VER_LIFE`, `LOC_LIFE_EN_US` and `SPIKE_YEARLY_A`, `SPIKE_GROUP`, `SPIKE_LIFETIME` from the catalog. Every write asks for Touch ID. Each row = one request (step `SL10n-<n>`); a 2xx response to a POST adds the created id to the probe's allowlist (put the variable name into "Variable for the first created id").

| Step | Request (method, path, query, template, variables) | Time UTC | Status | Observation (code, detail, returned attributes) | Fixture |
|---|---|---|---|---|---|
| SL10n-1 | GET `/v1/subscriptions/{{SPIKE_YEARLY_A}}/versions`, `include=localizations&limit=200&limit[localizations]=50` | | | Q1: number and `state` of every version; the localizations of each | spikes/SL10n/sub-versions.json |
| SL10n-2 | GET `/v1/subscriptionGroups/{{SPIKE_GROUP}}/versions`, same query | | | Q1 for the group | spikes/SL10n/group-versions.json |
| SL10n-3 | GET `/v2/inAppPurchases/{{SPIKE_LIFETIME}}/versions`, same query | | | Q1 for the IAP | spikes/SL10n/iap-versions.json |
| SL10n-4 | POST `/v2/subscriptionLocalizations`, `sl10n-sub-localization-create.json`, `VERSION={{VER_YA}}`, `LOCALE=fr-FR`, `NAME=Spike annuel`, `DESCRIPTION=Plan annuel Spike`; created id → `LOC_NEW` | | | Q2: status, attributes and relationships returned | spikes/SL10n/sub-localization-created.json |
| SL10n-5 | GET as SL10n-1 | | | Q2: the new row is in version 1; did the version state change? | |
| SL10n-6 | PATCH `/v2/subscriptionLocalizations/{{LOC_NEW}}`, `sl10n-sub-localization-patch.json`, `LOCALIZATION={{LOC_NEW}}`, `NAME=Spike annuel 2`, `DESCRIPTION=Plan annuel Spike 2` | | | Q2: status and body; are `name` and `description` returned exactly as sent? (Verification and provenance compare the text Purser wrote with the text read back.) | spikes/SL10n/sub-localization-patched.json |
| SL10n-7 | POST `/v2/subscriptionGroupLocalizations`, `sl10n-group-localization-create.json`, `VERSION={{VER_GROUP}}`, `LOCALE=fr-FR`, `NAME=Purser Spike`, `CUSTOM_APP_NAME=Spike` | | | Q2 for the group | spikes/SL10n/group-localization-created.json |
| SL10n-8 | POST `/v1/subscriptionVersions`, `sl10n-sub-version-create.json`, `SUB={{SPIKE_YEARLY_A}}` (version 1 is still in preparation) | | | Q3: status, code, detail. If 201: a second version exists and cannot be deleted through the API; write it down, stop the spike and tell the owner | spikes/SL10n/version-post-while-editable.json |
| SL10n-9 | POST as SL10n-4 with `LOCALE=xx-XX`, `NAME=Unknown` | | | Q4: code and detail for an unknown locale | spikes/SL10n/unknown-locale.json |
| SL10n-10 | POST as SL10n-4 with `LOCALE=it`, `NAME` = 31 characters (`Spike yearly plan name length31`), `DESCRIPTION=x` | | | Q4: name limit | spikes/SL10n/name-31.json |
| SL10n-11 | POST as SL10n-4 with `LOCALE=es-ES`, `NAME` = 30 characters (`Spike yearly plan name length3`), `DESCRIPTION` = 46 characters (`Spike description of exactly forty-six chars..`) | | | Q4: description limit (and that 30 is accepted when the description is short: repeat with a 45-character description if 409) | spikes/SL10n/description-46.json |
| SL10n-12 | POST as SL10n-4 with `LOCALE=pl`, `NAME` = 29 characters, 41 UTF-8 bytes, with diacritics (`Žluťoučký kůň úpěl ďábelské ó`) | | | Q4: are UTF-8 bytes counted instead of characters? (Every letter is one BMP code point, so characters and UTF-16 units cannot be told apart here; SL10n-14 does.) | |
| SL10n-13 | POST `/v2/subscriptionGroupLocalizations` as SL10n-7 with `LOCALE=it`, `NAME` = 76 characters, `CUSTOM_APP_NAME` = 31 characters | | | Q4: group limits (Apple publishes none) | spikes/SL10n/group-long.json |
| SL10n-14 | POST as SL10n-4 with `LOCALE=de-DE`, `NAME` = 29 BMP characters followed by 1 non-BMP character, so 30 characters and 31 UTF-16 units (`Spike yearly plan name length𝒜`, the last one U+1D49C), `DESCRIPTION=x` | | | Q4: how characters are counted. Rule N3 counts with Swift `String.count` (30 here). Accepted: Apple does not count UTF-16 units. 409: Apple may count UTF-16 units (31 > 30); repeat with 28 BMP characters and the same non-BMP one (29 characters, 30 UTF-16 units): accepted means UTF-16 units are counted and N3 must count `utf16.count`, a 409 again means the character itself is refused. The character is a letter, not an emoji, so a refusal is not about the kind of character. The step does not tell grapheme clusters from code points; a base letter with a combining mark would. | spikes/SL10n/name-non-bmp.json |

Every test locale uses its own code (`fr-FR`, `it`, `es-ES`, `pl`, `de-DE`), so a row left by an earlier step cannot hide a limit behind a duplicate 409, and `cs` stays free for the first live plan. Purser never deletes a locale (spec L-D4): what the spike creates stays in version 1 of the never-submitted spike products; the owner may remove it by hand in App Store Connect.
Q4 locale codes: compare `AppleConstants.localizationLocales` with the list App Store Connect offers in the "Add localization" menu of SpikeYearlyA; write down any difference. Reading an approved Juice subscription's versions happens without the console: Catalog → the subscription → Localizations section (L1), version number and state.

Responses are saved with "Save response…", then `python3 -I Tools/redact-fixture.py <saved.json> <redacted.json>` and `python3 -I Tools/anonymize-fixture.py <redacted.json> Packages/PurserCore/Tests/Fixtures/spikes/SL10n/<name>.json --path <path>`; only the anonymized file goes into the repository (exit 3 or 4 = commit nothing, repeat).

## Conclusions

| Question | Answer | Confidence (H/M/L) |
|---|---|---|
| Q1 | | |
| Q2 | | |
| Q3 | | |
| Q4 | | |

## Effect on the code

- AppleConstants: `localizationLimits` <old> → <new>, `localizationLocales` <change>, or "no change" with the reason
- N3 (`LocalizationRules.swift`): counts characters with `String.count`; "no change" when SL10n-14 is accepted, or the count of UTF-16 units with the test that shows it
- FakeASC (`FakeASC+Localizations.swift`): the 409 codes and details for a locked version, a duplicate and an unknown locale and a too long text, or "confirmed without change"
- ErrorClassifier / Reconciler / LocalizationSemantics: <change>, or "none"
- Executor+Errors (Q3, a second version while one is in preparation): <the status and code Apple returns, if Purser expects another>, or "none"

## First live L10N plan

| Field | Value |
|---|---|
| Plan id | |
| Owner and locales | SpikeYearlyA: en-US (changed name), cs (new) |
| Items | |
| Final state | Effective / … |
| Mismatch | 0 |
| `httpSent` paths | `/v2/subscriptionLocalizations…` |

## Cleanup

- Left in version 1 (never submitted): <localizations created in SL10n-4 to SL10n-14>; removed by hand in App Store Connect: <which, or none>
- State of the "Purser Spike" group after the spike: <texts left changed by the live plan; version 1 still PREPARE_FOR_SUBMISSION; never submitted>

## Q5–Q6: cloning (review screenshot cycle, and a clone into the same group)

| Field | Value |
|---|---|
| Date (UTC) | … |
| Done by | … (the actor in the audit) |
| Purser commit | … (`git rev-parse --short HEAD`) |
| Workspace | Juice, production = no |
| Products | SpikeYearlyA (…), PurserSpikeLifetime (…); clones SpikeYearlyA_C1, PurserSpikeLifetime_C1 |
| Write path | Catalog → Clone… (`ProductCreator`, `AssetTransfer`), then the price drafts on the Plans screen (`Executor`); audit `httpSent`/`httpReceived` with refs `clone=<step>`, `request=delete/reserve/upload/commit`, `part=<n>` |
| Write path (Q5b) | SL10n-C-11 and SL10n-C-12 through the DEBUG "Spike console" (`SpikeProbe`) on … (a spike subscription without a review screenshot); audit refs `spike=SL10n`, `step=SL10n-C-<n>` |

| # | Question | Purser's assumption (FakeASC) |
|---|---|---|
| Q5 | The review screenshot cycle: reservation, upload operations, commit, the resulting `assetDeliveryState` | one screenshot per product (a second reservation is 409); `uploadOperations` are `PUT`s whose offsets and lengths cover the file, with a `Content-Type` header; the commit (`uploaded: true`, MD5) makes it `COMPLETE`; no screenshot reads as `data: null` |
| Q5b | While a product has an uncommitted review screenshot reservation (`AWAITING_UPLOAD`), does Apple accept a new reservation (or replace the old one, or refuse it with 409)? Do uncommitted reservations expire, and after how long? | one screenshot per product, so a second reservation is 409 (`FakeASC+Products.swift`); the clone does not depend on it: a reservation from an earlier app session is left alone (spec §7; `ProductCreator` screenshot step, `AppGuard.reservedScreenshots`) |
| Q6 | A clone of SpikeYearlyA into the same group: the copied `groupLevel`, availability and texts read back as expected | a `groupLevel` equal to the source's is accepted; the availability has the source's territories and `availableInNewTerritories`; the texts land in version 1 (`PREPARE_FOR_SUBMISSION`) |

Q5 note (the owner's way out): when a clone meets an unfinished reservation from an earlier app session, the screenshot step is blocked (in the preview, and failed in the run, without Touch ID) with `ProductCreator.earlierSessionReservation`: "A review screenshot Purser cannot replace is in the way (an unfinished upload from an earlier run). Remove it in App Store Connect (the product's Review Information), then run the clone again." That advice is an assumption. Does an uncommitted `AWAITING_UPLOAD` reservation show in the ASC web UI at all, and can it be removed there? SL10n-C-14 to SL10n-C-16 record it. If it does not show or cannot be removed there, the message sends the owner nowhere: write down what does work (a new reservation replaces it, it expires, or only the API can remove it) and tell the owner that the message and spec §7 need a change.

Q6 note: the clone copies every text in the version in preparation of SpikeYearlyA, including the rows that Q2 and Q4 above left there; SL10n-C-4 compares all of them.

| Step | Action | Time UTC | Result | Observation |
|---|---|---|---|---|
| SL10n-C-1 | Check in the Clone sheet | … | … | the listed steps |
| SL10n-C-2 | Clone with Touch ID | … | … | the outcome of every step |
| SL10n-C-3 | History: the upload and commit events | … | … | number of parts, host, path without the query, offset, length; no `Authorization` |
| SL10n-C-4 | Catalog after the sync: the clones' texts and availability | … | … | equal to the sources? |
| SL10n-C-5 | ASC UI: level in the group, availability, review screenshot | … | … | `assetDeliveryState` right after the commit and later |
| SL10n-C-6 | Check again | … | … | "Everything is already in App Store Connect" |
| SL10n-C-7 | Apply the regular price draft | … | … | plan id, state |
| SL10n-C-8 | Apply each intro draft | … | … | plan ids, states |
| SL10n-C-9 | Apply each promotional offer draft | … | … | plan ids, states |
| SL10n-C-10 | Apply the in-app purchase price draft | … | … | plan id, state |
| SL10n-C-11 | Spike console: POST `/v1/subscriptionAppStoreReviewScreenshots` with the body below for a spike subscription without a review screenshot (`SpikeYearlyB`, `SpikeYearlyC` or `SpikeMonthly`, checked in the ASC UI); no upload, no commit | … | … | Q5b: status, `assetDeliveryState` (`AWAITING_UPLOAD` expected), the `uploadOperations`; fixture `spikes/SL10n/screenshot-reserved.json` |
| SL10n-C-12 | Spike console: the same POST again, without a commit or a DELETE of the first reservation | … | … | Q5b: 201 with a second id, 201 with the first replaced, or 409 (code, detail); fixture `spikes/SL10n/screenshot-reserved-again.json` |
| SL10n-C-13 | Spike console: GET `/v1/subscriptions/{{SPIKE_YEARLY_B}}/appStoreReviewScreenshot` (the variable of the product used) | … | … | Q5b: which reservation the product has (the id of C-11 or C-12) and its `assetDeliveryState` |
| SL10n-C-14 | ASC UI: the product's Review Information, look only | … | … | Q5 note: is the uncommitted reservation shown, and as what (a file, a placeholder, nothing)? |
| SL10n-C-15 | GET as SL10n-C-13 and the ASC UI again, about an hour and about a day after SL10n-C-11 | … | … | Q5b: is the reservation still there (expiry), and its state |
| SL10n-C-16 | ASC UI: remove the reservation there, then GET as SL10n-C-13 | … | … | Q5 note: can it be removed in the UI, and what does the GET answer afterwards (`data: null`)? |

Body of SL10n-C-11 and SL10n-C-12 (written by hand in the console; there is no template; use the variable of the product chosen):

```json
{"data": {"type": "subscriptionAppStoreReviewScreenshots",
  "attributes": {"fileName": "spike-q5b.png", "fileSize": 1024},
  "relationships": {"subscription": {"data": {"type": "subscriptions", "id": "{{SPIKE_YEARLY_B}}"}}}}}
```

| Question | Answer | Confidence (H/M/L) |
|---|---|---|
| Q5 | … | … |
| Q5b | … | … |
| Q5 note | … | … |
| Q6 | … | … |

Effect on the code: … ("FakeASC confirmed without change", or the change and its commit).

Cleanup: the clones stay in the never-submitted "Purser Spike" group; their Product IDs cannot be used again. The Spike console goes through the same `AppGuard` as every other write (`SpikeProbe` sends through `ASCHTTPClient`), which lets a DELETE or a commit of a review screenshot through only for a reservation made in the running app session. So it cannot delete a committed screenshot (the clones' and the sources'), nor a reservation left from before a relaunch (SL10n-C-11 and SL10n-C-12 after the app was quit): the screenshot cleanup goes through the ASC UI. In the same session the console can DELETE a reservation of its own (`/v1/subscriptionAppStoreReviewScreenshots/<id>` with the id the POST returned). Left in ASC after the spike: <the reservations of SL10n-C-11 and SL10n-C-12 and how they were removed, or none>.
