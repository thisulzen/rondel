// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rondel",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RondelCore"),
        .executableTarget(name: "Rondel", dependencies: ["RondelCore"]),
        .testTarget(name: "RondelCoreTests", dependencies: ["RondelCore"]),
        .testTarget(name: "RondelTests", dependencies: ["Rondel"]),
    ],
    // The converter shares a little state between threads behind a lock, and
    // AppKit is main-thread only anyway. Swift 6's strict checking would want
    // that restated in types everywhere without catching anything new.
    swiftLanguageModes: [.v5]
)
