// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SDImportCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SDImportCore",
            targets: ["SDImportCore"]
        ),
        .executable(
            name: "sdimport",
            targets: ["sdimport"]
        ),
        .executable(
            name: "SDImportApp",
            targets: ["SDImportApp"]
        ),
        .executable(
            name: "SDImportAgent",
            targets: ["SDImportAgent"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "SDImportCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "sdimport",
            dependencies: ["SDImportCore"]
        ),
        .executableTarget(
            name: "SDImportApp",
            dependencies: [
                "SDImportCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "SDImportAgent",
            dependencies: ["SDImportCore"]
        ),
        .testTarget(
            name: "SDImportCoreTests",
            dependencies: [
                "SDImportCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
