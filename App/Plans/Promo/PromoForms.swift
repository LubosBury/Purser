import SwiftUI
import Domain
import Planner

struct PromoCreateForm: View {
    @Bindable var model: PromoPlanModel

    var body: some View {
        PlanFormStep(3, "Offer") {
            HStack(alignment: .top, spacing: PurserSpacing.space3) {
                PlanFormField("Offer code") {
                    TextField("Offer code", text: $model.offerCode).font(PurserFont.figure)
                }
                PlanFormField("Name") { TextField("Name", text: $model.offerName) }
            }
            OfferCodeFeedback(check: model.codeCheck) { model.suggestCode() }
            HStack(alignment: .top, spacing: PurserSpacing.space3) {
                PlanFormField("Payment mode") {
                    Picker("Payment mode", selection: $model.mode) {
                        ForEach(OfferMode.allCases, id: \.self) { Text(PlanFormatting.modeLabel($0)).tag($0) }
                    }
                    .fixedSize()
                }
                PlanFormField("Duration") {
                    Picker("Duration", selection: $model.duration) {
                        ForEach(OfferDuration.allCases, id: \.self) { Text(PlanFormatting.durationLabel($0)).tag($0) }
                    }
                    .fixedSize()
                }
                if model.mode == .payAsYouGo {
                    PlanFormField("Number of periods") {
                        Stepper("\(model.numberOfPeriods)", value: $model.numberOfPeriods, in: 1...12).labelsHidden()
                        Text("\(model.numberOfPeriods)").font(PurserFont.figure)
                    }
                }
            }
        }
        PromoPricingSection(model: model)
        if let coverage = model.coverage { PromoCoverageMeter(coverage: coverage) }
    }
}

struct OfferCodeFeedback: View {
    let check: OfferCodeCheck
    let suggest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            if check.problems.isEmpty {
                PlanFormMessage("The code has never appeared in this workspace (O1).", kind: .success)
            }
            ForEach(Array(check.problems.enumerated()), id: \.offset) { _, problem in
                PlanFormMessage(Self.text(problem), kind: Self.isWarning(problem) ? .warning : .danger)
            }
            HStack(spacing: PurserSpacing.space3) {
                Button("Suggest a code", action: suggest).controlSize(.small).purserButton()
                if let suggestion = check.suggestion {
                    Text("Suggestion: \(suggestion)").font(PurserFont.identifier).textSelection(.enabled)
                }
            }
        }
    }

    static func isWarning(_ problem: OfferCodeProblem) -> Bool {
        if case .caseVariantOf = problem { return true }
        return false
    }

    static func text(_ problem: OfferCodeProblem) -> String {
        switch problem {
        case .empty: return "Enter a code"
        case let .tooLong(n): return "The code has \(n) characters; Purser allows at most \(OfferCodeAdvisor.maxLength)"
        case let .invalidCharacters(chars): return "Characters not allowed: “\(chars)” (only letters, digits, _ . -)"
        case .usedBefore: return "The code was already used in this workspace; Apple will not accept it again (O1)"
        case let .caseVariantOf(other): return "Differs only in letter case from the used “\(other)”"
        }
    }
}

struct PromoPricingSection: View {
    @Bindable var model: PromoPlanModel

    var body: some View {
        PlanFormStep(4, "Prices") {
            if model.isFreeTrialMode {
                PlanFormHint("A free trial offer has no prices: only territories are written, without a price point (O4).")
            } else {
                Picker("Price source", selection: $model.pricingChoice) {
                    Text("Percent of the regular price").tag(PromoPlanModel.PricingChoice.percent)
                    Text("Price table").tag(PromoPlanModel.PricingChoice.table)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch model.pricingChoice {
                case .percent, .freeTrial:
                    HStack(spacing: PurserSpacing.space2) {
                        TextField("Percent of the regular price", text: $model.percentText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(PurserFont.figure)
                            .frame(width: 70)
                        Text("% of the regular price, rounded down to the nearest price point").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                    }
                case .table:
                    PlanPriceTableEditor(title: "Price table", text: $model.tableText,
                                         hint: "One row = territory (ASC code or name) and amount, separated by a tab or a semicolon.",
                                         errors: model.tableErrors.map { "Row \($0.line): \($0.message)" })
                }
            }
        }
    }
}

struct OfferPicker: View {
    @Bindable var model: PromoPlanModel

    var body: some View {
        Picker("Offer", selection: $model.selectedOfferAscId) {
            Text("Select…").tag(String?.none)
            ForEach(model.offers, id: \.ascId) { offer in
                Text("\(offer.offerCode) · \(offer.name)").tag(Optional(offer.ascId))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

struct PromoRepriceForm: View {
    @Bindable var model: PromoPlanModel

    var body: some View {
        PlanFormStep(3, "Offer to reprice",
                     hint: "Repricing is risky (C2, O6): the confirmation requires a reason and ticking the risk class. The whole set of prices is always written.") {
            OfferPicker(model: model)
            if let offer = model.selectedOffer {
                Text("\(PlanFormatting.modeLabel(offer.mode)) · \(PlanFormatting.durationLabel(offer.duration)) × \(offer.numberOfPeriods)")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
                if offer.mode == .freeTrial {
                    PlanFormMessage("A free trial offer has no prices to reprice.", kind: .warning)
                }
            }
        }
        if model.selectedOffer.map({ $0.mode != .freeTrial }) ?? false {
            PromoPricingSection(model: model)
        }
        if let coverage = model.coverage { PromoCoverageMeter(coverage: coverage) }
    }
}

struct PromoDeleteForm: View {
    @Bindable var model: PromoPlanModel

    var body: some View {
        PlanFormStep(3, "Offer to delete", hint: "A deletion is always a plan of its own (O7).") {
            OfferPicker(model: model)
            if let offer = model.selectedOffer {
                PlanFormList {
                    Toggle("The app no longer uses \(offer.offerCode)", isOn: $model.confirmedUnusedByApp)
                }
                PlanFormMessage("The code \(offer.offerCode) can never be used again (O1). Apple does not document what happens to customers in the middle of the offer. Deleting is risky (C2).",
                                kind: .warning)
            }
        }
    }
}
