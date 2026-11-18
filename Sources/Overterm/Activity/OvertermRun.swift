import Darwin
import Foundation

/// Which Overterm started a process (docs/design/activity/analysis.md, 6.9,
/// D-15): this run — its pid and start, and whether it is a release, a
/// development build or an isolated run (a scenario, a layout dump, a unit
/// test). `OVERTERM_RUN=<kind>.<pid>.<start µs>` goes in every pane's
/// environment, and with `OVERTERM_HELPER=<helper>` on every child Overterm
/// spawns, set where each spawn path builds its environment. It names a pid
/// and a time, and is no secret.
///
/// Platform binaries hide their environment (`CS_RESTRICT`), so `/usr/bin/ssh`
/// and Apple's perl carry it unseen: those children name the run in their
/// argv instead (`ArgvSigns`), by the same pid and start (`start36`).
struct OvertermRun: Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// An installed Overterm: `Overterm.app` in /Applications or ~/Applications.
        case release
        /// Any other build: the repository's, Overterm Dev beside the release.
        case dev
        /// A scenario, a layout dump or a unit test (`AppEnvironment.isIsolated`):
        /// what it leaves is "left by a test run", never the app's.
        case isolated

        /// This process's kind, from its bundle's path — pure.
        static func of(isolated: Bool, bundlePath: String, home: String) -> Kind {
            if isolated { return .isolated }
            let url = URL(fileURLWithPath: bundlePath)
            guard url.lastPathComponent == "Overterm.app" else { return .dev }
            let folder = url.deletingLastPathComponent().path
            return folder == "/Applications" || folder == (home as NSString).appendingPathComponent("Applications") ? .release : .dev
        }
    }

    /// Which of Overterm's children it is: `OVERTERM_HELPER`'s value. One a
    /// spawn path; none is a secret.
    enum Helper: String, Sendable, CaseIterable {
        case kubectlProxy = "kubectl-proxy"
        case kubectlPortForward = "kubectl-port-forward"
        /// `kubectl auth can-i`, `kubectl apply`, `kustomize` (`KubeProcessRun`).
        case kubectl
        case helm
        case dockerSSH = "docker-ssh"
        case dockerCLI = "docker-cli"
        case databaseTunnel = "database-tunnel"
        case languageServer = "language-server"
        case git
        /// The login shell asked for its environment (`ShellEnvironment`).
        case loginShell = "login-shell"
        case agentUsage = "agent-usage"
        /// A validate, fmt, plan, init, state read or test (`TerraformRun`, `TerraformStreamRun`).
        case terraform
        /// A detached apply's launcher, and the terraform it starts.
        case terraformApply = "terraform-apply"
        /// Activity's one read of every user's listeners (`NettopListeners`).
        case nettop
        /// Any other `ManagedProcess`.
        case managed
    }

    static let variable = "OVERTERM_RUN"
    static let helperVariable = "OVERTERM_HELPER"

    let kind: Kind
    let identity: ActivityProcessID

    var pid: pid_t { identity.pid }
    var start: UInt64 { identity.start }

    /// `OVERTERM_RUN`'s value: `<kind>.<pid>.<start µs>`.
    var marker: String { "\(kind.rawValue).\(identity.pid).\(identity.start)" }

    /// The start in base 36, as the argv signs carry it: short enough for a
    /// unix socket's path, and exact.
    var start36: String { Self.base36(identity.start) }

    /// This process's.
    static let current: OvertermRun = {
        let pid = getpid()
        let start = ProcessInspector.kinfo(pid)?.start ?? 0
        let kind = Kind.of(isolated: AppEnvironment.isIsolated, bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory())
        return OvertermRun(kind: kind, identity: ActivityProcessID(pid: pid, start: start))
    }()

    /// The run `OVERTERM_RUN`'s value names, and its kind; nil for anything
    /// else (`<kind>.<pid>.<start>` with a known kind).
    init?(marker: String) {
        let parts = marker.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])), let pid = pid_t(parts[1]), pid > 0, let start = UInt64(parts[2]) else {
            return nil
        }
        self.init(kind: kind, identity: ActivityProcessID(pid: pid, start: start))
    }

    init(kind: Kind, identity: ActivityProcessID) {
        self.kind = kind
        self.identity = identity
    }

    /// The two markers for a child of this run's that is `helper`.
    func markers(helper: Helper) -> [String: String] {
        [Self.variable: marker, Self.helperVariable: helper.rawValue]
    }

    /// `environment` with this run's markers for `helper` — set over any it
    /// inherited: an Overterm started from another's pane carries that one's.
    func marking(_ environment: [String: String], helper: Helper) -> [String: String] {
        environment.merging(markers(helper: helper)) { _, own in own }
    }

    /// `environment` without either marker: what a login shell printed, its
    /// own markers among it, before another child is given it (`ShellEnvironment`).
    static func unmarked(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key != variable && $0.key != helperVariable }
    }

    static func base36(_ value: UInt64) -> String { String(value, radix: 36) }

    static func fromBase36(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.count <= 13, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLowercase) }) else { return nil }
        return UInt64(text, radix: 36)
    }
}
