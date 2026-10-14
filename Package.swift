// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Overterm",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Built locally by `make ghosttykit` (Scripts/build-ghosttykit.sh); not
        // committed. A static library + the GhosttyKit module map.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Overterm",
            dependencies: ["GhosttyKit"],
            path: "Sources/Overterm",
            linkerSettings: [
                // libghostty's C++ deps (glslang, spirv-cross, simdutf) and the
                // system frameworks its Zig code links against.
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "OvertermTests",
            dependencies: ["Overterm"],
            path: "Tests/OvertermTests"
        ),
        // Launches the built app per scenario; opt-in (make e2e).
        .testTarget(
            name: "OvertermE2ETests",
            path: "Tests/OvertermE2ETests"
        ),
    ]
)
