// swift-tools-version: 6.0
import PackageDescription

// Language mode v5 is deliberate. The app is overwhelmingly main-actor (AppKit,
// AX callbacks arrive on the main run loop), and Swift 6 strict-concurrency
// diagnostics against AppKit add a lot of friction for very little safety gain
// here. Thread discipline is enforced by review instead: everything touching
// UI or shared mutable state must be on the main queue.
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TmuxSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic, no AppKit. Everything unit-testable lives here.
        .target(
            name: "TmuxSwitcherCore",
            path: "Sources/TmuxSwitcherCore",
            swiftSettings: swiftSettings
        ),
        // The agent app: AppKit, Accessibility, event monitoring, socket.
        .executableTarget(
            name: "TmuxSwitcher",
            dependencies: ["TmuxSwitcherCore"],
            path: "Sources/TmuxSwitcher",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TmuxSwitcherCoreTests",
            dependencies: ["TmuxSwitcherCore"],
            path: "Tests/TmuxSwitcherCoreTests",
            swiftSettings: swiftSettings
        ),
    ]
)
