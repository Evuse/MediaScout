// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "MediaScout",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "MediaScout", targets: ["MediaScout"])
    ],
    targets: [
        .target(name: "MediaScout", dependencies: [])
    ]
)
