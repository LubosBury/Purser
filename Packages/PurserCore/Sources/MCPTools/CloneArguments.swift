import Foundation
import Domain
import Catalog
import Planner
import Executor
import MCPBridge

/// Reads the arguments of preview_clone and clone_products into a CloneRequest. Products may be named by ASC id or by
/// Product ID; product_id and name default to the source's followed by the suffix, as the Clone sheet proposes them.
public enum CloneArguments {
    public static let copyNames = ["localizations", "review_screenshot", "prices", "intro_offers", "promo_offers"]

    public static func request(_ arguments: JSONValue, snapshot: CatalogSnapshot) throws -> CloneRequest {
        let suffix = arguments["suffix"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !suffix.isEmpty else { throw ToolArgumentError("“suffix” is required, e.g. _AB3.") }
        guard let products = arguments["products"]?.arrayValue, !products.isEmpty else {
            throw ToolArgumentError("“products” is required: a list of {source, product_id?, name?}.")
        }
        let lookup = PlanArguments(arguments, snapshot: snapshot)
        let items = try products.map { entry -> CloneItem in
            guard let reference = text(entry["source"]) else { throw ToolArgumentError("Every product needs “source”: an ASC id or Product ID.") }
            let source: LocalizationOwner
            let productId: String
            let name: String
            if let ascId = try? lookup.subscription(reference), let info = snapshot.subscriptions[ascId] {
                (source, productId, name) = (.subscription(ascId), info.productId, info.name)
            } else if let ascId = try? lookup.iap(reference), let info = snapshot.iaps[ascId] {
                (source, productId, name) = (.iap(ascId), info.productId, info.name)
            } else {
                throw ToolArgumentError("No subscription or in-app purchase with the ASC id or Product ID “\(reference)”. list_products shows the known ones.")
            }
            return CloneItem(source: source, productId: text(entry["product_id"]) ?? productId + suffix, name: text(entry["name"]) ?? name + suffix)
        }
        return CloneRequest(items: items, group: try group(arguments["group"]), level: try level(arguments["level"]),
                            copy: try copy(arguments["copy"]), offerCodeSuffix: suffix)
    }

    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    static func group(_ value: JSONValue?) throws -> CloneGroupTarget {
        guard let value, !value.isNull else { return .sourceGroup }
        if value.stringValue == "source" { return .sourceGroup }
        if let name = text(value["new"]) { return .newGroup(name: name) }
        throw ToolArgumentError("“group” must be \"source\" or {\"new\": \"<group name>\"}.")
    }

    static func level(_ value: JSONValue?) throws -> CloneLevel {
        guard let value, !value.isNull else { return .sameAsSource }
        switch value.stringValue {
        case "source": return .sameAsSource
        case "end": return .end
        default: throw ToolArgumentError("“level” must be source or end, not \(value.line()).")
        }
    }

    static func copy(_ value: JSONValue?) throws -> CloneCopy {
        guard let value, !value.isNull else { return CloneCopy() }
        guard let names = value.arrayValue else {
            throw ToolArgumentError("“copy” must be a list of \(copyNames.joined(separator: ", ")), not \(value.line()); omit it to copy everything.")
        }
        var copy = CloneCopy(localizations: false, reviewScreenshot: false, prices: false, introOffers: false, promoOffers: false)
        for entry in names {
            switch entry.stringValue {
            case "localizations": copy.localizations = true
            case "review_screenshot": copy.reviewScreenshot = true
            case "prices": copy.prices = true
            case "intro_offers": copy.introOffers = true
            case "promo_offers": copy.promoOffers = true
            default: throw ToolArgumentError("“copy” may contain only \(copyNames.joined(separator: ", ")), not \(entry.line()).")
            }
        }
        return copy
    }
}

extension MCPRender {
    /// The answer of preview_clone while a clone or a creation runs: no steps, because what it lists would still change.
    public static func productRunInProgress(_ kind: ProductRunKind) -> JSONValue {
        ["running": .string(kind.rawValue), "note": .string(kind.waitMessage)]
    }

    /// The answer of preview_clone: the steps clone_products would write and, apart, the ones it cannot take now.
    public static func cloneSteps(_ preview: ClonePreview, snapshot: CatalogSnapshot) -> JSONValue {
        let steps = preview.writable
        var result: [String: JSONValue] = [
            "steps": .array(steps.map { .string(describeClone($0, snapshot: snapshot)) }),
            "note": steps.isEmpty
                ? "Everything already exists; clone_products would only prepare the price drafts that are missing."
                : "clone_products runs these steps after one approval, then syncs and prepares the price drafts. A Product ID can never be used again.",
        ]
        let blocked = preview.steps.compactMap { step in preview.blocked[step].map { (step, $0) } }
        if !blocked.isEmpty {
            result["blocked"] = .array(blocked.map { step, reason in
                ["step": .string(describeClone(step, snapshot: snapshot)), "reason": .string(reason)]
            })
            result["note"] = .string(steps.isEmpty
                ? "Nothing clone_products could write is missing. The blocked steps need the owner first (see their reasons); then call preview_clone again."
                : "clone_products runs these steps after one approval, then syncs and prepares the price drafts; it leaves the blocked steps out until the owner clears them. A Product ID can never be used again.")
        }
        return .object(result)
    }

