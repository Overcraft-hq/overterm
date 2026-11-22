import Foundation

/// What the Activity page's filter field means (docs/design/activity/
/// analysis.md, 6.6): `ResourceFilter`'s words — ANDed, `key:value`, a
/// leading `-` to negate — with two more things:
///
///     mem:>500m  age:<5m       quantities with units, turned into numbers
///     name:node|python         `|` inside a value ORs, as htop 3.2's does
///
/// Text matches only masked text, never the raw argv: typing a token a
/// character at a time could otherwise confirm a secret in another
/// process's arguments. Pure.
package typealias ActivityFilter = ResourceFilter<ActivityFilterKey>

/// The filter's keys, and every name they go by.
package enum ActivityFilterKey: String, ResourceFilterKey {
    case text, pid, ppid, pgid, user, name, cmd, tab, pane, checkout, branch, agent, role, port, cpu, mem, threads, age, energy, state, flag
    // Listening's own.
    case proto, family, scope, owner

    package static let names: [String: ActivityFilterKey] = [
        "pid": .pid, "ppid": .ppid, "pgid": .pgid,
        "user": .user, "u": .user,
        "name": .name, "n": .name,
        "cmd": .cmd, "command": .cmd,
        "tab": .tab, "pane": .pane,
        "checkout": .checkout, "wt": .checkout, "worktree": .checkout, "branch": .branch,
        "agent": .agent, "role": .role, "port": .port,
        "cpu": .cpu, "mem": .mem, "memory": .mem, "threads": .threads, "age": .age, "energy": .energy,
        "state": .state, "is": .flag,
        "proto": .proto, "family": .family, "scope": .scope, "owner": .owner,
    ]
}

