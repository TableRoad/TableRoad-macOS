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
    ],
    targets: [
        .target(name: "TableRoadCore"),
        .target(
            name: "TableRoadDesign",
            dependencies: ["TableRoadCore"]
        ),
        .testTarget(name: "TableRoadCoreTests", dependencies: ["TableRoadCore"]),
    ],
    swiftLanguageModes: [.v6]
)
