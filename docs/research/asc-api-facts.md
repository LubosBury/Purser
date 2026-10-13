# App Store Connect API: fact base for Purser

Status as of 2026-10-09. ASC OpenAPI spec 4.5.1 (zip Last-Modified 2026-10-06). Versions 4.5 and 4.5.1 did not change pricing [T4-28 H].

Every claim was researched against primary Apple sources and the ones that matter for the design were independently re-checked by a second, adversarial reviewer. Fact ids (e.g. `[T1-03 H]`) refer to the local research log; the letter is the confidence (H = Apple states it, M = secondary source or inferred from the schema, L = uncertain). **SPIKE** = unverified, test it before relying on it. **RECENT** = changed in 2025-26.

**There is no ASC API sandbox. Every write goes to production** [T3-06 H]. Spikes run on a throwaway subscription that is never submitted for review.

## 1. Write model per resource

### 1.1 Subscription regular price (`subscriptionPrices`)

- **Unit of write:** one `POST /v1/subscriptionPrices` = one change for one (subscription, territory, planType). Attributes `startDate`, `preserveCurrentPrice`, `planType`; relationship to a price point, which implies the territory [T3-01 H]. Price point ids are specific to one subscription and one territory [T3-22 H].
- **CRUD:** no PATCH. DELETE removes a scheduled (future) change [T3-03 H]. The relationship DELETE takes an array of ids; whether it is atomic is undocumented [T3-07 M]. A replacement is DELETE + POST and is not atomic.
- **Read:** `GET /v1/subscriptions/{id}/prices`, filters by territory and planType, max 200 per page, includes preserved old rows. The current price is the row with the latest `startDate` on or before today [T3-04 H, T3-05 M]. Idempotency key: (subscription, territory, planType, startDate). Read before writing, read again after any 409.
- **Scheduling:** one future change per storefront per plan type [T3-09 H]. Reportedly a second future change returns 409 instead of overwriting (SPIKE) [T3-10]. Reportedly DELETE returns 409 in the last hours before `startDate` (SPIKE) [T3-11]. Apple's docs conflict on the earliest date: the UI requires 1-2 days ahead, the API guide says `startDate: null` applies immediately [T3-12 M].
- **Price points:** `GET /v1/subscriptions/{id}/pricePoints` with `filter[territory]` (array) and `filter[planType]`, limit up to 8000; attributes `customerPrice`, `proceeds`, `proceedsYear2`. About 900 points per territory [T3-22 H].
- **Apple never adjusts subscription prices for FX or tax.** Subscriptions have no base territory and no automatic prices; equalized prices drift and re-equalizing is the developer's job [T3-25 H].
- **Rules derived:**
  - P1 Always send `planType` and `preserveCurrentPrice`; their defaults are undocumented [T3-02 H, T3-14 H].
  - P2 Plan type MONTHLY (RECENT, API 4.4): only on 1-year subscriptions, not in the USA, only where UPFRONT availability exists, and 12 x monthly must be 1.0-1.5x the upfront price [T3-02 H]. Apple's docs disagree on Singapore [T1-04 H].
  - P3 One pending change per cell. A replacement is an explicit DELETE+POST pair; block it close to `startDate` (Purser's own margin, not Apple's) [T3-11].
  - P4 Never send `startDate: null` for a subscription that already has prices [T3-12].
  - P5 A decrease cannot be reversed and applies to existing subscribers too [T3-16 H]. After a decrease, re-check every paid intro and promo price in that territory [T2-13 H].
  - P6 Predict price-increase consent per storefront. Consent is required when the increase is over 50 % and above the local threshold, when the subscriber already had an increase in the last 12 months, or in AUT, DEU, POL (RECENT, since 2025-09-03) and KOR [T3-17 H, T3-18 H]. Warn when increases stack [T3-13 H].
  - P7 Check `Subscription.state` before writing; a 409 was seen while a subscription was IN_REVIEW [T3-08 L].
- **Roles:** writing subscription prices needs Account Holder, Admin or App Manager; no read-only role is documented for price reads [T3-30 H, T3-34 L].

### 1.2 Introductory offer (`subscriptionIntroductoryOffers`)

