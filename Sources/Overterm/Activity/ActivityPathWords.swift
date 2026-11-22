import Foundation

/// What a process's path and names say to its owner (docs/design/activity/
/// analysis.md, 6.5): its file, app and bundle, an XPC service's or a VM's
/// path, another Overterm's app, a known engine's or macOS's agent. Strings
/// only, read once an identity and kept while the strings it was read from
/// are the same (10.4): a crowded Mac's owners split and searched thousands
/// of paths a tick otherwise, every tick the same ones.
package struct ActivityPathWords: Sendable {
    /// What it was read from: read again when any changed (an `exec`, a
    /// name read since).
    package let path: String?
    package let name: String?
    package let shortName: String
    /// The path's last component.
    package let file: String?
    /// The outermost `.app` on the path (`ActivityAttribution.appName`).
    package let app: String?
    /// The app whose own executable it is (`ActivityPaneSet.appBundle`).
    package let bundle: String?
    /// Inside an `.xpc` bundle, or a Virtualization executable (rule 13's
    /// path, `ActivityAttribution.isServiceOrVM`).
    package let serviceOrVM: Bool
    /// Its executable — the path's file, else `p_comm` — is a VM's (rule 6).
    package let vmExecutable: Bool
    /// Rule 10 by its executable: another Overterm app's name.
    package let overtermApp: String?
    /// Rule 6's known holder, by its executable's file or its name.
    package let engine: String?
    /// Rule 14's known agent, by its file or its name; nil without a name.
    package let appleAgent: String?
    /// Under `/System/`.
    package let underSystem: Bool
    /// Under `/System/`, `/usr/libexec/` or `/usr/sbin/`.
    package let macOSPath: Bool

    package init(path: String?, name: String?, shortName: String) {
        self.path = path
        self.name = name
        self.shortName = shortName
        let file = path.map(ActivityAttribution.fileName)
        self.file = file
        app = ActivityAttribution.appName(of: path)
        let bundle = path.flatMap(ActivityPaneSet.appBundle)
        self.bundle = bundle
        if let path, let file {
            serviceOrVM =
                ProcessRole.contains(path, ".xpc/") || ProcessRole.contains(path, "/XPCServices/") || file.contains("Virtualization")
                || file.contains("VirtualMachine")
        } else {
            serviceOrVM = false
        }
        let executable = file ?? shortName
        vmExecutable = executable.contains("Virtualization") || executable.contains("VirtualMachine")
        if let path, let file, ProcessRole.contains(path, "overterm"), let bundle, let app = ActivityAttribution.appName(of: bundle),
            app.hasPrefix("Overterm"), file == "Overterm"
        {
            overtermApp = app
        } else {
            overtermApp = nil
        }
        engine = ActivityAttribution.engineHolders[executable] ?? ActivityAttribution.engineHolders[name ?? shortName]
        if let name {
            appleAgent = ActivityAttribution.appleAgents[file ?? name] ?? ActivityAttribution.appleAgents[name]
        } else {
            appleAgent = nil
        }
        underSystem = path?.hasPrefix("/System/") ?? false
        macOSPath = path.map { path in ["/System/", "/usr/libexec/", "/usr/sbin/"].contains { path.hasPrefix($0) } } ?? false
    }

    /// Whether these were read from these strings.
    package func describes(path: String?, name: String?, shortName: String) -> Bool {
        self.path == path && self.name == name && self.shortName == shortName
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var kept: [ActivityProcessID: ActivityPathWords] = [:]

    /// The words read so far, by identity.
    package static func cached() -> [ActivityProcessID: ActivityPathWords] { lock.withLock { kept } }

    /// `made` kept; the lot dropped when it grows past four times what
    /// lives (`live`) and 4,096 — ended identities go with it.
    package static func remember(_ made: [ActivityProcessID: ActivityPathWords], live: Int) {
        guard !made.isEmpty else { return }
        lock.withLock {
            if kept.count + made.count > max(4 * live, 4_096) { kept = [:] }
            kept.merge(made) { _, new in new }
        }
    }
}