    /// The answer of clone_products. It always carries `not_copied`: what the drafts leave out when they were prepared, and
    /// otherwise a line that says the list is not known yet (an empty list would claim that nothing was left out).
    public static func cloneResult(_ report: CloneReport, drafts: CloneDraftOutcome?, snapshot: CatalogSnapshot) -> JSONValue {
        var result: [String: JSONValue] = [
            "steps": .array(report.steps.map { cloneStep($0, snapshot: snapshot) }),
            "clones": .array(report.created.sorted { $0.key < $1.key }.map { source, clone in
                ["source": .string(cloneSourceId(source, snapshot)), "source_asc_id": .string(source), "clone_asc_id": .string(clone)]
            }),
        ]
        guard !report.created.isEmpty else {
            result["drafts"] = []
            result["not_copied"] = notCopiedNotKnown
            result["note"] = "No clone exists, so no price drafts were prepared. Fix the failed steps and run clone_products again: it writes nothing that exists."
            return .object(result)
        }
        guard let drafts else {
            result["drafts"] = "preparing"
            result["not_copied"] = notCopiedNotKnown
            result["note"] = "The sync after the clone is still running; list_plans shows the price drafts when it ends."
            return .object(result)
        }
        if let problem = drafts.syncProblem {
            result["drafts"] = []
            result["not_copied"] = notCopiedNotKnown
            result["sync_problem"] = .string(problem)
            result["note"] = "No price drafts were prepared. Run sync_catalog, then clone_products again: it writes nothing that exists and prepares the drafts."
            return .object(result)
        }
        result["drafts"] = .array(drafts.drafts.map { line in
            var entry: [String: JSONValue] = ["title": .string(line.title)]
            if let planId = line.planId { entry["plan_id"] = .string(planId) }
            if let error = line.error { entry["error"] = .string(error) }
            if let note = line.note { entry["note"] = .string(note) }
            return .object(entry)
        })
        result["not_copied"] = .array(drafts.notes.map(JSONValue.string))
        result["note"] = .string("Review each draft with get_plan and apply them in the listed order, the regular prices first. "
            + (drafts.notes.isEmpty ? "Nothing of the sources' prices and offers was left out. "
                                    : "not_copied lists what the drafts leave out (MONTHLY plan types, scheduled changes, future prices); plan those once the clones' first prices are applied. ")
            + "The clones still need App Review in App Store Connect; a new clone_products run finishes failed steps and drafts.")
        return .object(result)
    }

    public static func describeClone(_ step: CloneStep, snapshot: CatalogSnapshot) -> String {
        switch step {
        case let .group(name): return "create the subscription group “\(name)”"
        case let .groupLocalization(locale): return "add the \(locale) text of the new group"
        case let .product(item):
            let kind = item.source.kind == .iap ? "in-app purchase" : "subscription"
            return "create the \(kind) \(item.productId) (\(item.name)) as a copy of \(cloneSourceId(item.source.ascId, snapshot))"
        case let .availability(productId): return "make \(productId) available where its source is"
        case let .localization(productId, locale): return "add the \(locale) text of \(productId)"
        case let .reviewScreenshot(productId): return "copy the review screenshot to \(productId)"
        }
    }

    static func cloneStep(_ entry: CloneStepReport, snapshot: CatalogSnapshot) -> JSONValue {
        var result: [String: JSONValue] = ["step": .string(describeClone(entry.step, snapshot: snapshot))]
        switch entry.outcome {
        case let .created(ascId):
            result["outcome"] = "created"
            result["asc_id"] = .string(ascId)
        case let .failed(message):
            result["outcome"] = "failed"
            result["message"] = .string(message)
        case let .skipped(message):
            result["outcome"] = "skipped"
            result["message"] = .string(message)
        }
        return .object(result)
    }

    static func cloneSourceId(_ ascId: String, _ snapshot: CatalogSnapshot) -> String {
        snapshot.subscriptions[ascId]?.productId ?? snapshot.iaps[ascId]?.productId ?? ascId
    }

    /// `not_copied` while the drafts, which work it out, do not exist.
    private static let notCopiedNotKnown: JSONValue =
        ["Not worked out yet: it comes with the price drafts. MONTHLY plan types, scheduled price changes and future in-app purchase prices are never copied."]
}
