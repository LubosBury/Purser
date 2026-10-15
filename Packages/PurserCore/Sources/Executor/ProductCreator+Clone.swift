import Foundation
import Domain
import Audit
import ASCClient
import Catalog
import Planner

// Cloning (spec "Localizations and cloning" §6): one ProductCreator run gives each clone its source's attributes,
// availability, texts and review screenshot. Prices and offers are never written here: CloneDrafts turns them into
// Draft plans after the sync that follows the run.

public enum CloneStep: Hashable, Sendable {
    case group(name: String)
    case groupLocalization(locale: String)
    case product(CloneItem)
    case availability(productId: String)
    case localization(productId: String, locale: String)
    case reviewScreenshot(productId: String)
}

/// One step of a clone run and what happened to it.
public struct CloneStepReport: Hashable, Sendable {
    public var step: CloneStep
    public var outcome: ProductCreationOutcome
    public init(step: CloneStep, outcome: ProductCreationOutcome) { self.step = step; self.outcome = outcome }
}

/// What a clone run would do now (`ProductCreator.previewClone`).
public struct ClonePreview: Hashable, Sendable {
    /// Every step still missing, in the order a run takes them.
    public var steps: [CloneStep]
    /// The steps a run cannot take now, each with what the owner has to do first. A run reports them as failed, sends
    /// nothing for them and does not count them in its Touch ID prompt.
    public var blocked: [CloneStep: String]

    public init(steps: [CloneStep], blocked: [CloneStep: String]) { self.steps = steps; self.blocked = blocked }

    /// The steps a run writes.
    public var writable: [CloneStep] { steps.filter { blocked[$0] == nil } }
}

public struct CloneReport: Hashable, Sendable {
    public var steps: [CloneStepReport]
    /// Source ASC id -> clone ASC id for every clone that exists after the run (made now or by an earlier run).
    public var created: [String: String]
    public init(steps: [CloneStepReport], created: [String: String]) { self.steps = steps; self.created = created }
}

