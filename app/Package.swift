// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tern",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "../vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Tern",
            dependencies: ["GhosttyKit"],
            // An AppKit app: main-thread code unless marked otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "TernTests",
            dependencies: ["Tern"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
