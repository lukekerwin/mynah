// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mynah",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Persistence and pure logic (no AppKit), unit-tested.
        .target(name: "MynahCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                path: "Sources/MynahCore"),
        .executableTarget(name: "Mynah",
                          dependencies: ["MynahCore", .product(name: "GRDB", package: "GRDB.swift"),
                                         .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Mynah"),
        .testTarget(name: "MynahCoreTests", dependencies: ["MynahCore"], path: "Tests/MynahCoreTests"),
    ]
)