- **Unit of write:** one POST = one record for one (subscription, territory[, planType]) [T1-08 M]. Required: `duration`, `numberOfPeriods`, `offerMode`, `subscription`. Optional: `startDate`, `endDate`, `targetSubscriptionPlanType`, price point, territory [T1-02 H].
- **CRUD:** PATCH can change only `endDate` [T1-03 H]. Any other change = delete + create, or end the current offer and create a future one. The relationship DELETE takes an array; atomicity unknown [T1-06 M]. There is no GET for a single offer: page `GET /v1/subscriptions/{id}/introductoryOffers` (max 200 per page) and match by id; `include` stops at 50 [T1-01 H].
- **Scheduling:** start and end are calendar dates; a start date of today starts immediately and the end time varies by region [T1-17 H]. One current and one future offer per storefront [T1-18 H]. What the API does with overlaps is unknown (SPIKE) [T1-19 L]. A September 2026 forum report describes an offer starting about 17 h late in APAC [T1-17].
- **Rules derived:**
  - I1 Always send the territory; omitting it returns 409 RELATIONSHIP.REQUIRED [T1-09 M].
  - I2 Validate mode, duration and periods against the subscription period [T1-12 H, T1-13 M]: for yearly subscriptions pay-as-you-go allows 1 year only; pay-up-front allows 1, 2, 3, 6 months or 1 year; free trial allows 3 days to 1 year; `numberOfPeriods` is 1 for every mode except pay-as-you-go.
  - I3 A paid offer's price point must belong to the same subscription, territory and plan type [T1-14 H, T1-10 M]. For pay-as-you-go it is the per-period price, for pay-up-front the price of the whole offer. The API does not fill prices, so the tool picks the point on each territory's ladder [T1-16 H].
  - I4 The intro price must be below the regular price and within tolerance of the intended discount. Apple defines intro offers as discounted but documents no API check [T1-15 M]. In a real catalog, absolute intro prices were found above the regular price in most territories after regular prices had been changed later.
  - I5 Never plan more than one current and one future offer per cell; use explicit end or delete steps, never rely on overwriting [T1-18].
  - I6 A regular price change does not touch intro offers. The tool must generate replacement offers starting on the price change date [T1-30 M].
  - I7 One intro offer per customer per subscription group [T1-24 H]. Korea collects consent when an offer converts to paid [T1-26 H].
  - I8 A 409 "Pricing change is not allowed" means an agreement is waiting to be accepted by the Account Holder [T1-22 M].
  - I9 Do not create offers inline through `PATCH /v1/subscriptions/{id}`; it may replace existing offers [T1-07 M].
- Intro offers do not go through App Review [T1-27 M]. In the UI, Marketing can also set up offers; the API role is undocumented [T3-31 M].

### 1.3 Promotional offer (`subscriptionPromotionalOffers`)

- **Unit of write:** one POST = one offer for one subscription with all territory prices inline (`included`) [T2-01 H]. Required: `duration`, `offerCode`, `name`, `numberOfPeriods`, `offerMode`, `prices`; optional `targetSubscriptionPlanType` [T2-02 H].
- **CRUD:** GET, PATCH, DELETE per offer; single price rows cannot be written on their own [T2-01 H]. PATCH can change prices only [T2-03 H]; whether it replaces or merges the price set is unknown (SPIKE) [T2-04]. Prices are read through `/{id}/prices`, max 200 per page [T2-14 H].
- **Scheduling:** none. No dates, no active flag [T2-05 H].
- **Rules derived:**
  - O1 `offerCode` is case-sensitive, unique, and can never be reused, even after deletion [T2-06 H]. Keep a registry of every code ever used.
  - O2 At most 10 offers per subscription (10 per payment configuration when MONTHLY is on) [T2-05 H].
  - O3 Give a price for every territory where the subscription is available; the API accepts gaps and their effect is undocumented [T2-10 M].
  - O4 Free-trial price rows carry only a territory; paid rows need a price point (SPIKE) [T2-11].
  - O5 A pay-as-you-go offer price must stay below the regular price; re-check on every regular-price decrease, otherwise purchases fail with `invalidOfferPrice` [T2-13 H].
  - O6 PATCH always sends the full price set, followed by a full read-back. What happens to customers already in an offer that is deleted or re-priced is undocumented [T2-24 M].
  - O7 Any change other than price means a new offer with a new identifier; the app's own references to identifiers must be updated by the developer [T2-20 H].
