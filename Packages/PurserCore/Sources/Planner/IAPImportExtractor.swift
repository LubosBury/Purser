import Foundation
import Domain
import Importer

/// IAP manual prices from an imported table: the first `.iapManualPrice` target of the IAP in the mapping.
public enum IAPImportExtractor {
    public static func amounts(from table: ImportedTable, mapping: ImportMapping, iapId: String) -> [TerritoryAmount] {
        guard let target = mapping.targets.first(where: { $0.productAscId == iapId && $0.kind == .iapManualPrice }) else { return [] }
        return table.rows.compactMap { row -> TerritoryAmount? in
            guard case let .amount(value)? = row.values[target.column] else { return nil }
            return TerritoryAmount(territory: row.territory, amount: value)
        }
        .sorted { $0.territory < $1.territory }
    }
}