/// Checks and steps of a clone, without App Store Connect.
public enum ClonePlanner {
    /// English messages for the sheet and the MCP tools; empty when the request can run. Checked against the catalog;
    /// the creator checks the same against what App Store Connect has when it runs.
    public static func problems(_ request: CloneRequest, snapshot: CatalogSnapshot) -> [String] {
        guard !request.items.isEmpty else { return ["There is nothing to clone."] }
        var problems: [String] = []
        var subscriptions: [NewSubscriptionProduct] = []
        var purchases: [NewNonConsumableProduct] = []
        var sourceGroups: Set<String> = []
        for item in request.items {
            switch item.source.kind {
            case .subscription:
                guard let source = snapshot.subscriptions[item.source.ascId] else {
                    problems.append("The subscription \(item.source.ascId) is not in the catalog; run a sync.")
                    continue
                }
                sourceGroups.insert(source.groupId)
                subscriptions.append(NewSubscriptionProduct(productId: item.productId, name: item.name, period: source.period))
                if item.productId == source.productId {
                    problems.append("The Product ID “\(item.productId)” of a clone must differ from its source.")
                }
            case .iap:
                guard let source = snapshot.iaps[item.source.ascId] else {
                    problems.append("The in-app purchase \(item.source.ascId) is not in the catalog; run a sync.")
                    continue
                }
                purchases.append(NewNonConsumableProduct(productId: item.productId, name: item.name))
                if item.productId == source.productId {
                    problems.append("The Product ID “\(item.productId)” of a clone must differ from its source.")
                }
            case .group:
                problems.append("A subscription group cannot be cloned; clone its subscriptions.")
            }
        }
        let groupName: String?
        switch request.group {
        case .sourceGroup:
            groupName = subscriptions.isEmpty ? nil : "source group"   // the clones stay in their sources' groups
        case let .newGroup(name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            groupName = trimmed
            if sourceGroups.count > 1 {
                problems.append("A new group takes the subscriptions of one group only; these come from \(sourceGroups.count) groups.")
            }
            // A group of that name may only be the one an earlier run of this request made: it holds this request's clones.
            let clones = Set(request.items.map(\.productId))
            if snapshot.subscriptions.values.contains(where: { subscription in
                (subscription.groupName == trimmed || snapshot.groups[subscription.groupId]?.referenceName == trimmed)
                    && !clones.contains(subscription.productId)
            }) {
                problems.append("A group named “\(trimmed)” already exists with other subscriptions; choose a name no group has.")
            }
        }
        // The Product ID and name rules of product creation, duplicates in the list included.
        problems += ProductCreationPlanner.problems(ProductCreationRequest(groupName: groupName, subscriptions: subscriptions,
                                                                           nonConsumables: purchases))
            .filter { $0 != "There is nothing to create." }
        for item in request.items {
            guard let other = existingProduct(item.productId, in: snapshot), other.ascId != item.source.ascId,
                  !isEarlierClone(kind: other.kind, name: other.name, of: item) else { continue }
            problems.append("The Product ID “\(item.productId)” is already used by “\(other.name)”.")
        }
        let suffix = request.offerCodeSuffix
        if request.copy.promoOffers, !subscriptions.isEmpty {
            if suffix.isEmpty || suffix.unicodeScalars.contains(where: { !isAllowedInSuffix($0) }) {
                problems.append("The suffix “\(suffix)” goes into the codes of copied promotional offers: it must not be empty and may contain only letters, digits, a period and an underscore.")
            } else {
                // Nothing is written before every new code is known to fit: a code too long for the suffix would fail only
                // when its Draft is applied, after the clones exist.
                var checked: Set<String> = []
                for item in request.items where item.source.kind == .subscription {
                    guard let source = snapshot.subscriptions[item.source.ascId], checked.insert(source.ascId).inserted else { continue }
                    for offer in snapshot.promoOffers(subscriptionId: source.ascId) where offer.planType == .upfront {
                        guard !CloneDrafts.isUsableOfferCode(offer.offerCode + suffix) else { continue }
                        problems.append("The code “\(offer.offerCode)” of a promotional offer of \(source.productId) would be too long or invalid with the suffix “\(suffix)”; use a shorter suffix or do not copy promotional offers.")
                    }
                }
            }
        }
        return problems
    }

    /// The trimmed name of the new group; nil when the clones stay in their sources' groups.
    static func newGroupName(_ request: CloneRequest) -> String? {
        if case let .newGroup(name) = request.group { return name.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    /// A product with the clone's Product ID, kind and reference name is the clone an earlier run created.
    static func isEarlierClone(kind: LocalizationOwnerKind, name: String, of item: CloneItem) -> Bool {
        kind == item.source.kind && name == item.name
    }

    /// The steps still needed, in order (see the task description in the spec, §6 "What ProductCreator writes").
    static func steps(_ request: CloneRequest, live: CloneLive) -> [CloneStep] {
        var steps: [CloneStep] = []
        if let name = newGroupName(request), live.sources.contains(where: { $0.subscription != nil }) {
            if live.groups[name] == nil { steps.append(.group(name: name)) }
            if request.copy.localizations {
                for locale in live.sourceGroupTexts.keys.sorted() where !live.targetGroupLocales.contains(locale) {
                    steps.append(.groupLocalization(locale: locale))
                }
            }
        }
        for source in ordered(request, live: live) {
            let item = source.item
            let clone = live.clones[item.productId]
            if clone == nil { steps.append(.product(item)) }
            if source.availability != nil, !(clone?.hasAvailability ?? false) { steps.append(.availability(productId: item.productId)) }
            if request.copy.localizations, clone?.lockedTexts != true {
                for locale in source.texts.keys.sorted() where !(clone?.locales.contains(locale) ?? false) {
                    steps.append(.localization(productId: item.productId, locale: locale))
                }
            }
            if request.copy.reviewScreenshot, source.screenshot?.isDownloadable == true, !(clone?.screenshot?.isCommitted ?? false) {
                steps.append(.reviewScreenshot(productId: item.productId))
            }
        }
        return steps
    }

    /// Request order; in a new group the subscriptions go by their sources' levels, so a level exists before a lower one.
    static func ordered(_ request: CloneRequest, live: CloneLive) -> [CloneLive.Source] {
        guard newGroupName(request) != nil else { return live.sources }
        return live.sources.enumerated()
            .sorted { ($0.element.subscription?.groupLevel ?? Int.max, $0.offset) < ($1.element.subscription?.groupLevel ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// groupLevel of each new subscription (clone Product ID -> level; missing = left to App Store Connect).
    static func groupLevels(_ request: CloneRequest, live: CloneLive) -> [String: Int] {
        var levels: [String: Int] = [:]
        let subscriptions = live.sources.filter { $0.subscription != nil }
        if newGroupName(request) != nil {
            let ranks = Array(Set(subscriptions.compactMap { $0.subscription?.groupLevel })).sorted()
            for source in subscriptions {
                levels[source.item.productId] = source.subscription?.groupLevel.flatMap { ranks.firstIndex(of: $0) }.map { $0 + 1 } ?? ranks.count + 1
            }
            return levels
        }
        var last: [String: Int] = [:]
        for source in subscriptions {
            guard let subscription = source.subscription else { continue }
            switch request.level {
            case .sameAsSource:
                if let level = subscription.groupLevel { levels[source.item.productId] = level }
            case .end:
                // A clone an earlier run made holds its level already (it is in groupLevels); only the missing ones get
                // the next levels, so a rerun ends where a clean run would have.
                guard live.clones[source.item.productId] == nil else { continue }
                let next = (last[subscription.groupId] ?? live.groupLevels[subscription.groupId]?.max() ?? 0) + 1
                levels[source.item.productId] = next
                last[subscription.groupId] = next
            }
        }
        return levels
    }

    /// The texts a clone copies: per locale the row of the pending version, else of the live version.
    static func texts(_ metadata: OwnerMetadata) -> [String: LocalizationText] {
        var texts: [String: LocalizationText] = [:]
        for version in [metadata.liveVersion, metadata.pendingVersion].compactMap({ $0 }) {
            for row in metadata.localizations where row.versionId == version.ascId { texts[row.locale] = row.text }
        }
        return texts
    }

    /// The file name of the copy: the source's name with a .png extension (the image is downloaded as PNG).
    static func pngName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? "review-screenshot" : base) + ".png"
    }

    private struct ExistingProduct {
        var kind: LocalizationOwnerKind
        var ascId: String
        var name: String
    }

    private static func existingProduct(_ productId: String, in snapshot: CatalogSnapshot) -> ExistingProduct? {
        if let found = snapshot.subscriptions.values.first(where: { $0.productId == productId }) {
            return ExistingProduct(kind: .subscription, ascId: found.ascId, name: found.name)
        }
        if let found = snapshot.iaps.values.first(where: { $0.productId == productId }) {
            return ExistingProduct(kind: .iap, ascId: found.ascId, name: found.name)
        }
        return nil
    }

    private static func isAllowedInSuffix(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_": return true
        default: return false
        }
    }
}

/// What App Store Connect has for one clone request, read before anything is written (`ProductCreator.readClone`).
struct CloneLive: Sendable {
    struct Source: Sendable {
        var item: CloneItem
        var subscription: SubscriptionInfo? = nil
        var iap: IAPInfo? = nil
        var availability: ProductAvailability? = nil
        var texts: [String: LocalizationText] = [:]       // locale -> text
        var screenshot: ReviewScreenshot? = nil
    }

    /// A clone an earlier run created (the same Product ID, kind and reference name).
    struct Clone: Sendable {
        var ascId: String
        var hasAvailability = false
        var versionId: String? = nil                       // its editable version
        var locales: Set<String> = []                      // the locales of that version
        var lockedTexts = false                            // no editable version: its texts are left alone
        var screenshot: ReviewScreenshot? = nil
    }

    var groups: [String: String] = [:]                     // reference name -> id
    var groupLevels: [String: [Int]] = [:]                 // group id -> levels in use
    var sources: [Source] = []                             // request order
    var clones: [String: Clone] = [:]                      // clone Product ID -> what exists
    var sourceGroupTexts: [String: LocalizationText] = [:] // texts of the source group (new group only)
    var targetGroupId: String? = nil                       // the new group when it exists already
    var targetGroupVersionId: String? = nil
    var targetGroupLocales: Set<String> = []

    func source(productId: String) -> Source? { sources.first { $0.item.productId == productId } }
}

/// What one clone run knows and has done so far.
struct CloneRun: Sendable {
    let request: CloneRequest
    let live: CloneLive
    let levels: [String: Int]                               // clone Product ID -> groupLevel
    var groupIds: [String: String]                          // reference name -> id
    var cloneIds: [String: String] = [:]                    // clone Product ID -> ASC id
    var created: [String: String] = [:]                     // source ASC id -> clone ASC id
    var versionIds: [LocalizationOwner: String?] = [:]      // editable version per owner; nil = it has none
    var stopReason: String? = nil
    var steps: [CloneStepReport] = []

    init(request: CloneRequest, live: CloneLive) {
        self.request = request
        self.live = live
        levels = ClonePlanner.groupLevels(request, live: live)
        groupIds = live.groups
        for source in live.sources {
            guard let clone = live.clones[source.item.productId] else { continue }
            cloneIds[source.item.productId] = clone.ascId
            created[source.item.source.ascId] = clone.ascId
            if let version = clone.versionId { versionIds[LocalizationOwner(source.item.source.kind, clone.ascId)] = version }
        }
        if let group = live.targetGroupId, let version = live.targetGroupVersionId { versionIds[.group(group)] = version }
    }

    var report: CloneReport { CloneReport(steps: steps, created: created) }

    mutating func record(_ step: CloneStep, _ outcome: ProductCreationOutcome) {
        steps.append(CloneStepReport(step: step, outcome: outcome))
    }
}

enum ClonePaths {
    static func screenshotType(_ kind: LocalizationOwnerKind) -> String {
        kind == .iap ? "inAppPurchaseAppStoreReviewScreenshots" : "subscriptionAppStoreReviewScreenshots"
    }
    static func screenshots(_ kind: LocalizationOwnerKind) -> String { "/v1/\(screenshotType(kind))" }
    static func screenshot(_ kind: LocalizationOwnerKind, id: String) -> String { "/v1/\(screenshotType(kind))/\(id)" }
}

extension ProductCreator {
    /// The steps `clone` would take now, after reading what the app has in App Store Connect, and the ones it could not
    /// take (`blocked`). Writes nothing.
    public func previewClone(_ request: CloneRequest, snapshot: CatalogSnapshot) async throws -> ClonePreview {
        let problems = ClonePlanner.problems(request, snapshot: snapshot)
        guard problems.isEmpty else { throw ProductCreationError.invalid(problems) }
        let live = try await readClone(request)
        let steps = ClonePlanner.steps(request, live: live)
        return ClonePreview(steps: steps, blocked: try await blockedSteps(steps, live: live))
    }

    /// Clones the request's products: one Touch ID for the run (none when nothing is missing), every request audited and
    /// never retried. A failed step skips the steps that need it; a request that may have reached Apple stops the run.
    /// Running it again finishes what is missing. Refused, before anything is read, while another creation or clone of the
    /// workspace runs (ProductRuns).
    public func clone(_ request: CloneRequest, snapshot: CatalogSnapshot) async throws -> CloneReport {
        let claim = try runs.claim(.clone)
        defer { claim.release() }
        return try await clone(request, snapshot: snapshot, holding: claim)
    }

    /// The same run, under a claim its caller took (`ProductRuns.claim`) and releases: the run stays marked after this
    /// returns or throws, for the work the caller does with the clones (their price drafts) before it releases the claim.
    public func clone(_ request: CloneRequest, snapshot: CatalogSnapshot, holding claim: ProductRunClaim) async throws -> CloneReport {
        precondition(claim.holds(.clone, in: runs), "a clone needs a live clone claim of the creator's own ProductRuns")
        let problems = ClonePlanner.problems(request, snapshot: snapshot)
        guard problems.isEmpty else { throw ProductCreationError.invalid(problems) }
        try await checkBinding()
        let live = try await readClone(request)
        let steps = ClonePlanner.steps(request, live: live)
        var run = CloneRun(request: request, live: live)
        guard !steps.isEmpty else { return run.report }
        // A step that cannot run is reported as failed, never sent and never part of the Touch ID prompt.
        let blocked = try await blockedSteps(steps, live: live)
        let writable = steps.count - blocked.count
        if writable > 0 {
            // Groups read under the workspace app just now may take new subscriptions.
            await http.appGuard.allowChildren(Set(live.groups.values))
            // The work left, not the request: a rerun may only add a text or a screenshot.
            let left = writable == 1 ? "1 step" : "\(writable) steps"
            try await gate.authenticate(reason: "clone products in App Store Connect: \(left) to write (a Product ID can never be used again)")
        }
        for step in steps {
            if let reason = blocked[step] {
                run.record(step, .failed(reason))
            } else {
                try await perform(step, run: &run)
            }
        }
        return run.report
    }

    /// The steps a run cannot take, with what the owner has to do first. A review screenshot is blocked when the clone
    /// already holds one this client may not delete: the source's own or a finished one (never touched), or a reservation
    /// AppGuard did not see this session make (after a relaunch, or a request that may have reached Apple). AppGuard is
    /// only asked; nothing is sent.
    func blockedSteps(_ steps: [CloneStep], live: CloneLive) async throws -> [CloneStep: String] {
        var blocked: [CloneStep: String] = [:]
        for step in steps {
            guard case let .reviewScreenshot(productId) = step, let source = live.source(productId: productId),
                  let original = source.screenshot, let stale = live.clones[productId]?.screenshot else { continue }
            if stale.ascId == original.ascId || stale.isCommitted {
                blocked[step] = "the screenshot \(stale.ascId) is not an uncommitted reservation of the clone; it is left alone"
                continue
            }
            do {
                try await http.appGuard.check(method: "DELETE", path: ClonePaths.screenshot(source.item.source.kind, id: stale.ascId), body: nil)
            } catch ASCError.foreignResource(_) {
                blocked[step] = Self.earlierSessionReservation
            }
        }
        return blocked
    }

    /// Reads (never writes) the sources, the groups and what an earlier run of the same request created.
    func readClone(_ request: CloneRequest) async throws -> CloneLive {
        var live = CloneLive()
        var subscriptions: [String: SubscriptionInfo] = [:]
        for group in try await reader.subscriptionGroups(appId: config.appId) {
            live.groups[group.referenceName] = group.id
            let members = try await reader.subscriptions(group: group)
            live.groupLevels[group.id] = members.compactMap(\.groupLevel)
            for member in members { subscriptions[member.ascId] = member }
        }
        var iaps: [String: IAPInfo] = [:]
        for iap in try await reader.inAppPurchases(appId: config.appId) { iaps[iap.ascId] = iap }
        var problems: [String] = []
        for item in request.items {
            var source = CloneLive.Source(item: item)
            switch item.source.kind {
            case .subscription:
                guard let subscription = subscriptions[item.source.ascId] else {
                    problems.append("The subscription \(item.source.ascId) is no longer in App Store Connect.")
                    continue
                }
                source.subscription = subscription
                source.availability = try await reader.subscriptionAvailability(subscriptionId: subscription.ascId)
            case .iap:
                guard let iap = iaps[item.source.ascId] else {
                    problems.append("The in-app purchase \(item.source.ascId) is no longer in App Store Connect.")
                    continue
                }
                source.iap = iap
                source.availability = try await reader.iapAvailability(iapId: iap.ascId)
            case .group:
                continue
            }
            if request.copy.localizations { source.texts = ClonePlanner.texts(try await reader.metadata(owner: item.source)) }
            if request.copy.reviewScreenshot { source.screenshot = try await reader.reviewScreenshot(of: item.source) }
            live.sources.append(source)

            let earlier: (kind: LocalizationOwnerKind, ascId: String, name: String)?
            if let found = subscriptions.values.first(where: { $0.productId == item.productId }) {
                earlier = (.subscription, found.ascId, found.name)
            } else if let found = iaps.values.first(where: { $0.productId == item.productId }) {
                earlier = (.iap, found.ascId, found.name)
            } else {
                earlier = nil
            }
            guard let earlier else { continue }
            guard earlier.ascId != item.source.ascId, ClonePlanner.isEarlierClone(kind: earlier.kind, name: earlier.name, of: item) else {
                problems.append("The Product ID “\(item.productId)” is already used by “\(earlier.name)” in App Store Connect.")
                continue
            }
            live.clones[item.productId] = try await readEarlierClone(LocalizationOwner(earlier.kind, earlier.ascId), copy: request.copy)
        }
        if let name = ClonePlanner.newGroupName(request), let target = live.groups[name] {
            let clones = Set(request.items.map(\.productId))
            if subscriptions.values.contains(where: { $0.groupId == target && !clones.contains($0.productId) }) {
                problems.append("A group named “\(name)” already exists in App Store Connect with other subscriptions; choose a name no group has.")
            }
        }
        guard problems.isEmpty else { throw ProductCreationError.invalid(problems) }
        if let name = ClonePlanner.newGroupName(request), request.copy.localizations,
           let sourceGroup = live.sources.compactMap(\.subscription).first?.groupId {
            live.sourceGroupTexts = ClonePlanner.texts(try await reader.metadata(owner: .group(sourceGroup)))
            if let target = live.groups[name] {
                let metadata = try await reader.metadata(owner: .group(target))
                live.targetGroupId = target
                if let version = metadata.pendingVersion, version.state.role == .editable { live.targetGroupVersionId = version.ascId }
                live.targetGroupLocales = Set(metadata.localizations.map(\.locale))
            }
        }
        return live
    }

    private func readEarlierClone(_ owner: LocalizationOwner, copy: CloneCopy) async throws -> CloneLive.Clone {
        var clone = CloneLive.Clone(ascId: owner.ascId)
        switch owner.kind {
        case .subscription: clone.hasAvailability = try await reader.subscriptionAvailability(subscriptionId: owner.ascId) != nil
        case .iap: clone.hasAvailability = try await reader.iapAvailability(iapId: owner.ascId) != nil
        case .group: break
        }
        if copy.localizations {
            let metadata = try await reader.metadata(owner: owner)
            if let version = metadata.pendingVersion, version.state.role == .editable {
                clone.versionId = version.ascId
                clone.locales = Set(metadata.localizations.filter { $0.versionId == version.ascId }.map(\.locale))
            } else {
                clone.lockedTexts = true
            }
        }
        if copy.reviewScreenshot { clone.screenshot = try await reader.reviewScreenshot(of: owner) }
        return clone
    }

    /// One step: its requests, each audited; the outcome goes into the run. ASC and image errors end the step, a request
    /// that may have reached Apple, the rate limit or a read-only client end the run; any other error (the audit, the
    /// database) ends the whole call, because a write that cannot be audited must not be sent.
    private func perform(_ step: CloneStep, run: inout CloneRun) async throws {
        if let reason = run.stopReason {
            run.record(step, .skipped(reason))
            return
        }
        let refs = Self.cloneRefs(step)
        do {
            switch step {
            case let .group(name):
                let id = try await createResource(path: "/v1/subscriptionGroups",
                                                  body: Self.resource("subscriptionGroups", attributes: ["referenceName": name],
                                                                      relationships: ["app": Self.toOne("apps", config.appId)]),
                                                  refs: refs)
                run.groupIds[name] = id
                await http.appGuard.allowChildren([id])
                run.record(step, .created(ascId: id))

            case let .groupLocalization(locale):
                guard let name = ClonePlanner.newGroupName(run.request), let groupId = run.groupIds[name],
                      let text = run.live.sourceGroupTexts[locale] else {
                    run.record(step, .skipped("the group was not created"))
                    return
                }
                let owner = LocalizationOwner.group(groupId)
                guard let versionId = try await editableVersion(of: owner, run: &run) else {
                    run.record(step, .failed("the group has no version in Prepare for Submission"))
                    return
                }
                let id = try await createLocalization(versionId: versionId, owner: owner, locale: locale, text: text, refs: refs)
                run.record(step, .created(ascId: id))

            case let .product(item):
                guard let source = run.live.source(productId: item.productId) else {
                    run.record(step, .failed("the source was not read"))
                    return
                }
                let id: String
                if let subscription = source.subscription {
                    let groupId: String?
                    if let name = ClonePlanner.newGroupName(run.request) { groupId = run.groupIds[name] } else { groupId = subscription.groupId }
                    guard let groupId else {
                        run.record(step, .skipped("the group was not created"))
                        return
                    }
                    var attributes: [String: Any] = ["name": item.name, "productId": item.productId,
                                                     "subscriptionPeriod": subscription.period.rawValue]
                    if let shared = subscription.familySharable { attributes["familySharable"] = shared }
                    if let note = subscription.reviewNote { attributes["reviewNote"] = note }
                    if let level = run.levels[item.productId] { attributes["groupLevel"] = level }
                    id = try await createResource(path: "/v1/subscriptions",
                                                  body: Self.resource("subscriptions", attributes: attributes,
                                                                      relationships: ["group": Self.toOne("subscriptionGroups", groupId)]),
                                                  refs: refs)
                } else if let iap = source.iap {
                    var attributes: [String: Any] = ["name": item.name, "productId": item.productId, "inAppPurchaseType": iap.iapType]
                    if let shared = iap.familySharable { attributes["familySharable"] = shared }
                    if let note = iap.reviewNote { attributes["reviewNote"] = note }
                    id = try await createResource(path: "/v2/inAppPurchases",
                                                  body: Self.resource("inAppPurchases", attributes: attributes,
                                                                      relationships: ["app": Self.toOne("apps", config.appId)]),
                                                  refs: refs)
                } else {
                    run.record(step, .failed("the source was not read"))
                    return
                }
                run.cloneIds[item.productId] = id
                run.created[item.source.ascId] = id
                await http.appGuard.allowProducts([id])
                run.record(step, .created(ascId: id))

            case let .availability(productId):
                guard let ascId = run.cloneIds[productId], let source = run.live.source(productId: productId),
                      let availability = source.availability else {
                    run.record(step, .skipped("the product was not created"))
                    return
                }
                let isSubscription = source.subscription != nil
                let type = isSubscription ? "subscriptionAvailabilities" : "inAppPurchaseAvailabilities"
                var relationships: [String: Any] = isSubscription
                    ? ["subscription": Self.toOne("subscriptions", ascId)]
                    : ["inAppPurchase": Self.toOne("inAppPurchases", ascId)]
                relationships["availableTerritories"] = Self.toMany("territories", availability.territories.map(\.rawValue).sorted())
                let id = try await createResource(path: "/v1/\(type)",
                                                  body: Self.resource(type, attributes: ["availableInNewTerritories": availability.availableInNewTerritories],
                                                                      relationships: relationships),
                                                  refs: refs)
                run.record(step, .created(ascId: id))

            case let .localization(productId, locale):
                guard let ascId = run.cloneIds[productId], let source = run.live.source(productId: productId),
                      let text = source.texts[locale] else {
                    run.record(step, .skipped("the product was not created"))
                    return
                }
                let owner = LocalizationOwner(source.item.source.kind, ascId)
                guard let versionId = try await editableVersion(of: owner, run: &run) else {
                    run.record(step, .failed("the product has no version in Prepare for Submission"))
                    return
                }
                let id = try await createLocalization(versionId: versionId, owner: owner, locale: locale, text: text, refs: refs)
                run.record(step, .created(ascId: id))

            case let .reviewScreenshot(productId):
                guard let ascId = run.cloneIds[productId], let source = run.live.source(productId: productId),
                      let original = source.screenshot else {
                    run.record(step, .skipped("the product was not created"))
                    return
                }
                guard let assets else {
                    run.record(step, .failed("this run cannot copy images"))
                    return
                }
                // Only the clone's own uncommitted reservation of this session is ever deleted: blockedSteps took out every
                // other one before Touch ID (and AppGuard refuses any screenshot this client did not reserve).
                let stale = run.live.clones[productId]?.screenshot
                let owner = LocalizationOwner(source.item.source.kind, ascId)
                let id = try await copyScreenshot(original, to: owner, stale: stale, assets: assets, refs: refs)
                run.record(step, .created(ascId: id))
            }
        } catch let error as ASCError {
            run.record(step, .failed(Self.describe(error)))
            switch error {
            case .network(_, maybeSent: true):
                run.stopReason = "the previous request may have reached Apple; run a sync and start the clone again"
            case .rateLimited:
                run.stopReason = "the hourly request budget is used up; try again later"
            case .readOnlyClient:
                run.stopReason = "read-only client"
            default:
                break   // the steps that need what failed are skipped by the missing id
            }
        } catch let error as AssetTransferError {
            run.record(step, .failed(error.description))
        }
    }

    /// The version the texts of `owner` go into: its pending version when that is editable. One read per owner and run.
    private func editableVersion(of owner: LocalizationOwner, run: inout CloneRun) async throws -> String? {
        if let known = run.versionIds[owner] { return known }
        let metadata = try await reader.metadata(owner: owner)
        let version = metadata.pendingVersion.flatMap { $0.state.role == .editable ? $0.ascId : nil }
        run.versionIds[owner] = .some(version)
        return version
    }

    /// POST of one text with the body the Executor uses (WriteBodies), audited here.
    private func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText,
                                    refs: [String: String]) async throws -> String {
        let route = WritePaths.createLocalization(owner.kind)
        let body = try WriteBodies.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text).data()
        guard let id = try await send(method: route.method, path: route.path, body: body, refs: refs, expectsId: true)?.data.first?.id else {
            throw ASCError.decoding("\(route.path): the response has no resource id")
        }
        return id
    }

    /// Download, delete the uncommitted reservation an earlier run left, reserve, upload every part, commit with the MD5.
    private func copyScreenshot(_ original: ReviewScreenshot, to owner: LocalizationOwner, stale: ReviewScreenshot?,
                                assets: AssetTransfer, refs: [String: String]) async throws -> String {
        let image = try await assets.download(original)
        func tagged(_ request: String) -> [String: String] { refs.merging(["request": request]) { current, _ in current } }
        if let stale {
            _ = try await send(method: "DELETE", path: ClonePaths.screenshot(owner.kind, id: stale.ascId), body: nil,
                               refs: tagged("delete"), expectsId: false)
        }
        let product: [String: Any] = owner.kind == .iap
            ? ["inAppPurchaseV2": Self.toOne("inAppPurchases", owner.ascId)]
            : ["subscription": Self.toOne("subscriptions", owner.ascId)]
        let reservation = try JSONSerialization.data(withJSONObject: Self.resource(
            ClonePaths.screenshotType(owner.kind),
            attributes: ["fileName": ClonePlanner.pngName(original.fileName), "fileSize": image.count], relationships: product),
            options: [.sortedKeys])
        guard let reserved = try await send(method: "POST", path: ClonePaths.screenshots(owner.kind), body: reservation,
                                            refs: tagged("reserve"), expectsId: true)?.data.first else {
            throw ASCError.decoding("\(ClonePaths.screenshots(owner.kind)): the response has no resource id")
        }
        guard let operations = UploadOperation.list(from: reserved), !operations.isEmpty else {
            throw AssetTransferError.badOperation("the reservation \(reserved.id) has no upload operations")
        }
        try await assets.upload(image, operations: operations, refs: tagged("upload"))
        let commit: [String: Any] = ["data": ["type": ClonePaths.screenshotType(owner.kind), "id": reserved.id,
                                              "attributes": ["uploaded": true, "sourceFileChecksum": AssetTransfer.md5(image)]]]
        _ = try await send(method: "PATCH", path: ClonePaths.screenshot(owner.kind, id: reserved.id),
                           body: try JSONSerialization.data(withJSONObject: commit, options: [.sortedKeys]), refs: tagged("commit"),
                           expectsId: false)
        return reserved.id
    }

    /// The outcome of a screenshot step whose clone holds a screenshot this client may not delete: a reservation another
    /// session (or a request that may have reached Apple) left, or one that failed after its commit.
    static let earlierSessionReservation = "A review screenshot Purser cannot replace is in the way (an unfinished upload from an earlier run). Remove it in App Store Connect (the product's Review Information), then run the clone again."

    static func cloneRefs(_ step: CloneStep) -> [String: String] {
        switch step {
        case let .group(name): return ["clone": "group", "product": name]
        case let .groupLocalization(locale): return ["clone": "groupLocalization", "locale": locale]
        case let .product(item): return ["clone": "product", "product": item.productId, "source": item.source.ascId]
        case let .availability(productId): return ["clone": "availability", "product": productId]
        case let .localization(productId, locale): return ["clone": "localization", "product": productId, "locale": locale]
        case let .reviewScreenshot(productId): return ["clone": "reviewScreenshot", "product": productId]
        }
    }
}
