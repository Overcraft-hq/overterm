// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Overterm",
    platforms: [
        .macOS(.v13)
    ],
    // The database client's wire protocols: PostgreSQL (and Redshift, which
    // speaks it) and MySQL — TLS, SCRAM and caching_sha2 included, which is
    // why they are packages and not ours. SQLite is the system's; ClickHouse
    // and BigQuery are HTTP.
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.2"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.2"),
        // Theirs, named for what the client itself uses: the event loops, TLS,
        // their logger, and RSA — BigQuery's service account signs a JWT.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    ],
    targets: [
        // Built locally by `make ghosttykit` (Scripts/build-ghosttykit.sh); not
        // committed. A static library + the GhosttyKit module map.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        // Built locally by `make treesitter` (Scripts/build-treesitter.sh):
        // tree-sitter and the editor's grammars, one static library.
        .binaryTarget(
            name: "TreeSitterKit",
            path: "Frameworks/TreeSitterKit.xcframework"
        ),
        .executableTarget(
            name: "Overterm",
            dependencies: [
                "GhosttyKit", "TreeSitterKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // Docker's Engine API: HTTP over its unix socket.
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
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
                // SQLite: the system's.
                .linkedLibrary("sqlite3"),
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
