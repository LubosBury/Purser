# App Store Connect API paths Purser calls

The source of truth for the endpoints the code may call. `make check-endpoints` checks every `METHOD /path` in this file against Apple's OpenAPI specification (pinned to 4.5.1). A new path is added here first, then to `ASCPath` and the `AppGuard` rules.

## Reading

| Purpose | Method and path | Note |
|---|---|---|
| App | `GET /v1/apps/{id}` | bundleId for rule A1 |
| Territories | `GET /v1/territories` | `limit=200`; id + currency |
| Groups | `GET /v1/apps/{id}/subscriptionGroups` | |
| Subscriptions | `GET /v1/subscriptionGroups/{id}/subscriptions` | state, subscriptionPeriod, productId, name; familySharable, reviewNote, groupLevel (copied by a clone) |
| Availability | `GET /v1/subscriptions/{id}/subscriptionAvailability`, `GET /v1/subscriptionAvailabilities/{id}/availableTerritories` | `availableInNewTerritories` is copied by a clone; 404 = no availability yet |
| Plan availability | `GET /v1/subscriptions/{id}/planAvailabilities` | `monthlyPlanAvailable` is read from it |
| Regular prices | `GET /v1/subscriptions/{id}/prices` | `include=subscriptionPricePoint,territory`, `limit=200` |
| Intro | `GET /v1/subscriptions/{id}/introductoryOffers` | `include=subscriptionPricePoint,territory`, `limit=200`; there is no GET for a single offer [T1-01] |
| Promo | `GET /v1/subscriptions/{id}/promotionalOffers`, `GET /v1/subscriptionPromotionalOffers/{id}/prices` | prices with `include=subscriptionPricePoint,territory` |
| Price points | `GET /v1/subscriptions/{id}/pricePoints` | `filter[territory]=USA,CZE,…`, `filter[planType]`, `include=territory`, `limit=8000` |
| Equalized prices | `GET /v1/subscriptionPricePoints/{id}/equalizations` | the prices of all territories from the price in one; `AppGuard` allows it only for a price point of an allowed subscription |
| IAP | `GET /v1/apps/{id}/inAppPurchasesV2` | familySharable, reviewNote (copied by a clone) |
| IAP schedule | `GET /v2/inAppPurchases/{id}/iapPriceSchedule`, `GET /v1/inAppPurchasePriceSchedules/{id}/manualPrices`, `GET /v1/inAppPurchasePriceSchedules/{id}/baseTerritory` | spike S10 |
| IAP automatic prices | `GET /v1/inAppPurchasePriceSchedules/{id}/automaticPrices` | `include=territory,inAppPurchasePricePoint`, `limit=200`; only an observation in spike S10 and rule L2 (provenance APPLE); the sync does not read it in v1 |
| IAP price points | `GET /v2/inAppPurchases/{id}/pricePoints` | `filter[territory]` |
| IAP availability | `GET /v2/inAppPurchases/{id}/inAppPurchaseAvailability`, `GET /v1/inAppPurchaseAvailabilities/{id}/availableTerritories` | read only when cloning; 404 = no availability yet |
| Review screenshot | `GET /v1/subscriptions/{id}/appStoreReviewScreenshot`, `GET /v2/inAppPurchases/{id}/appStoreReviewScreenshot` | read only when cloning; `data: null` or 404 = no screenshot; `imageAsset.templateUrl` holds `{w}`, `{h}` and `{f}` |
| Versions with texts | `GET /v1/subscriptions/{id}/versions`, `GET /v2/inAppPurchases/{id}/versions`, `GET /v1/subscriptionGroups/{id}/versions` | `include=localizations`, `limit[localizations]=50`, `limit=200`; the version number is the attribute `version`; the texts of the live and the pending version are kept |
| Texts of one version | `GET /v1/subscriptionVersions/{id}/localizations`, `GET /v1/inAppPurchaseVersions/{id}/localizations`, `GET /v1/subscriptionGroupVersions/{id}/localizations` | `limit=200`; only when the version's `localizations` relationship lists exactly 50 ids (the include limit) |

By id, `AppGuard` lets only reads through for subscriptions, in-app purchases, groups, availabilities, plan availabilities and IAP price schedules, their sub-resources included: Purser creates some of them (a `POST` without an id) but never changes or deletes one.

## Writing plans

Only `Executor` sends these, each preceded by an `httpSent` audit event.

| Purpose | Method and path | Note |
|---|---|---|
| Regular price | `POST /v1/subscriptionPrices`, `DELETE /v1/subscriptionPrices/{id}` | attributes startDate, preserveCurrentPrice, planType [T3-01] |
| Intro | `POST /v1/subscriptionIntroductoryOffers`, `PATCH /v1/subscriptionIntroductoryOffers/{id}` (endDate only), `DELETE /v1/subscriptionIntroductoryOffers/{id}` | |
| Promo | `POST /v1/subscriptionPromotionalOffers` (prices as `included` with the local ids `${price-N}`), `PATCH /v1/subscriptionPromotionalOffers/{id}`, `DELETE /v1/subscriptionPromotionalOffers/{id}` | [T2-01, T2-02] |
| IAP schedule | `POST /v1/inAppPurchasePriceSchedules` (manual prices as `included`) | spike S10 |

