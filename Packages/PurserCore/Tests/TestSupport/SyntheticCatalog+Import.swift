import Foundation
import Domain
import Importer

extension SyntheticCatalog {
    /// Alpha, Beta and Gamma (yearly, APPROVED, all 175 territories) with current regular prices taken from the
    /// check-only regular columns C, E and G of the imported synthetic table; no intros.
    public static func fromSyntheticTable(_ table: ImportedTable, state: ProductState = .approved) -> SyntheticCatalog {
        var catalog = SyntheticCatalog()
        for (column, product) in SyntheticImport.regularColumns {
            var prices: [TerritoryCode: Decimal] = [:]
            for row in table.rows { if let amount = row.values[column]?.amount { prices[row.territory] = amount } }
            catalog.addSubscription(product, prices: prices, state: state)
        }
        for row in table.rows { catalog.territories[row.territory] = row.currency }
        return catalog
    }
}
