import Foundation
import Domain

extension LiveASCClient {
    /// The price points Apple treats as equivalent to `pricePointId` in every other territory (what ASC UI fills in
    /// when one territory's price is entered "with automatic conversion"). The base territory itself is not included.
    public func equalizations(subscriptionId: String, pricePointId: String, planType: PlanType?) async throws -> [PricePoint] {
        let pages = try await http.getAll("/v1/subscriptionPricePoints/\(pricePointId)/equalizations", query: [
            URLQueryItem(name: "include", value: "territory"),
            URLQueryItem(name: "limit", value: "8000"),
        ])
        return try ASCMapping.pricePoints(pages, productAscId: subscriptionId, planType: planType)
            .sorted { $0.territory < $1.territory }
    }
}
