import Foundation
import Domain
import Store

/// I7 (CR-11): "jeho Effective odemkne zbytek". Products whose live intro replacement was proven by an Effective CANARY plan.
public enum LiveIntroCanaries {
    /// Subscription asc ids taken from the cells of Effective `endIntro` items of Effective plans whose spec (without fix
    /// wrappers) is an INTRO or IMPORT spec with canary == true. Plans whose spec does not decode are skipped.
    public static func unlockedProducts(store: PlanStore) throws -> Set<String> {
        var products: Set<String> = []
        for plan in try store.plans(states: [.effective]) {
            guard let spec = try? JSONCoding.decode(PlanSpec.self, from: plan.specJSON), spec.isCanary else { continue }
            for stored in try store.items(planId: plan.id) where stored.state == .effective {
                if case .endIntro = stored.item.payload { products.insert(stored.item.cell.productAscId) }
            }
        }
        return products
    }
}

extension PlanSpec {
    /// The CANARY flag of an INTRO or IMPORT spec (fix wrappers removed); other specs are never canaries.
    var isCanary: Bool {
        switch unwrapped {
        case let .intro(spec): return spec.canary
        case let .importTable(spec): return spec.canary
        case .regular, .promo, .iap, .fix, .withdraw: return false
        }
    }
}
