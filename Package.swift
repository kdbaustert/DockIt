// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockIt",
    // macOS 26 rather than the usual 14: the bar, the name labels and the settings are Liquid Glass
    // (`glassEffect`), which exists nowhere earlier. The string form because `.v26` needs tools 6.2
    // and nothing else here does.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DockIt",
            path: "Sources/DockIt",
            // Swift 6 language mode. Everything DockIt does happens on the main actor — the panel,
            // NSWorkspace notifications, a main-run-loop pointer timer — so strict checking costs
            // nothing and catches the one mistake that would matter: a drag-and-drop callback
            // touching the model from the thread NSItemProvider happened to call it on.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DockItTests",
            dependencies: ["DockIt"],
            path: "Tests/DockItTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
