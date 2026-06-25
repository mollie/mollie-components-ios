// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MollieComponents",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MollieCore", targets: ["MollieCore"]),
        .library(name: "MolliePayments", targets: ["MolliePayments"]),
        .library(name: "MolliePaymentsUI", targets: ["MolliePaymentsUI"]),
        .library(name: "MollieComponents", targets: ["MollieComponents"]),
    ],
    targets: [
        // MARK: - Library targets

        .target(
            name: "MollieCore",
            path: "Sources/MollieCore",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "MolliePayments",
            dependencies: ["MollieCore"],
            path: "Sources/MolliePayments",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "MolliePaymentsUI",
            dependencies: ["MollieCore", "MolliePayments"],
            path: "Sources/MolliePaymentsUI",
            // Brands.xcassets is currently an empty shell; declared so
            // `Bundle.module` is generated for `CardBrandIconView`'s
            // `UIImage(named:in:)` lookup. Phase 5 lands real brand
            // artwork into the catalog without further wiring.
            resources: [
                .process("Brands.xcassets"),
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .target(
            name: "MollieComponents",
            dependencies: ["MollieCore", "MolliePayments", "MolliePaymentsUI"],
            path: "Sources/MollieComponents",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),

        // MARK: - Test targets

        .testTarget(
            name: "MollieCoreTests",
            dependencies: ["MollieCore"],
            path: "Tests/MollieCoreTests"
        ),
        .testTarget(
            name: "MolliePaymentsTests",
            dependencies: ["MolliePayments"],
            path: "Tests/MolliePaymentsTests"
        ),
        .testTarget(
            name: "MolliePaymentsUITests",
            dependencies: ["MolliePaymentsUI"],
            path: "Tests/MolliePaymentsUITests"
        ),
        .testTarget(
            name: "MollieComponentsTests",
            dependencies: ["MollieComponents"],
            path: "Tests/MollieComponentsTests"
        ),
    ]
)
