// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaCard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuotaCardCore", targets: ["QuotaCardCore"]),
        .executable(name: "quota-card-ingest", targets: ["QuotaCardIngest"]),
        .executable(name: "QuotaCardApp", targets: ["QuotaCardApp"])
    ],
    targets: [
        .target(
            name: "QuotaCardCore",
            path: "Sources/QuotaCardCore"
        ),
        .executableTarget(
            name: "QuotaCardIngest",
            dependencies: ["QuotaCardCore"],
            path: "Sources/QuotaCardIngest"
        ),
        .executableTarget(
            name: "QuotaCardApp",
            dependencies: ["QuotaCardCore"],
            path: "Sources/QuotaCardApp"
        ),
        .executableTarget(
            name: "QuotaCardTests",
            dependencies: ["QuotaCardCore"],
            path: "Tests/QuotaCardCoreTests"
        )
    ]
)
