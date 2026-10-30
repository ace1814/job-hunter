// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shortlist",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        // Everything that isn't UI: the database, CSV import, company matching, and later
        // sourcing, scoring and tailoring. No SwiftUI/AppKit, so `swift test` covers it headlessly.
        .target(
            name: "ShortlistCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/ShortlistCore"
        ),
        .executableTarget(
            name: "Shortlist",
            dependencies: ["ShortlistCore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Shortlist"
        ),
        .testTarget(
            name: "ShortlistCoreTests",
            dependencies: ["ShortlistCore"],
            path: "Tests/ShortlistCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
