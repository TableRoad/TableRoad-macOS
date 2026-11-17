// swift-tools-version: 6.0
import PackageDescription

// TableRoadKit: everything that isn't a view or a platform API.
// Rule: no AppKit/UIKit imports anywhere in this package.
// Driver, SSH and storage modules are added phase by phase (see docs/PLAN.md §9).
let package = Package(
    name: "TableRoadKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TableRoadCore", targets: ["TableRoadCore"]),
        .library(name: "TableRoadDesign", targets: ["TableRoadDesign"]),
        .library(name: "TableRoadSQL", targets: ["TableRoadSQL"]),
        .library(name: "TableRoadMySQL", targets: ["TableRoadMySQL"]),
        .library(name: "TableRoadStorage", targets: ["TableRoadStorage"]),
        .library(name: "TableRoadTransfer", targets: ["TableRoadTransfer"]),
        .library(name: "TableRoadDrivers", targets: ["TableRoadDrivers"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(name: "TableRoadCore"),
        .target(
            name: "TableRoadDesign",
            dependencies: ["TableRoadCore"]
        ),
        .target(name: "TableRoadSQL", dependencies: ["TableRoadCore"]),
        .target(
            name: "TableRoadMySQL",
            dependencies: [
                "TableRoadCore",
                "TableRoadSQL",
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "TableRoadStorage", dependencies: ["TableRoadCore"]),
        // Chooses a driver per engine; the app depends on this rather than on individual drivers.
        .target(name: "TableRoadDrivers", dependencies: ["TableRoadCore", "TableRoadSQL", "TableRoadMySQL"]),
        // Export (CSV, JSON, SQL dump, Excel) and SQL dump import. zlib (system) for gzip and .xlsx (zip).
        .target(
            name: "TableRoadTransfer",
            dependencies: ["TableRoadCore", "TableRoadSQL", "TableRoadMySQL"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(name: "TableRoadCoreTests", dependencies: ["TableRoadCore"]),
        .testTarget(name: "TableRoadStorageTests", dependencies: ["TableRoadStorage"]),
        .testTarget(name: "TableRoadSQLTests", dependencies: ["TableRoadSQL"]),
        .testTarget(name: "TableRoadMySQLTests", dependencies: ["TableRoadMySQL", "TableRoadSQL"]),
        .testTarget(
            name: "TableRoadTransferTests", dependencies: ["TableRoadTransfer", "TableRoadMySQL", "TableRoadSQL"]),
    ],
    swiftLanguageModes: [.v6]
)
