// swift-tools-version:6.1
import PackageDescription

// `#if E2E` (the scenarios, the fakes): every debug build, a release build
// only with the E2E trait.
let e2eSettings: [SwiftSetting] = [
    .define("E2E", .when(configuration: .debug)),
    .define("E2E", .when(traits: ["E2E"])),
]

/// A module of the app over `below`, with every package the app uses (an
/// unused one costs nothing).
func feature(_ name: String, over below: [String]) -> Target {
    .target(
        name: name,
        dependencies: below.map { .target(name: $0) } + [
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
        path: "Sources/\(name)",
        swiftSettings: e2eSettings
    )
}

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
        // The app's code is a stack of library modules, one package: each
        // depends only on those below it, and shares what others use as
        // `package` (docs/architecture.md, Targets). Split so a release build
        // optimises them on several cores, and a change rebuilds what is
        // above it only.
        //
        // OvertermCore: what depends on nothing else of the app — parsers,
        // pure models, git, shell words, the transport.
        .target(
            name: "OvertermCore",
            dependencies: [
                "GhosttyKit", "TreeSitterKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/OvertermCore",
            swiftSettings: e2eSettings
        ),
        // Overterm: the shell under the features — tabs, terminals, the
        // editor, settings, Activity — and the few pieces of a feature it
        // holds itself (docs/architecture.md, Targets).
        .target(
            name: "Overterm",
            dependencies: [
                "OvertermCore",
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
            swiftSettings: e2eSettings,
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
        // The features, each over the shell and the ones it uses:
        // Database, then Docker (its containers' databases), Kubernetes
        // (Docker's images and CLI), Terraform (a context's class).
        feature("OvertermDatabase", over: ["Overterm"]),
        feature("OvertermDocker", over: ["OvertermDatabase"]),
        // OvertermAPI: the API client (⌥⌘R), under Kubernetes (a forward's
        // API docs, its discovery).
        feature("OvertermAPI", over: ["Overterm"]),
        feature("OvertermKubernetes", over: ["OvertermDocker", "OvertermAPI"]),
        feature("OvertermTerraform", over: ["OvertermKubernetes"]),
        // OvertermShell: the window and what holds the features together —
        // TerminalWindowController and its extensions, the app delegate, the
        // menus, the right slot and the sidebar — and the E2E scenarios.
        // OvertermOvergit: the git panel (⌥⌘G), beside the features: only
        // the window shows it.
        feature("OvertermOvergit", over: ["Overterm"]),
        // OvertermNotes: the notes vault (⌥⌘N), beside the features.
        feature("OvertermNotes", over: ["Overterm"]),
        // OvertermSimulator: the iOS simulator in the browser's column.
        feature("OvertermSimulator", over: ["Overterm"]),
        // OvertermUsage: what the agents have spent, the strip's chip and pane.
        feature("OvertermUsage", over: ["Overterm"]),
        // OvertermSettingsPage: ⌘, — the page, the themes' gallery and editor.
        feature("OvertermSettingsPage", over: ["Overterm"]),
        // OvertermAgents: the agents' overview (⇧⌘A) and the Sessions panel.
        feature("OvertermAgents", over: ["Overterm"]),
        // OvertermActivity: the Activity page (⌥⌘A) and its agents' tools;
        // what the rest reads of processes and ports stays in the shell.
        feature("OvertermActivity", over: ["Overterm"]),
        feature(
            "OvertermShell",
            over: [
                "OvertermTerraform", "OvertermOvergit", "OvertermNotes", "OvertermSimulator", "OvertermUsage", "OvertermSettingsPage",
                "OvertermAgents", "OvertermActivity",
            ]),
        // The app: Sources/OvertermApp/main.swift starts the library. Its
        // product keeps the name the binary always had (make-app.sh, the
        // docs' `.build/debug/Overterm`).
        .executableTarget(
            name: "OvertermApp",
            dependencies: ["OvertermShell"],
            path: "Sources/OvertermApp"
        ),
        .testTarget(
            name: "OvertermTests",
            dependencies: ["OvertermShell"],
            path: "Tests/OvertermTests"
        ),
        // Launches the built app per scenario; opt-in (make e2e).
        .testTarget(
            name: "OvertermE2ETests",
            path: "Tests/OvertermE2ETests"
        ),
    ]
)
