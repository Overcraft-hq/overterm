import Foundation

/// Listeners people meet without having started them (docs/design/activity/
/// analysis.md, 6.8, Owners rule 8): named, with what they are and where
/// they are turned off. Never a kill. Pure.
enum KnownHolders {
    /// What one is.
    struct Holder: Hashable, Sendable {
        /// What people know it as: "AirPlay Receiver".
        let name: String
        /// What it is and where it is turned off.
        let note: String
        /// The page's word for it in the filter's `owner:` (6.6).
        let word: String
    }

    /// AirPlay Receiver's ports: ControlCenter holds them while it is on.
    static let airPlayPorts: Set<Int> = [5000, 7000]

    static let airPlay = Holder(
        name: "AirPlay Receiver", note: "AirPlay Receiver (ControlCenter): turned off in System Settings ▸ General ▸ AirDrop & Handoff",
        word: "macos")

    /// `process`, by its executable's file or name, holding `port`.
    static func holder(_ process: String, port: Int) -> Holder? {
        switch process {
        case "ControlCenter":
            if airPlayPorts.contains(port) { return airPlay }
            return Holder(name: "Control Center", note: "Control Center, part of macOS", word: "macos")
        case "rapportd":
            return Holder(name: "Continuity", note: "Continuity (rapportd): Handoff and the Universal Clipboard, part of macOS", word: "macos")
        case "sharingd":
            return Holder(name: "AirDrop", note: "AirDrop (sharingd), part of macOS", word: "macos")
        case "adb":
            return Holder(name: "Android Debug Bridge", note: "Android Debug Bridge's server (adb): `adb kill-server` stops it", word: "elsewhere")
        default:
            if let engine = ActivityAttribution.engineHolders[process] {
                return Holder(name: "\(engine)’s engine", note: "\(engine)’s engine: it holds the ports its containers publish", word: "container")
            }
            return nil
        }
    }
}
