import AppKit

/// What the app does at launch — the `Overterm` executable's whole
/// `main.swift` (Sources/OvertermApp) is a call to this. The app's code is a
/// library of its own so that a test build compiles it once: the tests and
/// the executable link the same module.
package enum AppMain {
    /// The application's delegate, held: `NSApplication.delegate` is weak.
    @MainActor private static var delegate: AppDelegate?

    @MainActor package static func run() -> Never {
        // libghostty's process-wide init has to precede every other call into it.
        guard GhosttyRuntime.initialize() else {
            FileHandle.standardError.write(Data("overterm: ghostty_init failed\n".utf8))
            exit(1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}
