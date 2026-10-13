// swift-tools-version: 6.0
import PackageDescription

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

let package = Package(
    name: "PurserCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Store", targets: ["Store"]),
        .library(name: "Audit", targets: ["Audit"]),
        .library(name: "PurserSecurity", targets: ["PurserSecurity"]),
        .library(name: "ASCClient", targets: ["ASCClient"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Importer", targets: ["Importer"]),
        .library(name: "Policy", targets: ["Policy"]),
        .library(name: "Planner", targets: ["Planner"]),
        .library(name: "Executor", targets: ["Executor"]),
        .library(name: "Background", targets: ["Background"]),
        .library(name: "MCPBridge", targets: ["MCPBridge"]),
        .library(name: "MCPTools", targets: ["MCPTools"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Store", dependencies: ["Domain", grdb]),
        .target(name: "Audit", dependencies: ["Store", "Domain", grdb]),
        // The folder stays Sources/Security, but the module cannot be called "Security":
        // that name collides with Apple's Security framework (module dependency cycle via Foundation).
        .target(name: "PurserSecurity", dependencies: ["Domain"], path: "Sources/Security"),
        .target(name: "ASCClient", dependencies: ["PurserSecurity", "Domain"]),
        .target(name: "Catalog", dependencies: ["ASCClient", "Audit", "Store", "Domain", grdb]),
        .target(name: "Importer", dependencies: ["ASCClient", "Domain"], resources: [.process("Resources")]),
        .target(name: "Policy", dependencies: ["Catalog", "Store", "Audit", "ASCClient", "Domain", grdb]),
        .target(name: "Planner", dependencies: ["Policy", "Catalog", "Importer", "Store", "Audit", "ASCClient", "Domain", grdb]),
        .target(name: "Executor", dependencies: ["Planner", "Policy", "Catalog", "Importer", "ASCClient", "Audit", "PurserSecurity", "Store", "Domain", grdb]),
        .target(name: "Background", dependencies: ["Domain", "Store", "Audit", "PurserSecurity", "ASCClient", "Catalog", "Policy", grdb]),
        // MCP over stdio and the socket between the purser-mcp helper and the app. Foundation only: the helper links it.
        .target(name: "MCPBridge"),
        .target(name: "MCPTools", dependencies: ["MCPBridge", "Executor", "Planner", "Policy", "Catalog", "Importer", "Store", "Domain"]),
        .target(
            name: "PurserTestSupport",
            dependencies: ["Domain", "Store", "Audit", "PurserSecurity", "ASCClient", "Catalog", "Importer", "Policy", "Planner", "Executor", "Background", grdb],
            path: "Tests/TestSupport"
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain", "PurserTestSupport"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Domain", "PurserTestSupport", grdb]),
        .testTarget(name: "AuditTests", dependencies: ["Audit", "Store", "Domain", "PurserTestSupport", grdb]),
        .testTarget(name: "SecurityTests", dependencies: ["PurserSecurity", "Domain", "PurserTestSupport"]),
        .testTarget(name: "ASCClientTests", dependencies: ["ASCClient", "PurserSecurity", "Domain", "PurserTestSupport"]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "ASCClient", "Audit", "Store", "Domain", "PurserTestSupport", grdb]),
        .testTarget(name: "ImporterTests", dependencies: ["Importer", "ASCClient", "Domain", "PurserTestSupport"]),
        .testTarget(name: "PolicyTests", dependencies: ["Policy", "Catalog", "Store", "Audit", "ASCClient", "Domain", "PurserTestSupport", grdb]),
        .testTarget(name: "PlannerTests", dependencies: ["Planner", "Policy", "Catalog", "Importer", "Store", "Audit", "ASCClient", "Domain", "PurserTestSupport", grdb]),
        .testTarget(name: "ExecutorTests", dependencies: ["Executor", "PurserTestSupport", "Planner", "Policy", "Catalog", "Importer",
                                                          "Store", "Audit", "ASCClient", "PurserSecurity", "Domain", grdb]),
        .testTarget(name: "BackgroundTests", dependencies: ["Background", "PurserTestSupport", grdb]),
        .testTarget(name: "MCPBridgeTests", dependencies: ["MCPBridge"]),
        .testTarget(name: "MCPToolsTests", dependencies: ["MCPTools", "MCPBridge", "Executor", "Planner", "Policy", "Catalog", "Importer", "Store",
                                                          "Domain", "PurserTestSupport", grdb]),
    ]
)
