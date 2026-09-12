// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SDImportCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SDImportCore",
            targets: ["SDImportCore"]
        ),
        .library(
            name: "SDImportCommerce",
            targets: ["SDImportCommerce"]
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
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "sdimport",
            dependencies: ["SDImportCore"]
        ),
        .target(
            name: "SDImportCommerce",
            dependencies: ["SDImportCore"]
        ),
        .executableTarget(
            name: "SDImportApp",
            dependencies: [
                "SDImportCore",
                "SDImportCommerce",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.define("SDIMPORT_DIRECT")]
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
        ),
        .testTarget(
            name: "SDImportCommerceTests",
            dependencies: [
                "SDImportCommerce",
                "SDImportCore"
            ]
        )
    ]
)
