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
    ]
)