/// A filter value read as a number compared, with a unit (6.6): `>1g`,
/// `<5m`, `>=12.5`. Its operators are `ResourceFilterComparison`'s.
package struct ActivityQuantity: Equatable, Sendable {
    package enum Unit: Sendable {
        /// Plain: as it is.
        case plain
        /// Bytes; a bare number is MB (`mem:>500`), else k, m, g, t.
        case bytes
        /// Seconds; a bare number is seconds, else s, m, h, d.
        case seconds
    }

    package var op: ResourceFilterComparison.Operator
    package var value: Double

    package init?(_ text: String, unit: Unit) {
        let ops: [ResourceFilterComparison.Operator] = [.lessOrEqual, .greaterOrEqual, .less, .greater, .equal]
        let op = ops.first { text.hasPrefix($0.rawValue) } ?? .equal
        let rest = text.hasPrefix(op.rawValue) ? Substring(text.dropFirst(op.rawValue.count)) : Substring(text)
        let split = rest.firstIndex(where: \.isLetter) ?? rest.endIndex
        let digits = rest[..<split]
        let suffix = String(rest[split...])
        let scale: Double
        switch (unit, suffix) {
        case (.plain, ""): scale = 1
        case (.bytes, ""), (.bytes, "m"), (.bytes, "mb"): scale = 1024 * 1024
        case (.bytes, "b"): scale = 1
        case (.bytes, "k"), (.bytes, "kb"): scale = 1024
        case (.bytes, "g"), (.bytes, "gb"): scale = 1024 * 1024 * 1024
        case (.bytes, "t"), (.bytes, "tb"): scale = 1024 * 1024 * 1024 * 1024
        case (.seconds, ""), (.seconds, "s"): scale = 1
        case (.seconds, "m"), (.seconds, "min"): scale = 60
        case (.seconds, "h"): scale = 3_600
        case (.seconds, "d"): scale = 86_400
        default: return nil
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let number = Double(digits) else { return nil }
        self.op = op
        self.value = number * scale
    }

    package func holds(for value: Double) -> Bool {
        switch op {
        case .less: value < self.value
        case .lessOrEqual: value <= self.value
        case .equal: value == self.value
        case .greaterOrEqual: value >= self.value
        case .greater: value > self.value
        }
    }
}

extension ResourceFilter where Key == ActivityFilterKey {
    /// Every term holds for a process row, `now` its age's clock.
    package func matches(_ row: ActivityProcessRow, now: Date) -> Bool {
        matches(by: { term in term.alternatives.contains { term.matches(row, value: $0, now: now) } })
    }

    /// Every term holds for a listener's row.
    package func matches(_ row: ActivityPortRow) -> Bool {
        matches(by: { term in term.alternatives.contains { term.matches(row, value: $0) } })
    }
}

extension ResourceFilter where Key == ActivityFilterKey {
    /// It asks for Listening's connections: `state:established` or
    /// `is:connected`, not negated (6.8).
    package var asksConnections: Bool {
        terms.contains { term in
            !term.negated
                && ((term.key == .state && term.alternatives.contains { $0 == "established" || $0 == "connected" })
                    || (term.key == .flag && term.alternatives.contains { $0 == "connected" || $0 == "connection" }))
        }
    }
}

extension ResourceFilter.Term where Key == ActivityFilterKey {
    /// The value's `|`-separated choices, any of which may hold (htop 3.2).
    package var alternatives: [String] {
        let parts = value.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
        return parts.isEmpty ? [value] : parts
    }

    private func number(_ value: String, _ number: Double?, unit: ActivityQuantity.Unit = .plain) -> Bool {
        guard let number, let quantity = ActivityQuantity(value, unit: unit) else { return false }
        return quantity.holds(for: number)
    }

    package func matches(_ row: ActivityProcessRow, value: String, now: Date) -> Bool {
        switch key {
        case .text:
            return [row.name, row.label ?? "", row.command ?? "", row.tabTitle ?? "", row.checkout ?? "", row.branch ?? ""]
                .contains { $0.lowercased().contains(value) }
        case .pid: return number(value, Double(row.identity.pid))
        case .ppid: return number(value, Double(row.parentPID))
        case .pgid: return number(value, Double(row.group))
        case .user:
            if value == "me" || value == "mine" { return row.isOwn }
            return row.user.lowercased() == value
        case .name: return row.name.lowercased().contains(value) || row.label?.lowercased().contains(value) == true
        case .cmd: return row.command?.lowercased().contains(value) == true
        case .tab: return row.tabTitle?.lowercased().contains(value) == true
        case .pane: return number(value, row.pane.map { Double($0) })
        case .checkout: return row.checkout?.lowercased().contains(value) == true
        case .branch: return row.branch?.lowercased().contains(value) == true
        case .agent:
            guard let agent = row.owner?.agentKind else { return false }
            return value == "any" || agent.rawValue == value
        case .role:
            switch value {
            case "mcp": return row.owner?.role == .mcp
            case "shell": return row.owner?.role == .shell
            case "server": return row.owner?.role == .server || !row.listening.isEmpty
            case "build", "test": return row.owner?.role == .build
            default: return false
            }
        case .port:
            let ports = row.listening + row.boundUDP
            if let port = Int(value) { return ports.contains(port) }
            return ports.contains { number(value, Double($0)) }
        case .cpu: return number(value, row.cpu)
        case .mem: return number(value, row.memory.map { Double($0) }, unit: .bytes)
        case .threads: return number(value, row.threads.map { Double($0) })
        case .age: return number(value, max(now.timeIntervalSince(row.started), 0), unit: .seconds)
        case .energy: return number(value, row.energy)
        case .state:
            switch value {
            case "running", "r": return row.state == .running
            case "sleeping", "s": return row.state == .sleeping
            case "stopped", "t": return row.state == .stopped
            case "zombie", "z": return row.state == .zombie
            default: return false
            }
        case .flag: return flag(row, value, now: now)
        case .proto, .family, .scope, .owner: return false
        }
    }

    /// `is:` (6.6).
    private func flag(_ row: ActivityProcessRow, _ value: String, now: Date) -> Bool {
        let place = row.owner?.place
        switch value {
        case "mine", "own", "yours": return row.isOwn
        case "system": return !row.isOwn
        case "macos": return place == .macOS
        case "app": if case .app? = place { return true } else { return false }
        case "agent": return row.owner?.agentKind != nil
        case "tab": if case .pane? = place { return true } else { return false }
        case "overterm": return place == .overterm
        case "other-overterm": return place == .anotherOverterm
        case "probably": return row.owner?.certainty == .probably
        case "detached": return row.owner?.marks.contains(.detached) == true
        case "nohup": return row.ignoresHangup
        case "listening": return !row.listening.isEmpty || !row.boundUDP.isEmpty
        case "connected": return row.connected
        case "new": return now.timeIntervalSince(row.started) < 60
        case "stopped": return row.state == .stopped
        case "zombie": return row.state == .zombie
        case "rosetta": return row.translated
        // Left Behind (stage 3) and what Activity put in the background
        // (stage 2) aren't made yet: nothing is either.
        case "left", "background": return false
        default: return false
        }
    }

    package func matches(_ row: ActivityPortRow, value: String) -> Bool {
        switch key {
        case .text:
            return [":\(row.port)", String(row.port), row.process, row.tabTitle ?? "", row.address, row.reach, row.ownerText, row.whereText, row.note ?? ""]
                .contains { $0.lowercased().contains(value) }
        case .port:
            if let port = Int(value) { return row.port == port }
            return number(value, Double(row.port))
        case .pid: return number(value, row.holder.map { Double($0.pid) })
        case .name: return row.process.lowercased().contains(value)
        case .tab: return row.tabTitle?.lowercased().contains(value) == true
        case .proto: return row.proto == value
        case .family:
            switch value {
            case "4", "v4", "ipv4": return row.families.contains(.v4)
            case "6", "v6", "ipv6": return row.families.contains(.v6)
            default: return false
            }
        case .scope: return scope(row, value)
        case .flag:
            switch value {
            case "lan", "local": return scope(row, value)
            case "listening": return row.kind == .listener
            case "connected", "connection": return row.kind == .connection
            case "collision", "collides": return !row.collisions.isEmpty
            case "forwarded": return row.forwardedBy != nil
            default: return false
            }
        case .state:
            // Listeners and bound UDP, or the user's connections (6.8).
            switch value {
            case "listen", "listening": return row.kind == .listener
            case "established", "connected": return row.kind == .connection
            default: return false
            }
        case .owner: return row.owner == value
        default: return false
        }
    }

    /// `scope:lan` reaches past this Mac; `scope:local` loopback only.
    private func scope(_ row: ActivityPortRow, _ value: String) -> Bool {
        switch value {
        case "lan", "network": return row.scope != .thisMac
        case "local", "mac", "thismac": return row.scope == .thisMac
        default: return false
        }
    }
}
