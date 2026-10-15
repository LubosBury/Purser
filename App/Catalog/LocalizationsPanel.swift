import SwiftUI
import Catalog
import Domain

/// Read-only Localizations section of a subscription, an in-app purchase or a subscription group (spec §4): the texts of
/// the live version next to the texts of the pending one, with the version states as badges.
struct LocalizationsPanel: View {
    let owner: LocalizationOwner
    let snapshot: CatalogSnapshot

    var body: some View {
        let section = CatalogLocalizations.of(owner, snapshot: snapshot)
        VStack(alignment: .leading, spacing: PurserSpacing.space3) {
            HStack(spacing: PurserSpacing.space2) {
                if let live = section.liveVersion { Self.badge(live) }
                if let pending = section.pendingVersion { Self.badge(pending) }
                Text("\(section.rows.count) \(section.rows.count == 1 ? "locale" : "locales")").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            if section.rows.isEmpty {
                ContentUnavailableView("No texts", systemImage: "character.bubble",
                                       description: Text(section.liveVersion == nil && section.pendingVersion == nil
                                                         ? "No version has been read. Sync to read the texts from App Store Connect."
                                                         : "The version has no localizations."))
            } else {
                table(section)
            }
        }
    }

    private var secondField: String { owner.kind == .group ? "custom app name" : "description" }

    private func table(_ section: CatalogLocalizations) -> some View {
        let pendingWord = section.pendingVersion.map { Self.word($0.state.role) } ?? "Pending"
        return Table(section.rows) {
            TableColumn("Locale") { row in Text(row.locale).font(PurserFont.identifier).textSelection(.enabled) }
            TableColumn("Live name") { row in cell(row.live?.name) }
            TableColumn("Live \(secondField)") { row in cell(second(row.live)) }
            TableColumn("\(pendingWord) name") { row in cell(row.pending?.name) }
            TableColumn("\(pendingWord) \(secondField)") { row in cell(second(row.pending)) }
            TableColumn("Change") { row in change(row.change) }
        }
        .purserTable()
    }

    private func second(_ text: LocalizationText?) -> String? {
        owner.kind == .group ? text?.customAppName : text?.description
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(PurserFont.body)
            .foregroundStyle(text == nil ? PurserColor.textSecondary : PurserColor.textPrimary)
            .lineLimit(2)
            .help(text ?? "")
            .textSelection(.enabled)
    }

    /// The difference is a word with an icon in a badge, never colour alone.
    @ViewBuilder
    private func change(_ change: CatalogLocalizationRow.Change) -> some View {
        switch change {
        case .none: EmptyView()
        case .changed: PurserBadge(text: "Changed", kind: .info, icon: "arrow.left.arrow.right")
        case .added: PurserBadge(text: "New", kind: .info, icon: "plus")
        case .removed: PurserBadge(text: "Removed", kind: .warning)
        }
    }

    static func word(_ role: MetadataVersionState.Role) -> String {
        switch role {
        case .live: return "Live"
        case .editable: return "Draft"
        case .inReview: return "In review"
        case .retired: return "Replaced"
        }
    }

    /// Version state as a word with an icon of its own shape: Live (check), Draft (pencil), In review (clock).
    static func badge(_ version: MetadataVersion) -> some View {
        let text = "\(word(version.state.role)) · version \(version.number)"
        let badge: PurserBadge
        switch version.state.role {
        case .live: badge = PurserBadge(text: text, kind: .success)
        case .editable: badge = PurserBadge(text: text, kind: .neutral, icon: "pencil")
        case .inReview: badge = PurserBadge(text: text, kind: .info, icon: "clock")
        case .retired: badge = PurserBadge(text: text, kind: .neutral, icon: "archivebox")
        }
        return badge.help("App Store Connect state \(version.state.rawValue)")
    }
}
