import Foundation

/// Apple-behaviour constants. A spike may change a value only together with docs/spikes/<ID>.md.
public enum AppleConstants {
    public static let minLeadDays = 2                                   // R4, I7; spike S5
    public static let replaceCutoffHours = 48                           // R6; spike S6
    public static let maxRequestsPerMinute = 300                        // T3-28; spike S1
    public static let verifyBudgetShare = Decimal(string: "0.10")!      // §2 of the facts
    public static let maxPromoOffersPerSubscription = 10                // O2
    public static let tokenLifetimeSeconds: TimeInterval = 19 * 60      // < 20 min (T3-35)
    public static let snapWarnDeviation = Decimal(string: "0.02")!      // S4
    public static let snapBlockDeviation = Decimal(string: "0.10")!     // S4
    public static let i5ExtraDepthWarn = Decimal(string: "0.05")!       // I5
    public static let monthlyRatioMin = Decimal(string: "1.0")!         // R3
    public static let monthlyRatioMax = Decimal(string: "1.5")!         // R3
    public static let consentAlwaysTerritories: Set<TerritoryCode> = ["AUT", "DEU", "POL", "KOR"]  // R9
    public static let consentIncreaseThreshold = Decimal(string: "0.50")!                          // R9
    public static let iapDecreaseC2Threshold = Decimal(string: "0.30")!                            // L3
    public static let verifyAttempts = 3
    public static let verifyWindowSeconds: TimeInterval = 300
    public static let rateBackoffMinutes = [1, 2, 4, 8, 15]
    public static let maxServerErrorAttempts = 3
    public static let systemicSameErrorStreak = 3
    public static let systemicErrorShare = Decimal(string: "0.05")!
    public static let heartbeatSeconds: TimeInterval = 10
    public static let inactivityLockSeconds: TimeInterval = 15 * 60
    public static let c2MinReasonLength = 20
    public static let introLiveReplaceConfirmed = false                 // I7: true only after spike S4b
    /// O6: true when PATCH of a promo offer replaces the whole price set (spike S7); false = merge by territory.
    public static let promoPatchReplacesPriceSet = false
    /// L1: true after spike S10 confirmed that POST /v1/inAppPurchasePriceSchedules replaces the whole schedule.
    public static let iapScheduleReplaceConfirmed = false
    /// OQ3: true after spike SL confirmed the sandboxed login item syncs from the shared App Group container.
    public static let loginItemSyncConfirmed = false
    /// N2: locale shortcodes ASC accepts for localized metadata (developer.apple.com, "Managing metadata in your app by
    /// using locale shortcodes", 50 languages); spike SL10n Q4.
    public static let localizationLocales: Set<String> = [
        "ar-SA", "bn-BD", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl-NL", "en-AU", "en-CA", "en-GB", "en-US", "fi",
        "fr-FR", "fr-CA", "de-DE", "el", "gu-IN", "he", "hi", "hu", "id", "it", "ja", "kn-IN", "ko", "ms", "ml-IN", "mr-IN",
        "no", "or-IN", "pl", "pt-BR", "pt-PT", "pa-IN", "ro", "ru", "sk", "sl-SI", "es-MX", "es-ES", "sv", "ta-IN", "te-IN",
        "th", "tr", "uk", "ur-PK", "vi",
    ]
    /// N3: (minimum name, maximum name, maximum description); nil = Apple publishes no limit (groups). Spike SL10n Q4.
    public static let localizationLimits: [LocalizationOwnerKind: (nameMin: Int, nameMax: Int, descriptionMax: Int)?] = [
        .subscription: (2, 30, 45), .iap: (2, 30, 45), .group: nil,
    ]
    /// Whether a new version of an approved product starts with a copy of the live localizations. It stays false until a
    /// live trial of a new version of an approved product (which needs the owner's written approval) shows that Apple
    /// copies them; no step of spike SL10n creates such a version. While false: the Planner carries every unchanged Live
    /// locale over into a new version (PlanBuilder+NewVersion), and LocalizationSemantics.matchesMissingCopy accepts a new
    /// version without the locale's row. Either way the Executor reads the owner after the version exists: the ids of
    /// copied rows are known only from a read.
    public static let newVersionCopiesLocalizations = false
}
