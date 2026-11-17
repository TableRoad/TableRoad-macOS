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
        .library(name: "TableRoadBackup", targets: ["TableRoadBackup"]),
        .library(name: "TableRoadDrivers", targets: ["TableRoadDrivers"]),
        .library(name: "TableRoadSQLite", targets: ["TableRoadSQLite"]),
        .library(name: "TableRoadPostgres", targets: ["TableRoadPostgres"]),
        .library(name: "TableRoadClickHouse", targets: ["TableRoadClickHouse"]),
        .library(name: "TableRoadSQLServer", targets: ["TableRoadSQLServer"]),
        .library(name: "TableRoadVertica", targets: ["TableRoadVertica"]),
        .library(name: "TableRoadCassandra", targets: ["TableRoadCassandra"]),
        .library(name: "TableRoadRedis", targets: ["TableRoadRedis"]),
        .library(name: "TableRoadOracle", targets: ["TableRoadOracle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
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
        .target(
            name: "TableRoadDrivers",
            dependencies: [
                "TableRoadCore", "TableRoadSQL", "TableRoadMySQL", "TableRoadSQLite", "TableRoadPostgres",
                "TableRoadClickHouse", "TableRoadSQLServer", "TableRoadVertica", "TableRoadCassandra",
                "TableRoadOracle",
            ]),
        // Vertica's PostgreSQL-derived protocol (own implementation on SwiftNIO).
        .target(
            name: "TableRoadVertica",
            dependencies: [
                "TableRoadCore", "TableRoadSQL",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        // Microsoft SQL Server / Azure SQL over TDS 7.4 (own implementation on SwiftNIO).
        .target(
            name: "TableRoadSQLServer",
            dependencies: [
                "TableRoadCore", "TableRoadSQL",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        .target(
            name: "TableRoadPostgres",
            dependencies: [
                "TableRoadCore", "TableRoadSQL",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        // ClickHouse over its HTTP interface (no extra dependencies).
        .target(name: "TableRoadClickHouse", dependencies: ["TableRoadCore", "TableRoadSQL"]),
        // Cassandra over the CQL native protocol (v4) on SwiftNIO.
        .target(
            name: "TableRoadCassandra",
            dependencies: [
                "TableRoadCore", "TableRoadSQL",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        // Oracle Database: a pure-Swift thin client for Oracle Net (TNS/TTC, O5LOGON) on Network.framework.
        .target(name: "TableRoadOracle", dependencies: ["TableRoadCore", "TableRoadSQL"]),
        // Redis / Valkey: a small RESP2 client on Network.framework.
        .target(name: "TableRoadRedis", dependencies: ["TableRoadCore"]),
        // SQLite through the system library.
        .target(
            name: "TableRoadSQLite", dependencies: ["TableRoadCore", "TableRoadSQL"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        // Export (CSV, JSON, SQL dump, Excel) and SQL dump import. zlib (system) for gzip and .xlsx (zip).
        // Backup schedules and database sync: dumps to folders, syncs between connections, restores dump files.
        .target(
            name: "TableRoadBackup",
            dependencies: ["TableRoadCore", "TableRoadSQL", "TableRoadTransfer", "TableRoadStorage"]
        ),
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
            name: "TableRoadClickHouseTests",
            dependencies: ["TableRoadClickHouse", "TableRoadSQL", "TableRoadTransfer"]),
        .testTarget(
            name: "TableRoadCassandraTests", dependencies: ["TableRoadCassandra", "TableRoadSQL", "TableRoadTransfer"]),
        .testTarget(name: "TableRoadRedisTests", dependencies: ["TableRoadRedis"]),
        .testTarget(
            name: "TableRoadOracleTests", dependencies: ["TableRoadOracle", "TableRoadSQL", "TableRoadTransfer"]),
        .testTarget(name: "TableRoadSQLiteTests", dependencies: ["TableRoadSQLite", "TableRoadSQL"]),
        .testTarget(
            name: "TableRoadPostgresTests", dependencies: ["TableRoadPostgres", "TableRoadSQL", "TableRoadTransfer"]),
        .testTarget(
            name: "TableRoadTransferTests",
            dependencies: ["TableRoadTransfer", "TableRoadMySQL", "TableRoadSQL", "TableRoadSQLite"]),
        .testTarget(name: "TableRoadSQLServerTests", dependencies: ["TableRoadSQLServer", "TableRoadSQL"]),
        .testTarget(name: "TableRoadVerticaTests", dependencies: ["TableRoadVertica", "TableRoadSQL"]),
        .testTarget(
            name: "TableRoadBackupTests",
            dependencies: [
                "TableRoadBackup", "TableRoadTransfer", "TableRoadMySQL", "TableRoadSQL", "TableRoadSQLite",
                "TableRoadPostgres", "TableRoadStorage",
            ]),
    ],
    swiftLanguageModes: [.v6]
)
