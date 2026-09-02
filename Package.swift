// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-heos",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "HEOSKit", targets: ["HEOSKit"]),
        .library(name: "NeosDomain", targets: ["NeosDomain"])
    ],
    targets: [
        .target(name: "NeosDomain", path: "Sources/NeosDomain"),
        .target(
            name: "HEOSKit",
            dependencies: ["NeosDomain"],
            path: "Sources/HEOSKit"
        ),
        .testTarget(
            name: "NeosDomainTests",
            dependencies: ["NeosDomain"],
            path: "Tests/NeosDomainTests"
        ),
        .testTarget(
            name: "HEOSKitTests",
            dependencies: ["HEOSKit"],
            path: "Tests/HEOSKitTests"
        )
    ]
)
