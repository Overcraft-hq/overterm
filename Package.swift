// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Terminus",
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
            name: "Terminus",
            dependencies: ["GhosttyKit"],
            path: "Sources/Terminus",
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
            name: "TerminusTests",
            dependencies: ["Terminus"],
            path: "Tests/TerminusTests"
        ),
        // Launches the built app per scenario; opt-in (make e2e).
        .testTarget(
            name: "TerminusE2ETests",
            path: "Tests/TerminusE2ETests"
        ),
    ]
)
