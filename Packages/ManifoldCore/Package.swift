// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ManifoldCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ManifoldCore", targets: ["ManifoldCore"])
    ],
    targets: [
        .target(
            name: "ManifoldCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
