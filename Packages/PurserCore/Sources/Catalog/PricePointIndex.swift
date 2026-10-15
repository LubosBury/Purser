import Foundation
import Domain

/// Apple's price points by (product, territory, plan type) and by id.
///
/// A workspace has millions of points (one per tier, territory and plan type of every product, about 140,000 per
/// subscription), so the index keeps them compact: a ladder stores the part of the id its points share once and only
/// the rest of each id (short enough to need no allocation of its own), ladders with equal prices share one array, and
/// a `PricePoint` is built only when asked for. The storage is immutable and shared by every copy of the index.
public struct PricePointIndex: Sendable {
    struct Key: Hashable, Sendable {
        var productAscId: String
        var territory: TerritoryCode
        var planType: PlanType?
    }

    /// One point of a ladder before the index is built.
    struct Entry: Sendable {
        var id: String
        var customerPrice: Decimal
        var proceeds: Decimal?
    }

    private let storage: Storage

    public init(_ points: [PricePoint]) {
        var keys: [Key] = []
        var entries: [Key: [Entry]] = [:]
        for point in points {
            let key = Key(productAscId: point.productAscId, territory: point.territory, planType: point.planType)
            if entries[key] == nil { keys.append(key) }
            entries[key, default: []].append(Entry(id: point.id, customerPrice: point.customerPrice, proceeds: point.proceeds))
        }
        var builder = Builder()
        for key in keys { builder.add(key, entries[key] ?? []) }
        self = builder.build()
    }

    fileprivate init(storage: Storage) {
        self.storage = storage
    }

    /// The ladder of one product, territory and plan type, ascending by price; empty when there is none.
    public func ladder(productAscId: String, territory: TerritoryCode, planType: PlanType?) -> PricePointLadder {
        guard let index = storage.ladderByKey[Key(productAscId: productAscId, territory: territory, planType: planType)] else {
            return PricePointLadder(storage: nil, index: 0)
        }
        return PricePointLadder(storage: storage, index: index)
    }

    /// Sorted ascending by customerPrice.
    public func points(productAscId: String, territory: TerritoryCode, planType: PlanType?) -> [PricePoint] {
        Array(ladder(productAscId: productAscId, territory: territory, planType: planType))
    }

    public func point(id: String) -> PricePoint? {
        storage.location(of: id).map { storage.ladders[$0.ladder].point(at: $0.position) }
    }

    /// Smallest absolute difference; on a tie the cheaper point wins.
    public func nearest(to amount: Decimal, productAscId: String, territory: TerritoryCode, planType: PlanType?) -> PricePoint? {
        let ladder = ladder(productAscId: productAscId, territory: territory, planType: planType)
        let prices = ladder.prices
        let best = prices.indices.min { a, b in
            let da = abs(prices[a] - amount)
            let db = abs(prices[b] - amount)
            return da == db ? prices[a] < prices[b] : da < db
        }
        return best.map { ladder[$0] }
    }

    /// Highest point with customerPrice <= amount.
    public func floor(atMost amount: Decimal, productAscId: String, territory: TerritoryCode, planType: PlanType?) -> PricePoint? {
        let ladder = ladder(productAscId: productAscId, territory: territory, planType: planType)
        return ladder.prices.lastIndex { $0 <= amount }.map { ladder[$0] }
    }

    /// True when both indexes share one storage (a snapshot reused the index of an earlier one).
    func sharesStorage(with other: PricePointIndex) -> Bool {
        storage === other.storage
    }

    /// Collects ladders, one call per (product, territory, plan type), and builds the index.
    struct Builder {
        private var ladders: [Ladder] = []
        private var ladderByKey: [Key: Int] = [:]
        private var prices: [[Decimal]: [Decimal]] = [:]
        private var proceeds: [[Decimal?]: [Decimal?]] = [:]

        /// Adds the points of one ladder in any order. A key added again is merged with its earlier points.
        mutating func add(_ key: Key, _ entries: [Entry]) {
            guard !entries.isEmpty else { return }
            if let existing = ladderByKey[key] {
                let ladder = ladders[existing]
                let earlier = ladder.idSuffixes.indices.map {
                    Entry(id: ladder.idPrefix + ladder.idSuffixes[$0], customerPrice: ladder.prices[$0], proceeds: ladder.proceeds[$0])
                }
                ladders[existing] = makeLadder(key, earlier + entries)
            } else {
                ladderByKey[key] = ladders.count
                ladders.append(makeLadder(key, entries))
            }
        }

        func build() -> PricePointIndex {
            PricePointIndex(storage: Storage(ladders: ladders, ladderByKey: ladderByKey))
        }

