import Foundation

/// What names an Overterm run in a child's argv (docs/design/activity/
/// analysis.md, 6.9, D-15), for the children whose environment can't be
/// read — platform binaries are `CS_RESTRICT`: `/usr/bin/ssh`, Apple's perl
/// — or that outlive a crash with nothing else to say whose they are. Each
/// names the run by its pid **and start** (base 36, `OvertermRun.start36`),
/// so a later Overterm that gets the same pid isn't taken for the dead run.
/// None is a secret. Pure: the names are made and read here, and nothing
/// else spells them.
package enum ArgvSign: Hashable, Sendable {
    /// A kubectl proxy's or port-forward's socket folder,
    /// `/tmp/ot-kube-<uid>-<pid>-<start36>/` (`KubeSocketFolder`).
    case kubectl(ActivityProcessID)
    /// Docker's ssh forward's local socket, `ot-docker-<pid>-<start36>-<key>.sock`
    /// (`DockerSSHForward.localSocket`).
    case dockerSSH(ActivityProcessID)
    /// The database tunnel's `ControlPath`, `$TMPDIR/ot-run-<pid>-<start36>/db-<id>`:
    /// a path nothing creates (`SSHTunnel.controlPath`).
    case databaseTunnel(ActivityProcessID)
    /// A scenario's stand-in, its script under the run's scratch folder
    /// `overterm-e2e-<UUID>/`: left by a test run, never the app's.
    case testScratch(String)

    /// The run it names; nil for a scratch folder, which names a test run by its folder.
    package var run: ActivityProcessID? {
        switch self {
        case .kubectl(let run), .dockerSSH(let run), .databaseTunnel(let run): run
        case .testScratch: nil
        }
    }

    package static let kubePrefix = "ot-kube-"
    package static let dockerPrefix = "ot-docker-"
    package static let runPrefix = "ot-run-"
    package static let scratchPrefix = "overterm-e2e-"

    /// `ot-kube-<uid>-<pid>-<start36>`.
    package static func kubeFolder(uid: uid_t, run: ActivityProcessID) -> String {
        "\(kubePrefix)\(uid)-\(run.pid)-\(OvertermRun.base36(run.start))"
    }

    /// `ot-docker-<pid>-<start36>-<key>.sock`.
    package static func dockerSocket(run: ActivityProcessID, key: String) -> String {
        "\(dockerPrefix)\(run.pid)-\(OvertermRun.base36(run.start))-\(key).sock"
    }

    /// `ot-run-<pid>-<start36>`: the database tunnel's ControlPath's folder.
    package static func runFolder(run: ActivityProcessID) -> String {
        "\(runPrefix)\(run.pid)-\(OvertermRun.base36(run.start))"
    }

    /// Every sign in `command` — argv joined, masked or not: the signs are
    /// paths, which masking keeps. Bounded by the command's length.
    package static func signs(in command: String) -> [ArgvSign] {
        // Most commands carry none: one byte search for what every prefix
        // shares, before any walk by characters (a full tick asks it of
        // every process of the user's).
        guard ProcessRole.containsBytes(command, "ot-") || ProcessRole.containsBytes(command, scratchPrefix) else { return [] }
        var found: [ArgvSign] = []
        let text = Substring(command)
        for start in occurrences(of: kubePrefix, in: text) {
            // `<uid>-<pid>-<start36>/`, inside a path.
            guard start > text.startIndex, text[text.index(before: start)] == "/" else { continue }
            let fields = text[text.index(start, offsetBy: kubePrefix.count)...].prefix { $0 != "/" }.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3, uid_t(fields[0]) != nil, let run = identity(fields[1], fields[2]) else { continue }
            found.append(.kubectl(run))
        }
        for start in occurrences(of: dockerPrefix, in: text) {
            let name = text[text.index(start, offsetBy: dockerPrefix.count)...].prefix { $0 != "/" && $0 != ":" && $0 != " " }
            guard name.hasSuffix(".sock") else { continue }
            let fields = name.dropLast(".sock".count).split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3, let run = identity(fields[0], fields[1]) else { continue }
            found.append(.dockerSSH(run))
        }
        for start in occurrences(of: runPrefix, in: text) {
            guard start > text.startIndex, text[text.index(before: start)] == "/" else { continue }
            let rest = text[text.index(start, offsetBy: runPrefix.count)...]
            let folder = rest.prefix { $0 != "/" }
            guard rest.dropFirst(folder.count).hasPrefix("/db-") else { continue }
            let fields = folder.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 2, let run = identity(fields[0], fields[1]) else { continue }
            found.append(.databaseTunnel(run))
        }
        for start in occurrences(of: scratchPrefix, in: text) {
            guard start > text.startIndex, text[text.index(before: start)] == "/" else { continue }
            let id = text[text.index(start, offsetBy: scratchPrefix.count)...].prefix { $0 != "/" && $0 != " " && $0 != "'" }
            guard UUID(uuidString: String(id)) != nil else { continue }
            found.append(.testScratch(String(id)))
        }
        return found
    }

    private static func identity(_ pid: Substring, _ start: Substring) -> ActivityProcessID? {
        guard let pid = pid_t(pid), pid > 0, let start = OvertermRun.fromBase36(start) else { return nil }
        return ActivityProcessID(pid: pid, start: start)
    }

    /// Where `needle` starts in `text`, every time, left to right.
    private static func occurrences(of needle: String, in text: Substring) -> [Substring.Index] {
        var found: [Substring.Index] = []
        var rest = text[...]
        while let range = rest.range(of: needle) {
            found.append(range.lowerBound)
            rest = rest[range.upperBound...]
        }
        return found
    }
}