- **Redemption** is signed on the developer's server with the In-App Purchase key, never with the ASC API key [T2-17 H]. The ECDSA signature and the older StoreKit 2 options are deprecated in the iOS 26 SDK in favour of a compact JWS (back-deployed to iOS 15) [T2-15 H, T2-16 H]. The ASC write key plays no part in redemption.

### 1.4 In-app purchase price (non-renewing / lifetime)

- One price schedule resource per IAP: a base territory plus manual prices with start and end dates. A POST replaces the whole schedule; there is no DELETE of a single price (2026-09 validation, re-verify: **SPIKE**). Apple generates prices for territories without a manual price from the base territory and adjusts them for FX and tax; a manual price means the developer owns FX and tax for that territory.

## 2. Volume vs rate limits

- **Limit:** per API key over a rolling hour; Apple's example is 3,500 and "actual limits can vary". Every response carries `X-Rate-Limit` (`user-hour-lim`, `user-hour-rem`). Over the limit returns 429 RATE_LIMIT_EXCEEDED; no Retry-After header is documented [T3-26 H]. Read the limit from the header, do not hard-code it [T3-27 M].
- **Burst:** one community report describes 429s after ~300 requests in one minute (unverified) [T3-28 L].

| Operation | Approx. requests |
|---|---|
| Intro offers on 1 subscription x 175 territories | 175 POST + list pages + batched price point reads |
| Replace intro offers on 1 subscription x 175 | 175 DELETE + 175 POST |
| Regular price on 1 subscription everywhere | 175 POST (x2 plan types if MONTHLY is on), plus rebuilding its intro offers |
| One promo offer with 175 prices | 1 POST + ~2 reads |
| One IAP price schedule | 1 POST (SPIKE) |

A full intro rewrite on ~17 subscriptions is ~3,000 requests, about an hour at the example budget. Price point reads can be batched because `filter[territory]` takes an array [T3-22 H].

Apply pacing: throttle on `user-hour-rem`; keep ~10 % for verify reads; checkpoint after each item so a run can span hours and resume after a 429; show the request count and estimated duration on every plan; use a key not shared with other tools so their traffic does not eat the budget.

## 3. API keys and tokens

- **Team keys** cover all apps of the account whatever their role and cannot be limited to one app [T3-32 H].
- **Individual keys** carry the roles and app access of the user who created them. App Manager users can be restricted to specific apps, so an individual key of an app-restricted App Manager user is the only documented way to get an app-restricted key. One active individual key per user [T3-33 H].
- **JWT:** ES256, lifetime at most 20 minutes. The optional `scope` claim can restrict a token to listed GET requests; writes need an unscoped token, so per-endpoint guards must live in the tool's own code [T3-35 M].

## 4. Client libraries

- The spec is a ~7.5 MB OpenAPI document. Pin the client to the spec version and regenerate on upgrade [T4-28 H].
- No maintained Python client covers subscriptions [T4-33 M]. A TypeScript client generated from 4.5 exists (`@rage-against-the-pixel/app-store-connect-api`) [T4-29 H].
- **Swift was not researched** (the macOS decision came later). Candidates: Apple's `swift-openapi-generator` with the spec filtered to the ~20 operations needed, or a thin hand-written client with Codable models. **SPIKE.**

## 5. Spikes to run against a real account

Run on a throwaway subscription that is never submitted. Confirm key results once on an approved subscription, with rollback.