        private mutating func makeLadder(_ key: Key, _ entries: [Entry]) -> Ladder {
            let sorted = entries.sorted { ($0.customerPrice, $0.id) < ($1.customerPrice, $1.id) }
            let prefixLength = Self.sharedPrefixLength(sorted.map(\.id))
            let first = sorted[0].id.utf8
            let sortedPrices = sorted.map(\.customerPrice)
            let sortedProceeds = sorted.map(\.proceeds)
            return Ladder(key: key,
                          idPrefix: String(decoding: first.prefix(prefixLength), as: UTF8.self),
                          idSuffixes: sorted.map { String(decoding: $0.id.utf8.dropFirst(prefixLength), as: UTF8.self) },
                          prices: Self.intern(sortedPrices, in: &prices),
                          proceeds: Self.intern(sortedProceeds, in: &proceeds))
        }

        /// Equal arrays are kept once.
        private static func intern<T: Hashable>(_ values: [T], in pool: inout [[T]: [T]]) -> [T] {
            if let shared = pool[values] { return shared }
            pool[values] = values
            return values
        }

        /// The number of leading UTF-8 bytes every id shares, never ending inside a character's bytes.
        static func sharedPrefixLength(_ ids: [String]) -> Int {
            guard let first = ids.first else { return 0 }
            let bytes = Array(first.utf8)
            var length = bytes.count
            for id in ids.dropFirst() {
                var shared = 0
                for byte in id.utf8 {
                    guard shared < length, byte == bytes[shared] else { break }
                    shared += 1
                }
                length = shared
                if length == 0 { return 0 }
            }
            // Never split a multi-byte UTF-8 sequence: back off while the next byte continues one.
            while length > 0, length < bytes.count, bytes[length] & 0xC0 == 0x80 { length -= 1 }
            return length
        }
    }
}

/// One ladder of `PricePointIndex`, ascending by price. `prices` needs no allocation; a point is built when read.
public struct PricePointLadder: RandomAccessCollection, Sendable {
    fileprivate let storage: Storage?
    fileprivate let index: Int

    fileprivate init(storage: Storage?, index: Int) {
        self.storage = storage
        self.index = index
    }

    /// The customer prices, ascending, at the same positions as the points.
    public var prices: [Decimal] { storage?.ladders[index].prices ?? [] }

    public var startIndex: Int { 0 }
    public var endIndex: Int { prices.count }

    public subscript(position: Int) -> PricePoint {
        guard let storage else { preconditionFailure("An empty ladder has no points.") }
        return storage.ladders[index].point(at: position)
    }
}

private struct Ladder: Sendable {
    let key: PricePointIndex.Key
    /// The UTF-8 bytes every id of the ladder starts with.
    let idPrefix: String
    let idSuffixes: [String]
    let prices: [Decimal]
    let proceeds: [Decimal?]

    func point(at position: Int) -> PricePoint {
        PricePoint(id: idPrefix + idSuffixes[position], productAscId: key.productAscId, territory: key.territory,
                   planType: key.planType, customerPrice: prices[position], proceeds: proceeds[position])
    }
}

private final class Storage: Sendable {
    let ladders: [Ladder]
    let ladderByKey: [PricePointIndex.Key: Int]
    /// Ladders by the UTF-8 length of their id prefix, then by the prefix; a lookup tries each length in use.
    private let laddersByPrefix: [(length: Int, ladders: [String: [Int]])]

    init(ladders: [Ladder], ladderByKey: [PricePointIndex.Key: Int]) {
        self.ladders = ladders
        self.ladderByKey = ladderByKey
        var byPrefix: [Int: [String: [Int]]] = [:]
        for (index, ladder) in ladders.enumerated() {
            byPrefix[ladder.idPrefix.utf8.count, default: [:]][ladder.idPrefix, default: []].append(index)
        }
        laddersByPrefix = byPrefix.sorted { $0.key < $1.key }.map { (length: $0.key, ladders: $0.value) }
    }

    /// Where the point with this id (compared by its UTF-8 bytes) is; when ids repeat, the ladder added first wins.
    func location(of id: String) -> (ladder: Int, position: Int)? {
        let bytes = Array(id.utf8)
        var found: (ladder: Int, position: Int)?
        for (length, byPrefix) in laddersByPrefix where length <= bytes.count {
            // A stored prefix never ends inside a character's bytes, so neither may this split.
            if length < bytes.count, bytes[length] & 0xC0 == 0x80 { continue }
            guard let candidates = byPrefix[String(decoding: bytes[..<length], as: UTF8.self)] else { continue }
            let suffix = String(decoding: bytes[length...], as: UTF8.self)
            for ladder in candidates where found.map({ ladder < $0.ladder }) ?? true {
                if let position = ladders[ladder].idSuffixes.firstIndex(of: suffix) { found = (ladder, position) }
            }
        }
        return found
    }
}
