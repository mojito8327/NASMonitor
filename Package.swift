// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NASMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NASMonitor", targets: ["NASMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "NASMonitor",
            path: "Sources/NASMonitor"
        )
    ]
)
