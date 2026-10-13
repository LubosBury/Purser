# App Store Connect API paths Purser calls

The source of truth for the endpoints the code may call. `make check-endpoints` checks every `METHOD /path` in this file against Apple's OpenAPI specification (pinned to 4.5.1). A new path is added here first, then to `ASCPath` and the `AppGuard` rules.

## Reading

| Purpose | Method and path | Note |
|---|---|---|
| App | `GET /v1/apps/{id}` | bundleId for rule A1 |
| Territories | `GET /v1/territories` | `limit=200`; id + currency |
| Groups | `GET /v1/apps/{id}/subscriptionGroups` | |
| Subscriptions | `GET /v1/subscriptionGroups/{id}/subscriptions` | state, subscriptionPeriod, productId, name |
| Availability | `GET /v1/subscriptions/{id}/subscriptionAvailability`, `GET /v1/subscriptionAvailabilities/{id}/availableTerritories` | |
| Plan availability | `GET /v1/subscriptions/{id}/planAvailabilities` | `monthlyPlanAvailable` is read from it |
| Regular prices | `GET /v1/subscriptions/{id}/prices` | `include=subscriptionPricePoint,territory`, `limit=200` |
| Intro | `GET /v1/subscriptions/{id}/introductoryOffers` | `include=subscriptionPricePoint,territory`, `limit=200`; there is no GET for a single offer [T1-01] |
| Promo | `GET /v1/subscriptions/{id}/promotionalOffers`, `GET /v1/subscriptionPromotionalOffers/{id}/prices` | prices with `include=subscriptionPricePoint,territory` |
| Price points | `GET /v1/subscriptions/{id}/pricePoints` | `filter[territory]=USA,CZE,…`, `filter[planType]`, `include=territory`, `limit=8000` |
| Equalized prices | `GET /v1/subscriptionPricePoints/{id}/equalizations` | the prices of all territories from the price in one; `AppGuard` allows it only for a price point of an allowed subscription |
| IAP | `GET /v1/apps/{id}/inAppPurchasesV2` | |
| IAP schedule | `GET /v2/inAppPurchases/{id}/iapPriceSchedule`, `GET /v1/inAppPurchasePriceSchedules/{id}/manualPrices`, `GET /v1/inAppPurchasePriceSchedules/{id}/baseTerritory` | spike S10 |
| IAP automatic prices | `GET /v1/inAppPurchasePriceSchedules/{id}/automaticPrices` | `include=territory,inAppPurchasePricePoint`, `limit=200`; only an observation in spike S10 and rule L2 (provenance APPLE); the sync does not read it in v1 |
| IAP price points | `GET /v2/inAppPurchases/{id}/pricePoints` | `filter[territory]` |

## Writing plans

Only `Executor` sends these, each preceded by an `httpSent` audit event.

| Purpose | Method and path | Note |
|---|---|---|
| Regular price | `POST /v1/subscriptionPrices`, `DELETE /v1/subscriptionPrices/{id}` | attributes startDate, preserveCurrentPrice, planType [T3-01] |
| Intro | `POST /v1/subscriptionIntroductoryOffers`, `PATCH /v1/subscriptionIntroductoryOffers/{id}` (endDate only), `DELETE /v1/subscriptionIntroductoryOffers/{id}` | |
| Promo | `POST /v1/subscriptionPromotionalOffers` (prices as `included` with the local ids `${price-N}`), `PATCH /v1/subscriptionPromotionalOffers/{id}`, `DELETE /v1/subscriptionPromotionalOffers/{id}` | [T2-01, T2-02] |
| IAP schedule | `POST /v1/inAppPurchasePriceSchedules` (manual prices as `included`) | spike S10 |

## Creating products

Only `ProductCreator` sends these: `POST /v1/subscriptionGroups`, `POST /v1/subscriptions`, `POST /v1/subscriptionAvailabilities`, `POST /v2/inAppPurchases`, `POST /v1/inAppPurchaseAvailabilities`. `AppGuard` allows creating a group and a purchase only with the relationship `app` = the workspace's app, a subscription only in a group read under it, and an availability only for an allowed product. Apple's behaviour for these five requests is not verified by a spike.
