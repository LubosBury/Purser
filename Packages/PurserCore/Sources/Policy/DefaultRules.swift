import Foundation
import Domain

/// Registration of the default rules.
enum DefaultRules {
    static let planRules: [any PlanRule] = [
        A2ProductionRule(), A3SingleApplyingRule(), A4FreshBaseRule(), A5ProductStateRule(), A6AvailabilityRule(), A7BudgetRule(),
        R2MonthlyWriteRule(), R3MonthlyRatioRule(), R4LeadTimeRule(), R5ReplacementRule(), R6CutoffRule(), R7DecreaseRule(),
        R8IncreaseWithoutPreserveRule(), R9ConsentRule(),
        I2OfferShapeRule(), I4IntroBelowRegularRule(), I5NominalDiscountRule(), I6IntroSlotsRule(), I7LiveIntroRule(),
        I8IntroReplacementRule(), I9IntroEligibilityRule(),
        O1OfferCodeRule(), O2PromoCountRule(), O3PromoCoverageRule(), O5PromoBelowRegularRule(), O6PromoChangeRule(), O7PromoDeleteRule(),
        L2IAPGeneratedPricesRule(), L3IAPDecreaseRule(), IAPScheduleSpikeGateRule(),
    ]

    /// A6, R3, I4, I5, O5.
    static func invariants(nominalDiscounts: [String: Decimal]) -> [any InvariantRule] {
        [A6AvailabilityInvariant(), R3MonthlyRatioRule(), I4IntroBelowRegularRule(),
         I5NominalDiscountInvariant(nominalDiscounts: nominalDiscounts), O5PromoBelowRegularRule()]
    }
}