1. Intro offers: create without a territory; create overlapping offers and a third offer in one territory; DELETE a live offer vs PATCH `endDate` = today [T1-09, T1-18, T1-19, T1-21].
2. Omit `targetSubscriptionPlanType`, `planType`, `preserveCurrentPrice` and read back the defaults [T1-04, T3-02, T3-14].
3. Which intro requests are rejected: pay-as-you-go price at or above regular; price point from another territory or subscription; free trial with a price point; territory where the subscription is not available [T1-15, T1-10, T1-14, T1-05].
4. `startDate` today, past and null; which time zone defines "today" [T1-17, T3-12].
5. POST a regular price while another change is pending; DELETE a change close to its `startDate` [T3-10, T3-11].
6. Bulk relationship DELETE with an invalid id; does an inline create through `PATCH /v1/subscriptions/{id}` add or replace [T1-06, T3-07, T1-07, T3-08].
7. Promo offers: PATCH with only some territories; free trial with and without price point; reuse an identifier on another subscription [T2-04, T2-11, T2-10, T2-06].
8. Read the real `X-Rate-Limit`; push reads past 300 per minute [T3-27, T3-28].
9. Key roles: is a restricted App Manager key blocked on other apps; can a Marketing key read prices and write offers [T3-33, T3-34, T3-31].
10. IAP price schedule: read, replace the whole schedule, check FX behaviour of non-manual territories.
11. Swift client: generate from the filtered spec, check compile time and that the ~20 needed operations decode real responses.
12. Ask Apple DTS: what happens to customers already in a promo offer that is deleted or re-priced; what happens to a live pay-as-you-go intro offer when the regular price drops below it [T2-24, T1-30].

## 6. Sources

Apple ASC API:
- https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
- https://developer.apple.com/documentation/appstoreconnectapi/subscription-introductory-offers
- https://developer.apple.com/documentation/appstoreconnectapi/get-v1-subscriptions-_id_-introductoryoffers
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionintroductoryoffercreaterequest/data-data.dictionary/attributes-data.dictionary
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionintroductoryofferupdaterequest/data-data.dictionary/attributes-data.dictionary
- https://developer.apple.com/documentation/appstoreconnectapi/delete-v1-subscriptions-_id_-relationships-introductoryoffers
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionintroductoryofferinlinecreate
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionplantype
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionpromotionaloffercreaterequest/data-data.dictionary/attributes-data.dictionary
- https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-subscriptionpromotionaloffers-_id_
- https://developer.apple.com/documentation/appstoreconnectapi/get-v1-subscriptions-_id_-promotionaloffers
- https://developer.apple.com/documentation/appstoreconnectapi/subscriptionpricecreaterequest/data-data.dictionary/attributes-data.dictionary
- https://developer.apple.com/documentation/appstoreconnectapi/get-v1-subscriptions-_id_-prices
- https://developer.apple.com/documentation/appstoreconnectapi/delete-v1-subscriptionprices-_id_
- https://developer.apple.com/documentation/appstoreconnectapi/delete-v1-subscriptions-_id_-relationships-prices
- https://developer.apple.com/documentation/appstoreconnectapi/get-v1-subscriptions-_id_-pricepoints
- https://developer.apple.com/documentation/appstoreconnectapi/managing-auto-renewable-subscriptions
- https://developer.apple.com/documentation/appstoreconnectapi/configuring-subscription-prices-across-territories
- https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits
- https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
- https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-4-release-notes
- https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-5-1-release-notes

Apple help and StoreKit:
- https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions
- https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-promotional-offers-for-auto-renewable-subscriptions
- https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions
- https://developer.apple.com/help/app-store-connect/reference/pricing-and-availability/app-store-pricing-and-availability-start-times-by-country-or-region
- https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-price-increase-thresholds
- https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/consent-for-subscription-offer-conversions
- https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api
- https://developer.apple.com/help/app-store-connect/manage-your-team/edit-access-to-apps
- https://developer.apple.com/help/account/access/roles
- https://developer.apple.com/documentation/storekit/implementing-introductory-offers-in-your-app
- https://developer.apple.com/documentation/storekit/implementing-promotional-offers-in-your-app
- https://developer.apple.com/documentation/storekit/skerror/code/invalidofferprice
- https://developer.apple.com/documentation/storekit/generating-jws-to-sign-app-store-requests

Community (lower weight):
- https://developer.apple.com/forums/thread/731014
- https://developer.apple.com/forums/thread/110457
