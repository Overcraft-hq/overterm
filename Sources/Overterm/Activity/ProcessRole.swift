import Foundation

/// What a process is to the agent or the pane it runs under (docs/design/
/// activity/analysis.md, 6.5, Roles), read from its name and its masked
/// argv — never the raw one. Pure.
package enum ProcessRole: String, Hashable, Sendable, CaseIterable {
    /// An MCP server: `mcp` a word of its argv (`@playwright/mcp`,
    /// `acme-mcp-server`), `@modelcontextprotocol/…`.
    case mcp
    /// A shell run with a command: an agent's Bash tool, Codex's snapshot
    /// shells.
    case shell
    /// It listens on TCP.
    case server
    /// A build or a test run.
    case build
    case other

    /// Its words in the agent row's counts.
    package func counted(_ count: Int) -> String {
        switch self {
        case .mcp: "\(count) MCP"
        case .shell: count == 1 ? "1 shell" : "\(count) shells"
        case .server: count == 1 ? "1 server" : "\(count) servers"
        case .build: count == 1 ? "1 build" : "\(count) builds"
        case .other: count == 1 ? "1 other" : "\(count) others"
        }
    }

    package static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh"]
    package static let packageRunners: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    package static let builders: Set<String> = ["cargo", "xcodebuild", "pytest"]

    /// `name`'s role, its masked `command` read word by word, `listensTCP`
    /// whether it holds a TCP listener now.
    package static func of(name: String, command: String?, listensTCP: Bool) -> ProcessRole {
        let command = command ?? ""
        // An app's helper carries kilobytes of flags: its words are split
        // only where `mcp` occurs at all, and only the first few are read.
        if isMCP(name)
            || (mentionsMCP(command)
                && command.utf8.prefix(scanLimit).split(separator: UInt8(ascii: " ")).contains { word in
                    isMCP(String(decoding: word, as: UTF8.self))
                })
        {
            return .mcp
        }
        // Bytes, not characters: an argv's first words, past none of its rest.
        let words = command.utf8.split(separator: UInt8(ascii: " "), maxSplits: 4).prefix(4).map { String(decoding: $0, as: UTF8.self) }
        let base = words.first.map(ActivityAttribution.fileName) ?? name
        if shells.contains(name) || shells.contains(base),
            words.dropFirst().contains(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" || $0 == "-cl" })
        {
            return .shell
        }
        if listensTCP { return .server }
        if isBuild(name: name, base: base, words: words) { return .build }
        return .other
    }

    /// Whether `text` holds `needle` whatever its case: `strcasestr` over
    /// the string's own bytes, no copy of a native string.
    package static func contains(_ text: String, _ needle: String) -> Bool {
        text.withCString { haystack in needle.withCString { strcasestr(haystack, $0) != nil } }
    }

    /// A role as read for an identity, listening on TCP or not: what
    /// attribution keeps between ticks (`cached`).
    package struct Cached: Sendable {
        /// What it was read from: a role is read again when either changed
        /// (an argv read since, an `exec`).
        package let name: String
        package let command: String?
        package let quiet: ProcessRole
        package let listening: ProcessRole
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var roles: [ActivityProcessID: Cached] = [:]

    /// The roles read so far, by identity.
    package static func cached() -> [ActivityProcessID: Cached] { lock.withLock { roles } }

    /// `made` kept; the lot dropped when it grows past four times what
    /// lives (`live`) and 4,096 — ended identities go with it.
    package static func remember(_ made: [ActivityProcessID: Cached], live: Int) {
        lock.withLock {
            if roles.count + made.count > max(4 * live, 4_096) { roles = [:] }
            roles.merge(made) { _, new in new }
        }
    }

    /// Whether `text` holds `needle`, byte for byte: `strstr` over the
    /// string's own bytes.
    package static func containsBytes(_ text: String, _ needle: String) -> Bool {
        text.withCString { haystack in needle.withCString { strstr(haystack, $0) != nil } }
    }

    /// The bytes of an argv a role is read from: an MCP server says so in
    /// its first words; past them an Electron helper's kilobytes of flags.
    package static let scanLimit = 4_096

    /// Whether the first `scanLimit` bytes of `command` hold `mcp` or
    /// `modelcontextprotocol`, whatever their case: one pass, no copy.
    package static func mentionsMCP(_ command: String) -> Bool {
        func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = min(bytes.count, scanLimit)
            var index = 0
            while index + 2 < count {
                let byte = bytes[index] | 0x20
                if byte == UInt8(ascii: "m"), bytes[index + 1] | 0x20 == UInt8(ascii: "c"), bytes[index + 2] | 0x20 == UInt8(ascii: "p") { return true }
                if byte == UInt8(ascii: "m"), index + 20 <= count,
                    String(decoding: UnsafeBufferPointer(rebasing: bytes[index..<(index + 20)]), as: UTF8.self).lowercased() == "modelcontextprotocol"
                {
                    return true
                }
                index += 1
            }
            return false
        }
        return command.utf8.withContiguousStorageIfAvailable(scan) ?? Array(command.utf8.prefix(scanLimit)).withUnsafeBufferPointer(scan)
    }

    /// A word naming an MCP server: `mcp` one of its alphanumeric runs, or
    /// the protocol's own scope.
    package static func isMCP(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.contains("@modelcontextprotocol/") || lower.contains("mcp-server") { return true }
        guard lower.contains("mcp") else { return false }
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("mcp")
    }

    private static func isBuild(name: String, base: String, words: [String]) -> Bool {
        let rest = Array(words.dropFirst())
        if builders.contains(name) || builders.contains(base) { return true }
        if packageRunners.contains(base) || packageRunners.contains(name) {
            return rest.first == "test" || (rest.first == "run" && rest.dropFirst().first == "test")
        }
        if base == "swift" || name == "swift-build" { return rest.first == "build" || rest.first == "test" || name == "swift-build" }
        if base == "go" { return rest.first == "test" }
        if base.hasPrefix("python") { return rest.starts(with: ["-m", "pytest"]) }
        return false
    }
}

extension ProcessRole {
    private static let users = NSLock()
    nonisolated(unsafe) private static var userNames: [uid_t: String] = [:]

    /// A uid's login name (`getpwuid_r`), kept for the app's life; its
    /// number where it has none.
    package static func userName(_ uid: uid_t) -> String {
        if let known = users.withLock({ userNames[uid] }) { return known }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        let name: String =
            getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0 && result != nil ? String(cString: entry.pw_name) : String(uid)
        users.withLock { userNames[uid] = name }
        return name
    }
}
