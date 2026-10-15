import Foundation

/// What a tool may touch. The app refuses `.ascWrite` tools unless the owner allowed writes over MCP in Settings.
public enum ToolAccess: String, Sendable, Codable {
    /// Reads the local catalog, plans and findings.
    case read
    /// Changes local data (drafts, acks) or reads App Store Connect (sync). Never writes to App Store Connect.
    case local
    /// Writes to App Store Connect.
    case ascWrite
}

public struct ToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var access: ToolAccess

    public init(name: String, description: String, inputSchema: JSONValue, access: ToolAccess) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.access = access
    }
}

/// Every tool Purser offers over MCP. The helper answers `tools/list` from this list without the app; the app's
/// router implements each name (a test in the app target's router would be out of reach, so `MCPToolName` keeps
/// both sides on the same spelling).
public enum MCPToolName: String, CaseIterable, Sendable {
    case status = "purser_status"
    case listProducts = "list_products"
    case getPrices = "get_prices"
    case getLocalizations = "get_localizations"
    case listFindings = "list_findings"
    case listPlans = "list_plans"
    case getPlan = "get_plan"
    case applyStatus = "apply_status"
    case syncCatalog = "sync_catalog"
    case createRegularPricePlan = "create_regular_price_plan"
    case createIAPPricePlan = "create_iap_price_plan"
    case createIntroOfferPlan = "create_intro_offer_plan"
    case createPromoOfferPlan = "create_promo_offer_plan"
    case createLocalizationPlan = "create_localization_plan"
    case getImportFormat = "get_import_format"
    case exportImportTemplate = "export_import_template"
    case createImportPlan = "create_import_plan"
    case replan = "replan"
    case cancelPlan = "cancel_plan"
    case ackFindings = "ack_findings"
    case withdrawWritten = "withdraw_written"
    case replanRest = "replan_rest"
    case closePlan = "close_plan"
    case applyPlan = "apply_plan"
    case resumePlan = "resume_plan"
    case pauseApply = "pause_apply"
    case abortPlan = "abort_plan"
    case previewProducts = "preview_new_products"
    case createProducts = "create_products"
    case previewClone = "preview_clone"
    case cloneProducts = "clone_products"
}

public enum ToolCatalog {
    public static let all: [ToolDefinition] = MCPToolName.allCases.map(definition)

    public static func definition(named name: String) -> ToolDefinition? {
        MCPToolName(rawValue: name).map(definition)
    }

    // MARK: Schema pieces

