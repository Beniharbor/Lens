// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lens",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored (see Vela's Vendor/KeyboardShortcuts) with #Preview blocks
        // stripped — the Xcode-only PreviewsMacros plugin is missing from
        // Command Line Tools and breaks `swift build`.
        .package(path: "Vendor/KeyboardShortcuts"),
    ],
    targets: [
        .executableTarget(
            name: "Lens",
            dependencies: [
                "KeyboardShortcuts",
            ],
            path: "Sources/Lens",
            resources: [
                .copy("Resources/LensMark.svg"),
            ]
        )
    ]
)
