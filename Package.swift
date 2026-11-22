// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Overterm",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Overterm", targets: ["OvertermApp"])
    ],
    // The end-to-end scenarios (Sources/Overterm/E2E) and the tests' fake
    // servers (Fake*.swift) are `#if E2E`: in every debug build, and in a
    // release build only with `--traits E2E` — a shipped app carries none
    // of them (45,000 lines the release build no longer optimises).
    traits: [
        .trait(name: "E2E", description: "The end-to-end scenarios and the tests' fake servers, in a release build")
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
        // gRPC's transport: HTTP/2 with trailers, and h2c to a local server —
        // neither of which URLSession gives.
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.46.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        // Oracle's TNS protocol, its sign-in's verifiers and TCPS: too much to
        // write here (OracleTests runs it against Oracle Free). Pinned exactly —
        // a release candidate; its tracing trait off, as nothing reads spans.
        .package(url: "https://github.com/lovetodream/oracle-nio.git", exact: "1.0.0-rc.4", traits: []),
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
        // The app's code, as a library: the executable below and the tests
        // both link this one module, so a test build compiles it once (as an
        // executable target the tests' build compiled it a second time, as
        // a testable copy). `main` is the executable's.
        .target(
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
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "OracleNIO", package: "oracle-nio"),
            ],
            path: "Sources/Overterm",
            swiftSettings: [
                .define("E2E", .when(configuration: .debug)),
                .define("E2E", .when(traits: ["E2E"])),
            ],
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
        // The app: Sources/OvertermApp/main.swift starts the library. Its
        // product keeps the name the binary always had (make-app.sh, the
        // docs' `.build/debug/Overterm`).
        .executableTarget(
            name: "OvertermApp",
            dependencies: ["Overterm"],
            path: "Sources/OvertermApp"
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