    private static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
                 "additionalProperties": false])
    }

    private static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static func bool(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    private static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    private static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }

    private static let planId = string("Plan id, as list_plans returns it.")
    private static let date = "ISO date YYYY-MM-DD."
    private static let territoryList = strings("ISO 3166-1 alpha-3 territory codes, e.g. [\"USA\", \"CZE\"].")
    private static let prices: JSONValue = [
        "type": "array",
        "description": "Customer prices in the territory's own currency. Purser snaps each amount to Apple's nearest price point and shows the result in the plan.",
        "items": ["type": "object",
                  "properties": ["territory": ["type": "string", "description": "ISO 3166-1 alpha-3, e.g. USA."],
                                 "amount": ["type": "number", "description": "Price in the territory's currency, e.g. 9.99."]],
                  "required": ["territory", "amount"], "additionalProperties": false],
    ]
    private static let offerModes = ["FREE_TRIAL", "PAY_UP_FRONT", "PAY_AS_YOU_GO"]
    private static let offerDurations = ["THREE_DAYS", "ONE_WEEK", "TWO_WEEKS", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
    private static let subscriptionPeriods = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
    private static let pricingProperties: [String: JSONValue] = [
        "percent_of_regular": ["type": "number",
                               "description": "Offer price as a percentage of the regular price, between 0 and 100 (80 = the customer pays 80 %). Not for FREE_TRIAL."],
        "prices": prices,
    ]
    private static let confirmation: [String: JSONValue] = [
        "typed_app_name": string("Level C1 and C2: the workspace name exactly as purser_status returns it."),
        "reason": string("Level C2: why this change is made (stored in the audit)."),
        "acknowledge_exclusions": bool("Required when the plan has excluded cells: true confirms they will not be written."),
        "checked_risk_classes": strings("Level C2: every risk class get_plan lists for this plan."),
    ]

    private static let confirmationNote = " get_plan tells which confirmation fields this plan needs; when one is missing or wrong the plan returns to Draft and nothing is written. Writes to App Store Connect have no sandbox and are never retried automatically."

    // MARK: Definitions

    private static func definition(_ name: MCPToolName) -> ToolDefinition {
        func tool(_ description: String, _ input: JSONValue = schema(), _ access: ToolAccess) -> ToolDefinition {
            ToolDefinition(name: name.rawValue, description: description, inputSchema: input, access: access)
        }
        switch name {
        case .status:
            return tool("The state of the Purser app: locked or not, the open workspace, the last sync, open findings, plans by state, a running apply and whether writes over MCP are allowed. Call this first.", schema(), .read)
        case .listProducts:
            return tool("Subscriptions (with their groups and periods) and in-app purchases of the open workspace, from the last sync.", schema(), .read)
        case .getPrices:
            return tool("Current and scheduled prices of one product per territory, with intro offers and promotional offers of a subscription.",
                        schema(["product": string("ASC id or Product ID of a subscription or in-app purchase."),
                                "territories": territoryList], required: ["product"]), .read)
        case .getLocalizations:
            return tool("Localized texts from the last sync: name and description of subscriptions and in-app purchases, name and custom app name of subscription groups, per locale. Each owner shows its live version and its pending version (being prepared or in review) with the state. Read only.",
                        schema(["products": strings("Product IDs or ASC ids of subscriptions and in-app purchases, or group:<reference name> of a subscription group. Omit or leave empty for every product and group."),
                                "locales": strings("Only these locales, e.g. [\"en-US\", \"cs\"]. Omit for every locale.")]), .read)
        case .listFindings:
            return tool("Open findings: changes made outside Purser, broken schedules and invariant violations.", schema(), .read)
        case .listPlans:
            return tool("Plans of the open workspace, newest first.",
                        schema(["states": strings("Only these states: draft, applying, stale, scheduled, effective, partiallyApplied, closed, cancelled.")]), .read)
        case .getPlan:
            return tool("One plan: state, verdicts (BLOCK, WARN, confirmations), the confirmation apply_plan needs and the rows it would write.",
                        schema(["plan_id": planId,
                                "flagged_only": bool("Only rows with a flag or a verdict."),
                                "max_rows": integer("At most this many rows (default 200).")], required: ["plan_id"]), .read)
        case .applyStatus:
            return tool("Progress of the apply or resume in this workspace: phase, items done, rate budget, and the outcome of the last confirmation.", schema(), .read)
        case .syncCatalog:
            return tool("Reads the catalog from App Store Connect now (read-only requests) and re-evaluates plans and findings. Can take a few minutes.", schema(), .local)
        case .createRegularPricePlan:
            return tool("Builds a Draft plan that changes the regular price of subscriptions. Nothing is written until apply_plan. Read the result with get_plan.",
                        schema(["subscription_ids": strings("ASC ids or Product IDs of the subscriptions."),
                                "prices": prices,
                                "start_date": string("\(date) Omit to start as soon as App Store Connect allows."),
                                "preserve_current_price": bool("For price increases: true keeps existing subscribers on their current price, false raises it for them too. Required when the plan contains an increase."),
                                "territories": territoryList,
                                "reason": string("Note stored with the plan.")],
                               required: ["subscription_ids", "prices"]), .local)
        case .createIAPPricePlan:
            return tool("Builds a Draft plan that replaces the price schedule of one in-app purchase. Nothing is written until apply_plan.",
                        schema(["iap": string("ASC id or Product ID of the in-app purchase."),
                                "base_territory": string("Base territory of the schedule, e.g. USA; Apple equalizes the other territories from it."),
                                "prices": prices,
                                "start_date": string("\(date) Omit to start at once."),
                                "reason": string("Note stored with the plan.")],
                               required: ["iap", "base_territory", "prices"]), .local)
        case .createIntroOfferPlan:
            var properties: [String: JSONValue] = [
                "subscription_ids": strings("ASC ids or Product IDs of the subscriptions."),
                "mode": choice(offerModes, "Offer mode."),
                "duration": choice(offerDurations, "Length of one offer period."),
                "number_of_periods": integer("Number of periods (1 for FREE_TRIAL and PAY_UP_FRONT)."),
                "start_date": string("\(date) Omit to start at once."),
                "end_date": string("\(date) Omit for no end."),
                "nominal_discount": ["type": "number", "description": "Advertised discount in percent (20 = \"-20 %\"), checked against the effective one."],
                "territories": territoryList,
                "canary": bool("true writes a small canary first (default false)."),
                "reason": string("Note stored with the plan."),
            ]
            properties.merge(pricingProperties) { _, new in new }
            return tool("Builds a Draft plan that creates introductory offers. Give percent_of_regular or prices unless the mode is FREE_TRIAL. Nothing is written until apply_plan.",
                        schema(properties, required: ["subscription_ids", "mode", "duration", "number_of_periods"]), .local)
        case .createPromoOfferPlan:
            var properties: [String: JSONValue] = [
                "action": choice(["create", "reprice", "delete"], "What to do with the promotional offer."),
                "subscription": string("create: ASC id or Product ID of the subscription."),
                "offer_code": string("create: the offer identifier the app uses (never reusable after deletion)."),
                "name": string("create: reference name of the offer."),
                "mode": choice(offerModes, "create: offer mode."),
                "duration": choice(offerDurations, "create: length of one offer period."),
                "number_of_periods": integer("create: number of periods."),
                "offer_id": string("reprice, delete: ASC id of the promotional offer (get_prices lists them)."),
                "confirmed_unused_by_app": bool("delete: true confirms no shipped app version still uses this offer."),
                "reason": string("Note stored with the plan."),
            ]
            properties.merge(pricingProperties) { _, new in new }
            return tool("Builds a Draft plan that creates, re-prices or deletes a promotional offer. Nothing is written until apply_plan.",
                        schema(properties, required: ["action"]), .local)
        case .createLocalizationPlan:
            let row: JSONValue = [
                "type": "object",
                "properties": [
                    "product": ["type": "string", "description": "Product ID or ASC id of a subscription or in-app purchase, or group:<reference name> for a subscription group."],
                    "locale": ["type": "string", "description": "App Store locale code, e.g. en-US, cs, de-DE."],
                    "name": ["type": "string", "description": "Display name. Empty or omitted keeps the current one; a new locale needs it."],
                    "description": ["type": "string", "description": "Subscription and in-app purchase only. Empty or omitted keeps the current one."],
                    "custom_app_name": ["type": "string", "description": "Subscription group only: the custom app name. Empty or omitted keeps the current one."],
                ],
                "required": ["product", "locale"], "additionalProperties": false,
            ]
            return tool("Builds a Draft plan that changes localized names and descriptions of subscriptions and in-app purchases and the name and custom app name of subscription groups. Purser writes into a version that is still in preparation; for an approved product or group without one, the plan first creates a new version (rule N5, confirmation C1), which cannot be deleted through the API and which the owner submits in App Store Connect. An empty or omitted field keeps the current text and no locale is ever removed. A row Purser cannot place refuses the whole call. Nothing is written until apply_plan.",
                        schema(["rows": ["type": "array", "items": row, "description": "One entry per product or group and locale."],
                                "reason": string("Note stored with the plan.")], required: ["rows"]), .local)
        case .getImportFormat:
            return tool("The layout create_import_plan expects: the first data row, the country and currency columns and what each price column writes (product, kind of price, check-only or not).", schema(), .read)
        case .exportImportTemplate:
            return tool("Returns the workspace's import table as CSV, filled with what is live today: one row per territory (country name, currency) and the columns of the saved import mapping. Edit the values and hand the CSV to create_import_plan; an unedited table plans nothing. The saved mapping is never changed. Only a workspace without any mapping gets the default one (one regular-price column per subscription).", schema(), .local)
        case .createImportPlan:
            return tool("Builds one Draft plan from a whole price table (CSV in the layout of get_import_format), read by Purser's importer: it checks country names and currencies, snaps prices to Apple's price points and compares check-only columns with the live prices. An empty cell carries no value (the price stays), except in an in-app purchase column, where a territory without a value loses its manual price; the answer lists both under checks. Prefer this to the per-product tools for more than a few prices. Nothing is written until apply_plan.",
                        schema(["csv_path": string("Absolute path of a .csv file on this Mac. Give this or csv_text."),
                                "csv_text": string("The CSV itself. Give this or csv_path."),
                                "validate_only": bool("true reads and checks the table and builds no plan."),
                                "write_columns": strings("Column letters to write, e.g. [\"C\", \"D\"]. Omit for every column the mapping marks as written."),
                                "products": strings("Only these products (ASC ids or Product IDs)."),
                                "territories": territoryList,
                                "start_date": string("\(date) Omit to start as soon as App Store Connect allows."),
                                "preserve_current_price": bool("For price increases: true keeps existing subscribers on their current price, false raises it for them too. Required when the plan contains an increase."),
                                "canary": bool("true writes a small canary first (default false)."),
                                "reason": string("Note stored with the plan.")]), .local)
        case .replan:
            return tool("Re-plans a Draft or Stale plan against the latest catalog; returns the id of the new Draft.", schema(["plan_id": planId], required: ["plan_id"]), .local)
        case .cancelPlan:
            return tool("Cancels a Draft plan. Nothing was written, nothing is written.", schema(["plan_id": planId], required: ["plan_id"]), .local)
        case .ackFindings:
            return tool("Acknowledges a group of findings with a reason (stored in the audit). Does not change App Store Connect.",
                        schema(["group_id": string("Group id from list_findings."), "reason": string("Why the findings are accepted.")],
                               required: ["group_id", "reason"]), .local)
        case .withdrawWritten:
            return tool("Builds a WITHDRAW Draft that removes the future-dated items a Scheduled or PartiallyApplied plan already wrote. Nothing is written until that Draft is applied.",
                        schema(["plan_id": planId], required: ["plan_id"]), .local)
        case .replanRest:
            return tool("Builds a new Draft for the items a PartiallyApplied plan did not write.", schema(["plan_id": planId], required: ["plan_id"]), .local)
        case .closePlan:
            return tool("Closes a PartiallyApplied plan with a reason (stored in the audit). Writes nothing.",
                        schema(["plan_id": planId, "reason": string("Why the plan is closed.")], required: ["plan_id", "reason"]), .local)
        case .applyPlan:
            var properties = confirmation
            properties["plan_id"] = planId
            return tool("WRITES TO APP STORE CONNECT: applies a Draft plan. Price changes of approved products take effect without App Review. Returns when the apply ends or after about 20 seconds; then poll apply_status." + confirmationNote,
                        schema(properties, required: ["plan_id"]), .ascWrite)
        case .resumePlan:
            var properties = confirmation
            properties["plan_id"] = planId
            return tool("WRITES TO APP STORE CONNECT: resumes a paused apply. Returns when it ends or after about 20 seconds; then poll apply_status." + confirmationNote,
                        schema(properties, required: ["plan_id"]), .ascWrite)
        case .pauseApply:
            return tool("Pauses the running apply after the request in flight.", schema(), .local)
        case .abortPlan:
            return tool("Aborts a paused apply: the items already written stay written, the rest is dropped.", schema(["plan_id": planId], required: ["plan_id"]), .local)
        case .previewProducts, .createProducts:
            let products = schema([
                "group_name": string("Reference name of the subscription group; created when the app has none of that name."),
                "subscriptions": ["type": "array", "items": ["type": "object",
                                  "properties": ["product_id": ["type": "string"], "name": ["type": "string"],
                                                 "period": .object(["type": "string", "enum": .array(subscriptionPeriods.map(JSONValue.string))])],
                                  "required": ["product_id", "name", "period"], "additionalProperties": false]],
                "non_consumables": ["type": "array", "items": ["type": "object",
                                    "properties": ["product_id": ["type": "string"], "name": ["type": "string"]],
                                    "required": ["product_id", "name"], "additionalProperties": false]],
            ])
            if name == .previewProducts {
                return tool("Lists the steps create_products would take for these products, after reading what the app already has. Writes nothing.", products, .local)
            }
            return tool("WRITES TO APP STORE CONNECT: creates the subscription group, subscriptions and non-consumables that do not exist yet. A Product ID can never be used again, even after deletion. New products still need metadata and App Review in App Store Connect.", products, .ascWrite)
        case .previewClone, .cloneProducts:
            let clone = schema([
                "products": ["type": "array", "description": "The products to clone: subscriptions and in-app purchases.",
                             "items": ["type": "object",
                                       "properties": ["source": ["type": "string", "description": "ASC id or Product ID of the product to clone."],
                                                      "product_id": ["type": "string", "description": "Product ID of the clone. Default: the source's Product ID followed by the suffix."],
                                                      "name": ["type": "string", "description": "Reference name of the clone. Default: the source's name followed by the suffix."]],
                                       "required": ["source"], "additionalProperties": false]],
                "suffix": string("Appended to the source's Product ID and name (unless product_id and name are given) and to the codes of copied promotional offers, e.g. _AB3."),
                "group": ["description": "\"source\" keeps every subscription clone in its source's group (default); {\"new\": \"<name>\"} puts them into a new group that gets the texts of the source group.",
                          "oneOf": [["type": "string", "enum": ["source"]],
                                    ["type": "object", "properties": ["new": ["type": "string"]], "required": ["new"], "additionalProperties": false]]],
                "level": choice(["source", "end"], "Level of a subscription clone in its group: the source's level (default, variants of an A/B test) or a new level at the end."),
                "copy": ["type": "array", "items": ["type": "string", "enum": ["localizations", "review_screenshot", "prices", "intro_offers", "promo_offers"]],
                         "description": "What to copy besides the product, its attributes and availability; omit for everything. Prices and offers become Draft plans."],
            ], required: ["products", "suffix"])
            if name == .previewClone {
                return tool("Lists the steps clone_products would take for these products, after reading what the app already has in App Store Connect, and under blocked the steps it cannot take now, with what the owner has to do first. Writes nothing. While a clone or a product creation runs in Purser, it says so instead of listing steps; wait until it no longer does.", clone, .local)
            }
            return tool("WRITES TO APP STORE CONNECT: clones subscriptions and in-app purchases for an A/B test: each clone gets its source's attributes, availability, texts and review screenshot. A Product ID can never be used again, even after deletion. Then Purser syncs and builds Draft plans with the source's prices and offers; apply them in the listed order, the regular prices first. Running it again finishes what is missing.", clone, .ascWrite)
        }
    }
}
