# Localizations and product cloning: design

> Status: implemented in 1.2; spike SL10n not run yet. Designed on 2026-10-14 in a brainstorming session with the project owner. It extends [the v1 design](2026-10-09-purser-v1-design.md): localization moves from "outside v1" into scope, and product creation gains cloning. Submitting for review stays outside.

## TL;DR

Purser reads, shows and writes the localized names and descriptions of subscriptions, in-app purchases and subscription groups (including a group's custom app name). Changes go through the same plan path as prices: draft → diff → rules → confirmation → write → verification → audit. Texts come from a Google Sheet or CSV, from Claude over MCP, or from editing in the app.

On top of that, Purser clones products for A/B tests: a clone gets everything the source has (group, level, period, Family Sharing, review note, availability, localizations, review screenshot), and the source's current UPFRONT prices, intro offers and promotional offers (for a one-time purchase, its current prices) come as Draft plans that the owner applies or replaces with new prices.

Purser prepares a version for review but never submits it. Submitting stays one click in App Store Connect.

## 1. What the API offers

Checked against the OpenAPI specification 4.5.1 and the [4.4.1 release notes](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-4-1-release-notes).

| Owner | Localized fields | Write endpoints (v2) |
|---|---|---|
| Subscription | `name`, `description` | `POST /v2/subscriptionLocalizations`, `PATCH`/`DELETE /v2/subscriptionLocalizations/{id}` |
| In-app purchase | `name`, `description` | `POST /v2/inAppPurchaseLocalizations`, `PATCH`/`DELETE /v2/inAppPurchaseLocalizations/{id}` |
| Subscription group | `name`, `customAppName` | `POST /v2/subscriptionGroupLocalizations`, `PATCH`/`DELETE /v2/subscriptionGroupLocalizations/{id}` |

Since 4.4.1 the metadata of these three owners lives in **versions** (`subscriptionVersions`, `inAppPurchaseVersions`, `subscriptionGroupVersions`). A version holds the localizations (and images) and is what goes to App Review. The v1 localization resources are deprecated; the v2 ones are created under a version (relationship `version`). A version has a `version` number and a `state`: `PREPARE_FOR_SUBMISSION`, `READY_FOR_REVIEW`, `WAITING_FOR_REVIEW`, `IN_REVIEW`, `ACCEPTED`, `APPROVED`, `REPLACED_WITH_NEW_VERSION`, `REJECTED`, `DEVELOPER_REJECTED`. Apple describes creating a version as "capturing its current localized metadata". The API has no DELETE for a version.

Consequences:

- A product never submitted for review (the "Purser Spike" group, products Purser just created) is edited in its existing draft version.
- An approved product needs a new version; its texts are edited there and the version is submitted in App Store Connect. Customers see the old texts until Apple approves it.

The review screenshot is not versioned: it stays on the product (`/v1/subscriptionAppStoreReviewScreenshots`, `/v1/inAppPurchaseAppStoreReviewScreenshots`, relationship to the product) and is uploaded through a reservation with `uploadOperations` to an Apple upload host, then committed with `PATCH uploaded=true` and a checksum.

Third-party subscription tools can write a product's name and description per locale, but not a group's name or custom app name, and they do not say how they handle approved products.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| L-D1 | Localizations are a new kind of plan cell, not a separate editor | Diff, rules, confirmation, verification, audit and the MCP review flow come for free; machine translations are reviewed as a Draft before anything is written |
| L-D2 | Purser writes only into an editable version and creates one when an approved product has none; it never submits for review | Submitting is a new kind of write with conflicts (an app version already in review); one click in ASC is cheap |
| L-D3 | An empty cell in an imported row means "keep the current text" | The same convention as the third-party tools the owner knows; a partial table cannot erase texts |
| L-D4 | No deleting of a locale (for now) | Not needed for the known flows; can be added later with a confirmation |
| L-D5 | A clone writes the product, its availability, localizations and review screenshot in one `ProductCreator` run; prices, intro and promo offers come as Draft plans | Prices and offers only ever go through plans (v1 principle) |
| L-D6 | A clone of a subscription goes to the source's group at the source's level by default; a new group (with the source group's localizations) is the alternative | A/B variants in one group cannot be held at the same time |

## 3. ASC layer

### Paths

Added to [docs/research/asc-api-paths.md](../research/asc-api-paths.md) first (checked by `make check-endpoints`), then to `ASCPath` and the `AppGuard` rules.

| Purpose | Method and path | Note |
|---|---|---|
| Versions with texts | `GET /v1/subscriptions/{id}/versions`, `GET /v2/inAppPurchases/{id}/versions`, `GET /v1/subscriptionGroups/{id}/versions` | `include=localizations`, `limit[localizations]=50`, `limit=200` |
| Texts of a version | `GET /v1/subscriptionVersions/{id}/localizations`, `GET /v1/inAppPurchaseVersions/{id}/localizations`, `GET /v1/subscriptionGroupVersions/{id}/localizations` | only when the live or pending version's `localizations` relationship lists exactly 50 ids (the include limit), so it may have more |
| New version | `POST /v1/subscriptionVersions`, `POST /v1/inAppPurchaseVersions`, `POST /v1/subscriptionGroupVersions` | Executor only |
| Texts | `POST /v2/subscriptionLocalizations`, `/v2/inAppPurchaseLocalizations`, `/v2/subscriptionGroupLocalizations`; `PATCH` of `/{id}` on the same three | Executor and `ProductCreator`; no DELETE (L-D4) |
| Review screenshot | `GET /v1/subscriptions/{id}/appStoreReviewScreenshot`, `GET /v2/inAppPurchases/{id}/appStoreReviewScreenshot`, `POST /v1/subscriptionAppStoreReviewScreenshots`, `PATCH`/`DELETE /v1/subscriptionAppStoreReviewScreenshots/{id}`, the same for `/v1/inAppPurchaseAppStoreReviewScreenshots` | `ProductCreator` only (cloning) |

`check-asc-endpoints.py` also checks the attributes Purser reads: the v2 localization schemas (`name`, `locale`, `description` / `customAppName`; v2 localizations carry no `state`) and the three version schemas (`version`, `state`).

### AppGuard

- `subscriptionVersions`, `inAppPurchaseVersions`, `subscriptionGroupVersions` are read-only child collections: a version is read by id only after Purser learned its id from an answer to a request under the workspace app (in practice the versions read under a product or group); a version is never changed or deleted.
- A localization of the three v2 collections is read or changed (`PATCH`, the body naming the same id) only by an id learned the same way, from a read or from the answer to its `POST`; never deleted.
- A `POST` of a version must name a subscription or in-app purchase read under the app, or a group read under it; a `POST` of a localization must name a version id learned as above; a `POST` of a review screenshot must name a product read under the app. Learned ids are one set, not kept per type: the check is that an id came from the workspace app, not that it belongs to the owner the request is about.
- A review screenshot by id is read when it was learned; it is committed (`PATCH`) or deleted only when the answer to a reservation sent through the same `AppGuard` returned its id, and only until a commit or `DELETE` of it succeeds. The source's screenshot is never changed, even when the source is a clone finished earlier in the same session.
- Subscriptions, in-app purchases, groups, availabilities, plan availabilities and IAP price schedules are only read by id, their sub-resources included; Purser creates some of them but never changes or deletes one.
- Rules and their tests come before the code that uses them.

### AssetTransfer

Downloading the source screenshot (Apple's image CDN, from the `imageAsset` template URL) and uploading to the URLs of `uploadOperations` leave `api.appstoreconnect.apple.com`. A small `AssetTransfer` in `Sources/Executor` does both: `https` only, only hosts ending in `.apple.com` or `.mzstatic.com`, no `Authorization` header, and no redirect is followed. Every upload `PUT` is audited (`httpSent` before, `httpReceived` after) like any write; the download is a read and is not audited. `ArchitectureTests` enforce that nothing else talks to those hosts.

## 4. Catalog and data model

**Sync.** One extra request per product and per group: the versions list with included localizations (up to 50 per version; a live or pending version at that limit is read again with its texts in full). That is about +10 requests for Juice and about +30 for an app with 22 subscriptions, far under the hourly budget. The versions read under a product make their ids known to `AppGuard`.

**Version roles.** For each owner Purser keeps:

| Role | States | Writable |
|---|---|---|
| Live | the newest `APPROVED` or `ACCEPTED` | no |
| Editable | `PREPARE_FOR_SUBMISSION`, `READY_FOR_REVIEW`, `REJECTED`, `DEVELOPER_REJECTED` | yes |
| In review | `WAITING_FOR_REVIEW`, `IN_REVIEW`, and any state Purser does not know | no (BLOCK) |
| Retired | `REPLACED_WITH_NEW_VERSION` | no; its texts are not kept |

The pending version is the newest editable or in-review version newer than Live.

**Domain.**

- `LocalizationOwner`: `.subscription(ascId)`, `.iap(ascId)`, `.group(ascId)`.
- `CellKey.localization(owner:locale:)`, storage key `T|S|<id>|<locale>` (`S`, `I`, `G` for the owner kind).
- `LocalizationRow`: `ascId`, owner, version id, `locale` and `text`, a `LocalizationText` with `name`, `description` (subscriptions and in-app purchases) and `customAppName` (groups).
- `CellKey.metadataVersion(owner:)`, storage key `V|S|<id>`, with `CellState.metadataVersion(MetadataVersion?)`: the version a plan creates is a cell of its own.
- `CellState.localization(live: LocalizationRow?, pending: LocalizationRow?, pendingVersion: MetadataVersion?)`: the locale's row in the live version, its row in the pending version and that pending (editable or in-review) version as a `MetadataVersion` (id, owner, number, state).
- Observed rows go through the existing observation and provenance machinery. A text changed in App Store Connect raises an EXTERNAL finding like a price does, and can be acknowledged.
- A GRDB migration adds the tables `metadata_version` (`asc_id`, `owner_key`, `number`, `state`, `last_sync`) and `subscription_group` (`asc_id`, `reference_name`, `first_sync`, `last_sync`); the texts of the live and pending versions live in the existing observation storage (kind LOCALIZATION).

**Catalog screen.** The detail of a subscription or an in-app purchase switches between *Prices* and *Localizations*; a group's texts are its *Group texts* row in the product list, above its subscriptions. The Localizations section is read only: a table with the locale, the live name and description (custom app name for a group) next to the pending ones, a *Change* badge (`Changed`, `New`, `Removed`) for each difference, and the versions as badges with a word, the version number and an icon (`Live`, `Draft`, `In review`, `Replaced`), never color alone.

## 5. Localization plans

**Plan origin** `PlanOrigin.localization` (`"L10N"`).

**Input row.** `product` (a Product ID or ASC id, or `group:<reference name>` / `group:<ASC id>`), `locale`, `name`, `description`, `custom_app_name` (groups only). An empty cell keeps the current text (L-D3).

**Sources.**

1. **Google Sheet / CSV.** The source *Table* of the New plan sheet's Localizations tab: a downloaded CSV template prefilled with the current texts (one row per owner and locale), edited outside Purser and loaded as a CSV or from a Google Sheet. The table has fixed columns, `product`, `locale`, `name`, `description` and `custom_app_name` (the header in any order), and is read by `LocalizationTable`, not through the price importer's column mapping.
2. **MCP.** `get_localizations` (access `read`) returns the current texts of chosen products or groups. `create_localization_plan` (access `local`) takes rows in the shape above and builds a Draft. Applying goes through the existing `apply_plan` and its gate.
3. **The app.** *Edit texts…* on the Catalog screen opens the New plan sheet on its Localizations tab (source *Edit in Purser*) for the selected product or group: the current texts per locale, each field editable, and *Add locale*; *Build plan* builds a Draft. The catalog's Localizations section only shows the texts.

**Diff.**

- The desired row is compared with the pending version, or with Live when there is none. Identical text gives no item.
- An owner with a pending version: a text item names the localization to `PATCH` when the locale is in that version, or the version to `POST` into when it is not (a version in review gets the items too, and N1 blocks them). An owner without any version gets BLOCK·PLAN.
- An approved owner (a Live version) without a pending version gets a `createMetadataVersion` item first; its text items depend on it (`dependsOn`) and carry only the owner and the locale. Whether Apple copies the Live texts into a new version is not known until a version of an approved product is created live for the first time (§8), so while `AppleConstants.newVersionCopiesLocalizations` is false the plan also carries every Live locale it does not change, with its Live text, as an id-less item of its own: the new version holds every Live text either way.
- The Executor resolves an id-less item after the version exists: it reads the owner once per apply run, once the read shows the version, and sends `PATCH` to the locale's row in it, `POST` to the version when it has no row for the locale, or nothing when the row already has the text (a text Apple copied).

**New write payloads.** `createMetadataVersion(owner:)` and `setLocalization(SetLocalization)` (owner, locale, the full desired text, and the localization id or the version id when they are known). Each is at most one ASC request at apply time.

**Rules.**

| # | Rule | Severity |
|---|---|---|
| N1 | The owner's version is in review | BLOCK · cell |
| N2 | Unknown locale code (list in `AppleConstants`) | BLOCK · cell |
| N3 | A text outside Apple's limit for its field (limits in `AppleConstants`: name 2-30 and description up to 45 characters for subscriptions and in-app purchases, from the App Store Connect help; groups have no published limit and are not checked until spike SL10n finds one) | BLOCK · cell |
| N4 | A new locale without a name | BLOCK · cell |
| N5 | A new version of an approved owner: it cannot be deleted through the API and customers see the change only after it is submitted in App Store Connect and approved | C1 |

Rule A5 (the product is in a state Purser writes in) also covers localization owners: a group owner must be a group read under the app.

Texts written into an existing editable version need no confirmation of their own: the plan's level comes from the other rules (C0, or C1 on a production workspace).

**Apply and verification.** New Executor branches with Touch ID and `httpSent`/`httpReceived`. No blind retry: after an uncertain answer a read decides, as for prices, and a text is sent again only when the read shows it was not written; a version `POST` is never sent again. Verification reads the version again and compares the texts exactly. A plan that created a version ends with a clear call to action: *Ready for review: submit in App Store Connect*.

**Plan screen.** Text cells show the locale, the text before and after with a badge for each changed field, and the kind of change (Edit, New locale, Carried over, New version); each field's before and after are in a Details popover (see the layout notes in CLAUDE.md).

## 6. Cloning

**Flow.** In the catalog the owner selects a subscription or an in-app purchase and chooses *Clone…*. The sheet starts with that product; *Add product* adds more. A sheet with numbered steps (`PlanFormParts`):

1. **Target** (subscriptions): the source's group (default) or a new group with a name; the source's level (default) or the end of the group.
2. **New Product IDs.** A suffix (for example `_AB3`) prefills `<source><suffix>` for the Product ID and the reference name; each can be edited. Validation as in `ProductCreationPlanner`, plus a check against the products the app has. The sheet says that Apple never allows reusing a Product ID, not even of a deleted product, and Purser cannot see those.
3. **What to copy**, all on by default: localizations, review screenshot, current prices, intro offers, promotional offers.
4. **Summary.** *Check* reads App Store Connect and lists the steps still missing (steps that cannot be taken now are listed as blocked, with the reason). After the acknowledgement that a Product ID can never be used again, *Clone with Touch ID* writes them (one Touch ID).

**What `ProductCreator` writes** (each request audited, never retried, what exists is skipped, so running it again finishes the rest):

1. A new group if chosen, and its localizations copied from the source group (into the new group's first version). Texts are copied per locale from the source's pending version where it has one, else from its live version.
2. The product with the copied attributes: period, `familySharable`, `reviewNote`, `groupLevel` (subscriptions); `inAppPurchaseType`, `familySharable`, `reviewNote` (in-app purchases).
3. Availability with the source's territories and its `availableInNewTerritories`.
4. The localizations, into the new product's first version (found with one GET).
5. The review screenshot: GET of the source's screenshot, download through `AssetTransfer`, reservation, upload of each operation, `PATCH uploaded=true` with the MD5 checksum.

**Draft plans** created after a sync of the new products:

| Draft | Content |
|---|---|
| Regular | one per clone: the source's current UPFRONT prices in the territories the clone is available in, mapped to the clone's price point of the same tier, without a start date (first price). MONTHLY prices and scheduled changes are not copied |
| Intro | the source's current and future UPFRONT intro offers, one Draft per offer shape (mode, duration, number of periods, dates; a free trial whose length differs by territory keeps the length of each). An offer running now starts on the clone at once and keeps its end date; a future one keeps both dates. A paid intro is copied at the source's prices, so it gets the same tier |
| Promo | one per UPFRONT promotional offer of the source; the offer code and the offer's name get the sheet's suffix (the one that prefills the Product IDs). The new code is checked by `OfferCodeAdvisor` (length, characters), against every code the workspace has seen (rule O1) and against the codes other clones of the same pass get |
| IAP | the source's current manual prices with the same base territory; future prices are not copied |

They are ordinary Drafts: reviewed, then applied, or cancelled and replaced by an import of the new prices. Each is titled with its clone and its place in the order of application; what they leave out (MONTHLY plan types, scheduled changes, future in-app purchase prices, an offer whose code cannot be used) is listed under *Not copied*. Building them opens none of them, so the sheet stays open. Preparing them again builds only the drafts whose title no unfinished plan (Draft, Stale, Applying, Scheduled, PartiallyApplied) carries yet.

**MCP.** `preview_clone` (access `local`, it reads App Store Connect like `preview_new_products`) shows what a clone would create; `clone_products` (access `ascWrite`) runs it under the same `MCPWriteGate` rules as `create_products`. A workspace runs one product creation or clone at a time (`ProductRuns`), whether it started in the window or over MCP, and a clone's run lasts until its price drafts are built: a second one (or *Prepare price drafts*) is refused before it reads anything, and `preview_clone` says that a clone is running instead of listing steps that are still changing.

## 7. Errors

| Situation | Handling |
|---|---|
| A text write fails | The item is `failed`; the plan ends `partiallyApplied` (or Stale when nothing was written); resume or replan as for prices |
| The version changed between planning and apply (submitted, or a version created in ASC) | Preflight syncs the owners again and runs the rules on the fresh catalog. A version in review (N1), a version item whose owner has a pending version now, or a text whose effective text changed (A4) is found by the preflight. At the first start the plan becomes Stale before anything is written; replan. On a resume the affected items still to run become Stale, and a plan-wide finding such as A4 also refuses the resume: the plan stays Applying and paused until it is aborted (it then ends PartiallyApplied, or Cancelled when nothing was written), and the rest is replanned after that. Text cells are compared by their effective text and whether their version went into review; a text planned into a version in preparation also needs that same version (by id), so one that was approved and followed by a new version makes it Stale. Localization ids are not compared. A change found during the apply, right before an item is sent, makes that item Stale and skips the items that depend on it |
| App Store Connect refuses `createMetadataVersion` (409, or another status that is not a 5xx) | The item is Stale with the status in its note (for 409: the owner may already have a pending version) and its texts are skipped; the rest of the plan runs; sync and replan |
| No answer, or a 5xx, to `createMetadataVersion` | The version `POST` is never sent twice: Purser waits and reads until App Store Connect shows the version (the plan pauses NETWORK when the waits run out). On resume after a crash, a version `POST` whose version the read does not show is Stale with its texts skipped |
| A clone fails part way | As today: steps that depend on the failed one are skipped; running the clone again creates only what is missing |
| A screenshot upload fails | The product stays without a screenshot and the report says so; on the next run in the same app session a missing screenshot is detected by GET and an uncommitted reservation is deleted and made again |
| An uncommitted screenshot reservation from an earlier app session (Purser was relaunched after a failed upload) | `AppGuard` lets Purser change only screenshots it reserved in the running session, so the reservation is left alone: the preview shows the screenshot step as blocked, and the run reports it as failed before anything is downloaded or sent, without counting it in the Touch ID prompt (no prompt when nothing else is to be written). The message tells the owner to remove the unfinished screenshot in App Store Connect (the product's Review Information) and run the clone again. Whether Apple replaces or expires such a reservation is spike question Q5b |
| The sync after a clone fails | No Drafts are created; the clone report offers *Prepare price drafts* again |

## 8. Spike SL10n

Recorded in `docs/spikes/SL10n.md` from `TEMPLATE-write.md`. Runs only on the "Purser Spike" group, before the first live write of this feature.

| # | Question |
|---|---|
| Q1 | Does a newly created subscription, IAP and group have version 1 in `PREPARE_FOR_SUBMISSION` right away? |
| Q2 | Create and modify a localization through v2 in that version (Purser never deletes one); what is returned and in which state, and whether a modified text reads back exactly as sent |
| Q3 | What does `POST` of a version do when an editable version exists (409 expected)? |
| Q4 | Apple's text limits and the accepted locale codes (unknown code, too long a text) |
| Q5 | The full review screenshot cycle: reservation, upload operations, commit, the resulting `assetDeliveryState` |
| Q5b | While a product has an uncommitted screenshot reservation, does Apple accept a new reservation (or replace the old one, or refuse it with 409)? Do uncommitted reservations expire, and after how long? |
| Q6 | A clone of `SpikeYearlyA` into the same group: the copied `groupLevel`, availability and texts read back as expected |

The "Purser Spike" group is never submitted, so it has no approved product. The spike only reads the versions of an approved Juice subscription; creating a version of an approved product happens live for the first time only after the owner's written approval, as with OQ1. Until the spike, `FakeASC`'s behaviour for versions and localizations is an assumption and the limits and locale list in `AppleConstants` are provisional.

## 9. Testing

- `AppGuard` rules and tests first.
- `FakeASC`: versions with states, localizations, version creation (409 while a pending version, editable or in review, exists), screenshot reservation and upload on a fake upload host.
- Planner: an empty cell keeps the text, identical text gives no item, `createMetadataVersion` precedes and is depended on, a group row uses `customAppName`.
- One test that satisfies and one that breaks each rule N1-N5, and the A5 extension for groups.
- Executor: apply and verification of text items, PATCH vs POST resolution after a read, a version created in the same run.
- Planner: the localization template round trip (export → import gives no items); Importer: parsing of the localization table.
- `MCPTools`: argument parsing and rendering of `get_localizations`, `create_localization_plan`, `preview_clone`, `clone_products`.
- Cloning: step planning, mapping of price tiers between source and clone, offer code suffixes, rerun after a partial failure.
- `ArchitectureTests`: `AssetTransfer` only in `Sources/Executor`; nothing else reaches the upload hosts; `MCPWriteGate` is still built only by `MCPToolRouter`.

## 10. Delivery

| Milestone | Content | Exit criterion |
|---|---|---|
| L1 | Read only: paths, `AppGuard`, sync of versions and texts, the Localizations section, MCP `get_localizations` | The Juice texts in Purser match the ASC UI; no write path added |
| L2 | Localization plans from all three sources into editable versions; spike SL10n (Q1-Q5) | An L10N plan on the "Purser Spike" group ends Effective, 0 Mismatch |
| L3 | `createMetadataVersion` for approved products (N5) | After written approval: one approved Juice subscription gets a new version with changed texts, ready for review in ASC |
| L4 | Cloning: the sheet, `ProductCreator` steps, `AssetTransfer`, Drafts, MCP `preview_clone` and `clone_products`; SL10n Q6 | A clone of `SpikeYearlyA` and `PurserSpikeLifetime` with all Drafts applied ends Effective |

## 11. Documentation to update

- [The v1 design](2026-10-09-purser-v1-design.md), §2: localization and review screenshots (for clones) move into scope; submitting for review stays outside.
- [docs/research/asc-api-paths.md](../research/asc-api-paths.md): the paths in §3.
- [docs/runbooks/mcp.md](../runbooks/mcp.md): the four new tools and their access.
- README: the feature list.

## 12. Known limitations

- One product creation or clone runs at a time per workspace. A second one, from the window or over MCP, is refused until the first ends; the windows do not grey out their buttons while a run started over MCP is in progress.
- Applying or resuming a plan is not refused while a product creation or clone runs (only the other way round: a creation or clone is refused while a plan is being applied).
- After an uncertain answer to a version `POST` (a lost answer or a 5xx), Purser takes the editable version a read shows as the one it created. A version created in App Store Connect at the same moment would be adopted and receive the plan's texts.
- An uncommitted review screenshot reservation from an earlier app session (Purser was relaunched after a failed upload) blocks the clone's screenshot step until the owner removes it in App Store Connect.
- A product's review note, which can hold sign-in details for App Review, is stored in the workspace catalog, and a clone's copy of it is in the audit as part of the request body.
- Verification and provenance assume that App Store Connect stores a `PATCH`ed text exactly as sent (spike SL10n confirms). If Apple normalizes a text, Purser's own write would show as Mismatch and as changed outside Purser.
