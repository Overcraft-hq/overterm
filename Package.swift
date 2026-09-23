// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Terminus",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Terminus",
            path: "Sources/Terminus"
        )
    ]
)
