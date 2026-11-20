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

    /// macOS's own daemons people meet in a port list (D-25: every user's
    /// listeners, read through nettop): what each is, and where it is
    /// turned off when there is a switch. Never a kill.
    static let macOSDaemons: [String: (name: String, switch: String?)] = [
        "mDNSResponder": ("Bonjour", nil),
        "netbiosd": ("NetBIOS names for Windows file sharing", nil),
        "syslogd": ("The system log", nil),
        "remotepairingd": ("Pairing with your devices", nil),
        "remoted": ("Remote device services", nil),
        "cupsd": ("Printing", "Printer Sharing is in System Settings ▸ General ▸ Sharing"),
        "screensharingd": ("Screen Sharing", "System Settings ▸ General ▸ Sharing"),
        "ARDAgent": ("Remote Management", "System Settings ▸ General ▸ Sharing"),
        "smbd": ("File Sharing", "System Settings ▸ General ▸ Sharing"),
        "sshd": ("Remote Login", "System Settings ▸ General ▸ Sharing"),
        "sshd-session": ("Remote Login", "System Settings ▸ General ▸ Sharing"),
        "bootpd": ("Internet Sharing", "System Settings ▸ General ▸ Sharing"),
        "kdc": ("Kerberos", nil),
        "timed": ("Time sync", nil),
        "configd": ("Network configuration", nil),
        "identityservicesd": ("iMessage and FaceTime", nil),
        "apsd": ("Push notifications", nil),
        "UserEventAgent": ("System events", nil),
        "AirPlayXPCHelper": ("AirPlay", nil),
        "WiFiAgent": ("Wi-Fi", nil),
        "airportd": ("Wi-Fi", nil),
        "symptomsd": ("Network diagnostics", nil),
        "launchd": ("launchd", nil),
    ]

    /// Tools of the user's whose listeners aren't servers they asked for —
    /// a tunnel client's inspector, an app's sync — by executable, and the
    /// port each is known on (nil: any).
    static let tools: [String: (name: String, note: String, port: Int?)] = [
        "ngrok": ("ngrok's inspector", "ngrok's web inspector of the requests it forwards (4040): it goes with ngrok", 4040),
        "cloudflared": ("Cloudflare Tunnel", "cloudflared, Cloudflare Tunnel's client: its metrics port; it forwards a local server to the internet", nil),
        "tailscaled": ("Tailscale", "Tailscale's daemon (tailscaled): quit Tailscale to stop it", nil),
        "Dropbox": ("Dropbox's LAN sync", "Dropbox's LAN sync (17500): turned off in Dropbox's settings", 17_500),
        "Spotify": ("Spotify Connect", "Spotify Connect (57621): it goes with Spotify", 57_621),
        "ollama": ("Ollama", "Ollama's server (11434): it goes with the Ollama app, or `ollama serve`'s terminal", 11_434),
    ]

    /// Whether a process whose name is macOS's is macOS's: a platform
    /// binary, or one under macOS's own folders (`/usr/local` is
    /// Homebrew's). A name alone is anyone's to take.
    static func isMacOSBinary(_ facts: ActivityFacts?) -> Bool {
        if facts?.codeSigning?.isPlatformBinary == true { return true }
        guard let path = facts?.path, !path.hasPrefix("/usr/local/") else { return false }
        return ["/usr/", "/System/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

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
            if let daemon = macOSDaemons[process] {
                return Holder(name: daemon.name, note: "\(daemon.name) (\(process)), part of macOS\(daemon.switch.map { ": \($0)" } ?? "")", word: "macos")
            }
            if let tool = tools[process], tool.port.map({ $0 == port }) ?? true {
                return Holder(name: tool.name, note: tool.note, word: "elsewhere")
            }
            if let engine = ActivityAttribution.engineHolders[process] {
                return Holder(name: "\(engine)’s engine", note: "\(engine)’s engine: it holds the ports its containers publish", word: "container")
            }
            return nil
        }
    }
}
