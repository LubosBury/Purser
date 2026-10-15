import Foundation
import Domain
import ASCClient

/// Request estimate of an apply (rule A7, plan header).
public enum RequestEstimator {
    /// Writes + 1 app read (A1) + one price-point batch per product
    /// + preflight and verify reads: one page of 200 cells per (product, kind), twice
    /// + one owner read for every SET_TEXT item whose request is resolved at apply time (both ids nil).
    public static func requests(items: [PlannedItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        var cellsByScope: [String: Set<CellKey>] = [:]
        var products: Set<String> = []
        var resolvedReads = 0
        for item in items {
            products.insert(item.cell.productAscId)
            cellsByScope["\(item.cell.productAscId)|\(item.cell.storageKey.prefix(1))", default: []].insert(item.cell)
            if case let .setLocalization(text) = item.payload, text.localizationId == nil, text.versionId == nil { resolvedReads += 1 }
        }
        let pages = cellsByScope.values.reduce(0) { $0 + max(1, ($1.count + 199) / 200) }
        return items.count + 1 + products.count + 2 * pages + resolvedReads
    }

    /// Minutes at min(maxRequestsPerMinute, remaining hourly budget / 60) requests per minute.
    public static func minutes(requests: Int, rateLimit: RateLimitSnapshot?) -> Int {
        guard requests > 0 else { return 0 }
        let remaining = rateLimit?.remaining ?? AppleConstants.maxRequestsPerMinute * 60
        let perMinute = max(1, min(AppleConstants.maxRequestsPerMinute, remaining / 60))
        return (requests + perMinute - 1) / perMinute
    }
}
