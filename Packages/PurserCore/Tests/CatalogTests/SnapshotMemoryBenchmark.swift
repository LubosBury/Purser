import Darwin
import Foundation
import Testing
import Catalog
import Domain
import Store

/// Time and memory of `CatalogStore.latestSnapshot()` on a workspace database the size of a real app.
/// Skipped unless PURSER_BENCH=1. Set PURSER_BENCH_DB to the folder of a copy of a workspace database (`purser.sqlite`);
/// never point it at a live workspace, opening the database runs the migrations.
/// `PURSER_BENCH=1 PURSER_BENCH_DB=<folder> swift test --package-path Packages/PurserCore --filter SnapshotMemoryBenchmark`
@Suite(.serialized) struct SnapshotMemoryBenchmark {
    static let directory = ProcessInfo.processInfo.environment["PURSER_BENCH_DB"].map { URL(fileURLWithPath: $0) }
    static let enabled = ProcessInfo.processInfo.environment["PURSER_BENCH"] == "1" && directory != nil

    @Test(.enabled(if: SnapshotMemoryBenchmark.enabled))
    func snapshotsOfARealSizedCatalog() async throws {
        let database = try WorkspaceDatabase.open(at: try #require(Self.directory))
        let store = CatalogStore(database: database)
        let points = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM price_point") ?? 0 }

        let base = Footprint.now()
        let first = try Footprint.peak { try store.latestSnapshot() }
        let held = Footprint.now()
        let second = try Footprint.peak { try store.latestSnapshot() }
        let heldTwo = Footprint.now()
        let concurrent = try Footprint.peak {
            try DispatchQueue.concurrentMap(count: 2) { _ in try store.latestSnapshot() }
        }
        let heldFour = Footprint.now()
        // Another store starts without an index, as a newly opened workspace does.
        let fresh = CatalogStore(database: database)
        let cold = try Footprint.peak {
            try DispatchQueue.concurrentMap(count: 2) { _ in try fresh.latestSnapshot() }
        }
        withExtendedLifetime((first.value, second.value, concurrent.value, cold.value)) {}

        print("""
        SNAPSHOT-MEMORY-BENCH pricePoints=\(points)
          first:            \(first.milliseconds)ms peak +\(Footprint.mb(first.peak - base))MB, holding it +\(Footprint.mb(held - base))MB
          second:           \(second.milliseconds)ms peak +\(Footprint.mb(second.peak - held))MB, holding both +\(Footprint.mb(heldTwo - base))MB
          2 at once:        \(concurrent.milliseconds)ms peak +\(Footprint.mb(concurrent.peak - heldTwo))MB
          2 at once, cold:  \(cold.milliseconds)ms peak +\(Footprint.mb(cold.peak - heldFour))MB
        """)
    }
}

/// The process's physical footprint (what Activity Monitor shows as Memory).
enum Footprint {
    static func now() -> Int64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : 0
    }

    static func mb(_ bytes: Int64) -> Int64 { bytes / 1_048_576 }

    /// Runs `body` while a thread samples the footprint every millisecond; returns the result, the highest footprint and the time.
    static func peak<T>(_ body: () throws -> T) rethrows -> (value: T, peak: Int64, milliseconds: Int) {
        let sampler = Sampler()
        let thread = Thread { sampler.run() }
        thread.start()
        let start = ContinuousClock.now
        let value = try body()
        let elapsed = ContinuousClock.now - start
        let peak = sampler.stop()
        return (value, max(peak, now()), Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: Int64 = 0
        private var running = true

        func run() {
            while lock.withLock({ running }) {
                let current = Footprint.now()
                lock.withLock { highest = max(highest, current) }
                usleep(1000)
            }
        }

        func stop() -> Int64 {
            lock.withLock { running = false; return highest }
        }
    }
}

extension DispatchQueue {
    /// Runs `body` `count` times in parallel and returns the results in order.
    static func concurrentMap<T: Sendable>(count: Int, _ body: @Sendable (Int) throws -> T) throws -> [T] {
        let results = ConcurrentResults<T>(count: count)
        concurrentPerform(iterations: count) { index in
            let result = Result { try body(index) }
            results.lock.withLock { results.values[index] = result }
        }
        return try results.values.map { try $0!.get() }
    }
}

private final class ConcurrentResults<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var values: [Result<T, any Error>?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
}
