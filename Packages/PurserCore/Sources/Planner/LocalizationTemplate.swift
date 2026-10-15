import Foundation
import Domain
import Catalog
import Importer

/// The localization table of a workspace: an export prefilled with today's texts, and the resolution of imported rows.
public enum LocalizationTemplate {
    public static let groupPrefix = "group:"

    /// One row per owner and locale that has an effective text: the text of the version in preparation when there is one,
    /// else the live text. An unedited export imported back plans nothing.
    public static func csv(snapshot: CatalogSnapshot, owners: [LocalizationOwner]) -> String {
        var rows: [LocalizationTableRow] = []
        for owner in owners.sorted() {
            guard let product = reference(owner, snapshot: snapshot),
                  let version = snapshot.pendingVersion(of: owner) ?? snapshot.liveVersion(of: owner) else { continue }
            for locale in snapshot.locales(of: owner) {
                guard let row = snapshot.localization(owner, locale: locale, versionId: version.ascId) else { continue }
                rows.append(LocalizationTableRow(product: product, locale: locale, name: row.text.name,
                                                 description: owner.kind == .group ? nil : row.text.description,
                                                 customAppName: owner.kind == .group ? row.text.customAppName : nil))
            }
        }
        rows.sort { ($0.product, $0.locale) < ($1.product, $1.locale) }
        return LocalizationTable.csv(rows)
    }

    /// The name of an owner in the table and in the MCP tools: Product ID, or group:<reference name>. When that name would not
    /// lead back to the same owner (a group's name is another group's ASC id, two groups or two products share a name, a
    /// Product ID is another product's ASC id) the ASC id is used instead: the bare ASC id for a subscription or an in-app
    /// purchase, group:<ASC id> for a group. nil when the snapshot does not know the owner.
    public static func reference(_ owner: LocalizationOwner, snapshot: CatalogSnapshot) -> String? {
        let readable: String
        switch owner.kind {
        case .subscription:
            guard let subscription = snapshot.subscriptions[owner.ascId] else { return nil }
            readable = subscription.productId
        case .iap:
            guard let iap = snapshot.iaps[owner.ascId] else { return nil }
            readable = iap.productId
        case .group:
            guard let group = snapshot.groups[owner.ascId] else { return nil }
            readable = groupPrefix + group.referenceName
        }
        // The table and the tools trim what they read, so a name with blanks at its ends or an empty one cannot lead back either.
        let readsBack = !readable.isEmpty && readable == readable.trimmingCharacters(in: .whitespacesAndNewlines)
        if readsBack, Self.owner(for: readable, snapshot: snapshot).owner == owner { return readable }
        return owner.kind == .group ? groupPrefix + owner.ascId : owner.ascId
    }

    /// Rows -> edits. A row Purser cannot place is left out and named in `problems` ("Row n: …").
    public static func resolve(_ rows: [LocalizationTableRow], snapshot: CatalogSnapshot) -> (edits: [LocalizationEdit], problems: [String]) {
        var edits: [LocalizationEdit] = []
        var problems: [String] = []
        for row in rows {
            let place = row.rowNumber > 0 ? "Row \(row.rowNumber)" : "\(row.product) \(row.locale)"
            let found = owner(for: row.product, snapshot: snapshot)
            guard let owner = found.owner else {
                problems.append("\(place): \(found.problem ?? "unknown product").")
                continue
            }
            if owner.kind == .group, row.description != nil {
                problems.append("\(place): a subscription group has no description; put the text into custom_app_name.")
            } else if owner.kind != .group, row.customAppName != nil {
                problems.append("\(place): only a subscription group has a custom app name.")
            } else {
                edits.append(LocalizationEdit(owner: owner, locale: row.locale, name: row.name, description: row.description,
                                              customAppName: row.customAppName))
            }
        }
        return (edits, problems)
    }

    /// The one resolver of owner references, shared by the table import and the MCP tools. group:<ASC id> or
    /// group:<reference name> (the prefix in any case, the ASC id first), else a Product ID or ASC id of a subscription or an
    /// in-app purchase. A reference that names more than one group or product is refused with a problem that says how to
    /// name it; `problem` reads as a clause ("no subscription group is named “x”"), the callers add the sentence around it.
    public static func owner(for reference: String, snapshot: CatalogSnapshot) -> (owner: LocalizationOwner?, problem: String?) {
        if reference.lowercased().hasPrefix(groupPrefix) {
            let name = String(reference.dropFirst(groupPrefix.count)).trimmingCharacters(in: .whitespaces)
            if snapshot.groups[name] != nil { return (.group(name), nil) }
            let matches = snapshot.groups.values.filter { $0.referenceName == name }
            switch matches.count {
            case 1: return (.group(matches[0].ascId), nil)
            case 0: return (nil, "no subscription group is named “\(name)”")
            default: return (nil, "more than one subscription group is named “\(name)”; name it as group:<ASC id>")
            }
        }
        var candidates: [LocalizationOwner] = []
        func add(_ owner: LocalizationOwner) { if !candidates.contains(owner) { candidates.append(owner) } }
        if snapshot.subscriptions[reference] != nil { add(.subscription(reference)) }
        if snapshot.iaps[reference] != nil { add(.iap(reference)) }
        for subscription in snapshot.subscriptions.values where subscription.productId == reference { add(.subscription(subscription.ascId)) }
        for iap in snapshot.iaps.values where iap.productId == reference { add(.iap(iap.ascId)) }
        switch candidates.count {
        case 1: return (candidates[0], nil)
        case 0: return (nil, "no subscription or in-app purchase has the Product ID or ASC id “\(reference)”")
        default: return (nil, "more than one product is named “\(reference)”; name it by its ASC id")
        }
    }
}
