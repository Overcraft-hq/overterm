import AppKit

/// `simctl`, the way the rest of the app runs tools: a GCD thread per call
/// (`Git.run`), never the main one and never a blocked concurrency thread.
enum SimulatorControl {
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static var scratch: URL { FileManager.default.temporaryDirectory }

    /// Whether there are command line tools with a simulator behind them —
    /// `xcrun` is on every Mac, Xcode is not.
    static func isPresent() async -> Bool { await developerDirectory() != nil }

    /// `xcode-select -p`, asked once: Simulator.app lives under it.
    nonisolated(unsafe) private static var developerPath: String?
    private static let pathLock = NSLock()

    static func developerDirectory() async -> String? {
        if let known = pathLock.withLock({ developerPath }) { return known }
        guard
            let path = try? await Git.run(
                URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], in: scratch, timeout: 10
            ).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        pathLock.withLock { developerPath = path }
        return path
    }

    /// Every available device, booted first (SimulatorList's order).
    static func devices() async -> [SimulatorDevice] {
        guard let json = try? await Git.run(xcrun, ["simctl", "list", "devices", "--json"], in: scratch, timeout: 30) else { return [] }
        return SimulatorList.devices(fromJSON: Data(json.utf8))
    }

    /// Boots a device (and leaves it booted); `simctl` says so itself when
    /// it is already up, which is not an error here.
    static func boot(_ udid: String) async {
        _ = try? await Git.run(xcrun, ["simctl", "boot", udid], in: scratch, success: [0, 149, 164], timeout: 60)
    }

    /// Simulator.app — the window we mirror is its.
    static func openSimulator(device: SimulatorDevice?, activate: Bool = false) async {
        guard let developer = await developerDirectory() else { return }
        if let device, !device.isBooted { await boot(device.udid) }
        let app = URL(fileURLWithPath: developer).appendingPathComponent("Applications/Simulator.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // It comes up where it was; Overterm keeps the keyboard unless the
        // point was to go and tap on it.
        configuration.activates = activate
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// The device's own screen, straight out of CoreSimulator — no window
    /// and no screen recording. A BMP: `simctl` spends most of a PNG's
    /// 0.6 s encoding it, and this pane throws the pixels away anyway
    /// (SimulatorMirror cuts the frame down with ImageIO).
    static func screenshot(_ udid: String) async -> Data? {
        let file = scratch.appendingPathComponent("overterm-sim-\(udid).bmp")
        guard (try? await Git.run(xcrun, ["simctl", "io", udid, "screenshot", "--type", "bmp", file.path], in: scratch, timeout: 20)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }
}
