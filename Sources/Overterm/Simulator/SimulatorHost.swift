import AppKit

/// Xcode's own simulator frameworks, reached through the Objective-C
/// runtime — what Simulator.app itself draws and taps with.
///
/// There is no public API for either: `simctl` can boot a device and take
/// a screenshot, and nothing more. Every tool that puts a simulator inside
/// its own window — Radon IDE, idb, the rest — links CoreSimulator and
/// SimulatorKit out of the installed Xcode and does what this does. So:
///
/// - nothing is bundled; the frameworks are the ones this Mac's Xcode has,
///   found through `xcode-select`,
/// - every step is failable, and a step that fails leaves the pane on
///   `simctl` screenshots (`SimulatorMirror`) rather than empty,
/// - no symbol is linked at build time, so a missing class or function is
///   a nil here and not a crash at launch.
@MainActor
enum SimulatorHost {
    private(set) static var isLoaded = false
    /// The version of the CoreSimulator that was loaded, for the input rule.
    private(set) static var coreSimulatorVersion: String?

    private static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"

    /// Opens both frameworks (once). False: this Mac has no Xcode, or its
    /// Xcode keeps them somewhere else.
    @discardableResult
    static func load(developerDirectory: String) -> Bool {
        if isLoaded { return true }
        let kit = "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        guard dlopen("\(coreSimulatorPath)/CoreSimulator", RTLD_NOW) != nil, dlopen(kit, RTLD_NOW) != nil,
            NSClassFromString("SimServiceContext") != nil
        else { return false }
        coreSimulatorVersion =
            (NSDictionary(contentsOfFile: "\(coreSimulatorPath)/Resources/Info.plist")?["CFBundleShortVersionString"] as? String)
        isLoaded = true
        return true
    }

    /// SimulatorKit's handle, for the Indigo message builders.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }

    /// The `SimDevice` behind a UDID, from the default device set.
    static func device(udid: String, developerDirectory: String) -> NSObject? {
        guard load(developerDirectory: developerDirectory),
            let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type,
            let context = contextClass.perform(
                Selector(("sharedServiceContextForDeveloperDir:error:")), with: developerDirectory, with: nil
            )?.takeUnretainedValue() as? NSObject,
            let set = context.perform(Selector(("defaultDeviceSetWithError:")), with: nil)?.takeUnretainedValue() as? NSObject,
            let devices = set.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return devices.first { ($0.value(forKey: "UDID") as? UUID)?.uuidString.lowercased() == udid.lowercased() }
    }

    /// Whether a device is booted — a shut-down one must not be sent to.
    static func isBooted(_ device: NSObject) -> Bool {
        (device.value(forKey: "state") as? NSNumber)?.intValue == 3
    }

    /// Whether the guest still takes the legacy (Indigo) input this sends.
    ///
    /// From CoreSimulator 1155.4 (Xcode 27) the guest drops it for the
    /// whole boot: the bytes arrive and nothing happens, which is worse
    /// than refusing, so the pane says so rather than letting you tap at
    /// a picture (the finding is idb's, which hit it first).
    static var acceptsInput: Bool { !suppressesLegacyInput(coreSimulatorVersion) }

    /// Pure, and the reason it is: the rule is a version comparison that
    /// has to be numeric — 1155.10 is newer than 1155.4, not older.
    static func suppressesLegacyInput(_ version: String?) -> Bool {
        guard let version else { return false }
        return version.compare("1155.4", options: .numeric) != .orderedAscending
    }
}
