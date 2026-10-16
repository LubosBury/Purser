import Foundation

public enum ImportSource: Hashable, Sendable, Codable {
    case googleSheet(spreadsheetId: String, range: String)
    case csv
}

public enum TargetKind: Hashable, Sendable, Codable {
    case regularPrice(planType: PlanType)
    case introPayUpFront(duration: OfferDuration)
    case introPayAsYouGo(duration: OfferDuration, periods: Int)
    /// Column holds an OfferDuration raw value or a day count (3, 7, 14, 30, 60, 90, 180, 365).
    case introFreeTrial
    case promoPrice(offerCode: String)
    case iapManualPrice
}

public struct ImportTarget: Hashable, Sendable, Codable {
    public var column: String               // A1 column letters, e.g. "G"
    public var productAscId: String
    public var kind: TargetKind
    public var nominalDiscount: Decimal?    // e.g. 0.20 for a "-20%" column (rule I5)
    public var writes: Bool                 // false = check-only column
    public init(column: String, productAscId: String, kind: TargetKind, nominalDiscount: Decimal?, writes: Bool) {
        self.column = column; self.productAscId = productAscId; self.kind = kind
        self.nominalDiscount = nominalDiscount; self.writes = writes
    }
}

public struct ImportMapping: Hashable, Sendable, Codable {
    public var version: Int
    public var source: ImportSource
    public var firstDataRow: Int            // 1-based row number of the first data row
    public var countryColumn: String
    public var currencyColumn: String
    public var targets: [ImportTarget]
    public init(version: Int, source: ImportSource, firstDataRow: Int, countryColumn: String, currencyColumn: String, targets: [ImportTarget]) {
        self.version = version; self.source = source; self.firstDataRow = firstDataRow
        self.countryColumn = countryColumn; self.currencyColumn = currencyColumn; self.targets = targets
    }
}

public struct WorkspaceConfig: Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var isProduction: Bool
    public var appId: String
    public var bundleId: String
    public var keyKind: KeyKind
    public var keyId: String
    public var issuerId: String?            // team keys only
    public var importMapping: ImportMapping?
    public var googleClientId: String?
    public var slackWebhookEnabled: Bool
    public var nightlySyncHourUTC: Int

    public init(id: UUID, name: String, colorHex: String, isProduction: Bool, appId: String, bundleId: String,
                keyKind: KeyKind, keyId: String, issuerId: String?, importMapping: ImportMapping?,
                googleClientId: String?, slackWebhookEnabled: Bool, nightlySyncHourUTC: Int) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.isProduction = isProduction
        self.appId = appId; self.bundleId = bundleId; self.keyKind = keyKind; self.keyId = keyId
        self.issuerId = issuerId; self.importMapping = importMapping; self.googleClientId = googleClientId
        self.slackWebhookEnabled = slackWebhookEnabled; self.nightlySyncHourUTC = nightlySyncHourUTC
    }
}

/// What a plan is bound to (rule A1).
public struct PlanBinding: Hashable, Sendable, Codable {
    public var keyKind: KeyKind
    public var keyId: String
    public var issuerId: String?
    public var appId: String
    public var bundleId: String
    public init(config: WorkspaceConfig) {
        keyKind = config.keyKind; keyId = config.keyId; issuerId = config.issuerId
        appId = config.appId; bundleId = config.bundleId
    }
}
