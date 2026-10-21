// swift-tools-version:5.10
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
            swiftSettings: [
                // DEBUG gates the development-only harness in DebugHooks.swift, so
                // release builds leave it out.
                .define("DEBUG", .when(configuration: .debug)),
            ],
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
    ]
)
