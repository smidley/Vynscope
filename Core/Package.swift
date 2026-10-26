// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BMWCodingCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BMWCodingCore", targets: ["BMWCodingCore"]),
    ],
    targets: [
        .target(
            name: "BMWCodingCore",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "BMWCodingCoreTests",
            dependencies: ["BMWCodingCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
