// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScanEngine", targets: ["ScanEngine"]),
        .executable(name: "dgscan", targets: ["dgscan"]),
    ],
    targets: [
        .target(name: "CRemovefile"),
        .target(
            name: "ScanEngine",
            dependencies: ["CRemovefile"],
            // Always optimized, even in Debug app builds: the engine's hot loops (scanning, interning, archive
            // loading) are ~10x slower at -Onone — a saved full-disk scan took 26 s to open instead of 2.5 s.
            // (-wmo would clash with Xcode's index-while-building.)
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "dgscan", dependencies: ["ScanEngine"]),
        .testTarget(name: "ScanEngineTests", dependencies: ["ScanEngine"]),
    ]
)