## Writing localizations

Only `Executor` sends these (L10N plans), each preceded by an `httpSent` audit event. `AppGuard` lets a POST name only a version id, and a PATCH only a localization id, that Purser learned from an answer to a request under the workspace app (a read, or the answer to a POST); a PATCH body must name the same id.

| Purpose | Method and path | Note |
|---|---|---|
| Subscription texts | `POST /v2/subscriptionLocalizations`, `PATCH /v2/subscriptionLocalizations/{id}` | `name`, `locale`, `description`; relationship `version` (`subscriptionVersions`) |
| In-app purchase texts | `POST /v2/inAppPurchaseLocalizations`, `PATCH /v2/inAppPurchaseLocalizations/{id}` | `name`, `locale`, `description`; relationship `version` (`inAppPurchaseVersions`) |
| Group texts | `POST /v2/subscriptionGroupLocalizations`, `PATCH /v2/subscriptionGroupLocalizations/{id}` | `name`, `locale`, `customAppName`; relationship `version` (`subscriptionGroupVersions`) |
| New version | `POST /v1/subscriptionVersions`, `POST /v1/inAppPurchaseVersions`, `POST /v1/subscriptionGroupVersions` | an L10N plan item (rule N5): an approved owner without a version in preparation; no attributes, only the owner, which `AppGuard` requires to be a subscription or in-app purchase read under the app or a group read under it; 409 while the owner has a pending version (expected; spike SL10n Q3) |

Spike SL10n is to send `POST /v1/subscriptionVersions` through the DEBUG `SpikeProbe` as well (Q3, while an editable version exists); it has not run yet. `AppGuard` allows a version POST only for an allowed product or a group read under the app. Purser never deletes a localization (spec L-D4): `AppGuard` refuses every DELETE of one.

## Creating products

Only `ProductCreator` sends these: `POST /v1/subscriptionGroups`, `POST /v1/subscriptions`, `POST /v1/subscriptionAvailabilities`, `POST /v2/inAppPurchases`, `POST /v1/inAppPurchaseAvailabilities`. `AppGuard` allows creating a group and a purchase only with the relationship `app` = the workspace's app, a subscription only in a group read under it, and an availability only for an allowed product. Apple's behaviour for these requests is not verified yet; spike SL10n (Q5, Q6) will record it in [docs/spikes/SL10n.md](../spikes/SL10n.md).

## Cloning products

Only `ProductCreator` sends these, after one Touch ID for the whole clone; every request has its `httpSent` and `httpReceived` events and is never retried. The product, its availability and a new group use the requests of "Creating products" (with the source's `familySharable`, `reviewNote` and `groupLevel`); the texts go into the new product's first version through `POST /v2/subscriptionLocalizations`, `POST /v2/inAppPurchaseLocalizations` and `POST /v2/subscriptionGroupLocalizations`.

| Purpose | Method and path | Note |
|---|---|---|
| Review screenshot of a subscription | `POST /v1/subscriptionAppStoreReviewScreenshots`, `PATCH /v1/subscriptionAppStoreReviewScreenshots/{id}`, `DELETE /v1/subscriptionAppStoreReviewScreenshots/{id}` | reservation (`fileName`, `fileSize`, relationship `subscription`) answers `uploadOperations`; the commit sends `uploaded: true` and the MD5 of the file in `sourceFileChecksum`; DELETE only for a reservation an earlier run left uncommitted |
| Review screenshot of an in-app purchase | `POST /v1/inAppPurchaseAppStoreReviewScreenshots`, `PATCH /v1/inAppPurchaseAppStoreReviewScreenshots/{id}`, `DELETE /v1/inAppPurchaseAppStoreReviewScreenshots/{id}` | the same with the relationship `inAppPurchaseV2` |

`AppGuard` lets a reservation through only when it names a product read under the workspace app. By id, a screenshot learned by a read is only read; `PATCH` (the commit, naming the same screenshot) and `DELETE` need an id that the answer to a reservation sent through the same `AppGuard` returned, until a commit or `DELETE` of it succeeds, so the source product's screenshot (even a clone finished earlier in the session) is never changed. Two kinds of request leave `api.appstoreconnect.apple.com`: the download of the source image from Apple's image CDN (the `templateUrl` with the image's width, height and `png`) and the upload `PUT`s to the URLs of `uploadOperations`. Both go only through `AssetTransfer` in `Sources/Executor`: `https`, hosts ending in `.apple.com` or `.mzstatic.com`, no `Authorization` header, every `PUT` audited with its scheme, host, part, offset and length (never the path or the query, which can carry the upload's secret).
