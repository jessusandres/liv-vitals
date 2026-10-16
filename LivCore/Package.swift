// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LivCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LivCore", targets: ["LivCore"]),
        .library(name: "LivWidgetsUI", targets: ["LivWidgetsUI"]),
    ],
    targets: [
        .target(name: "LivCore"),
        // The widget faces and definitions: SwiftUI and WidgetKit, so LivCore itself stays free of UI.
        .target(name: "LivWidgetsUI", dependencies: ["LivCore"]),
        .testTarget(name: "LivCoreTests", dependencies: ["LivCore"]),
        .testTarget(name: "LivWidgetsUITests", dependencies: ["LivWidgetsUI"]),
    ]
)
