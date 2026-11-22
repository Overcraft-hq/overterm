import Foundation

/// A port two holders share in a way that surprises (docs/design/activity/
/// analysis.md, 6.8, Collisions): which one a client reaches depends on how
/// it asks. Docker's `PortConflicts` reads the engine's error text, which
/// is a different job; a checkout's stack wanting a held port is the
/// Docker page's Up on Free Ports.
package struct PortCollision: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        /// One holder only on IPv4, another only on IPv6: `localhost` may
        /// reach either.
        case split
        /// A specific address beside a wildcard (`SO_REUSEADDR`): the
        /// address's clients reach one, everything else the other.
        case wildcardBesideSpecific
        /// The same address and port, two holders' own sockets
        /// (`SO_REUSEPORT`): connections go to either.
        case sharedPort
        /// AirPlay Receiver holds the port too.
        case knownHolder
    }

    package let kind: Kind
    /// What the row says, from its own side.
    package let sentence: String
}

/// Collisions between listeners, by protocol and port (6.8). Pure.
package enum PortCollisions {
    /// Each listener's collisions, by row id: on both rows, each from its
    /// own side. Rows of one holder never collide with themselves, nor a
    /// row with the socket it shares with its co-holders.
    package static func find(_ rows: [ActivityPortRow]) -> [String: [PortCollision]] {
        var found: [String: [PortCollision]] = [:]
        let groups = Dictionary(grouping: rows.filter { $0.kind == .listener }, by: { "\($0.proto):\($0.port)" })
        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count > 1 else { continue }
            for (offset, first) in group.enumerated() {
                for second in group.dropFirst(offset + 1) where differ(first, second) {
                    for (kind, one, other) in collisions(first, second) {
                        found[first.id, default: []].append(PortCollision(kind: kind, sentence: one))
                        found[second.id, default: []].append(PortCollision(kind: kind, sentence: other))
                    }
                }
            }
        }
        // The worst first: which one a client reaches is the surprise.
        let rank: [PortCollision.Kind: Int] = [.sharedPort: 0, .split: 1, .wildcardBesideSpecific: 2, .knownHolder: 3]
        return found.mapValues { collisions in
            var seen = Set<PortCollision>()
            return collisions.filter { seen.insert($0).inserted }.sorted { rank[$0.kind]! < rank[$1.kind]! }
        }
    }

    /// Two holders, not one socket.
    package static func differ(_ first: ActivityPortRow, _ second: ActivityPortRow) -> Bool {
        if let one = first.holder, let two = second.holder, one == two { return false }
        if !first.sockets.isEmpty, !first.sockets.isDisjoint(with: second.sockets) { return false }
        return true
    }

    /// What `first` and `second` on one port say of each other.
    package static func collisions(_ first: ActivityPortRow, _ second: ActivityPortRow) -> [(PortCollision.Kind, String, String)] {
        var said: [(PortCollision.Kind, String, String)] = []
        let port = first.port
        // AirPlay Receiver, on 5000 and 7000.
        for (airPlay, other) in [(first, second), (second, first)] where isAirPlay(airPlay) && !isAirPlay(other) {
            let toOther = "AirPlay Receiver holds :\(port) too — turned off in System Settings ▸ General ▸ AirDrop & Handoff"
            let toAirPlay = "\(who(other)) holds :\(port) too"
            said.append(airPlay.id == first.id ? (.knownHolder, toAirPlay, toOther) : (.knownHolder, toOther, toAirPlay))
        }
        // The same address, two holders' own sockets: SO_REUSEPORT.
        if first.proto == "tcp", !first.bound.isEmpty, Set(first.bound) == Set(second.bound) {
            let sentence = "two servers share :\(port) — connections go to either: \(who(first)) and \(who(second))"
            said.append((.sharedPort, sentence, sentence))
            return said
        }
        // One only on IPv4, the other only on IPv6.
        if let (v4, v6) = split(first, second) {
            let sentence = "localhost may reach either: \(who(v4)) on IPv4, \(who(v6)) on IPv6"
            said.append((.split, sentence, sentence))
            return said
        }
        // A specific address beside a wildcard of its family.
        for (wild, specific) in [(first, second), (second, first)] {
            guard let address = specificBeside(wild: wild, specific: specific) else { continue }
            let toSpecific =
                address.isLoopback
                ? "local clients reach this one; the LAN reaches \(who(wild))" : "\(address.description) reaches this one; other addresses reach \(who(wild))"
            let toWild =
                address.isLoopback
                ? "local clients reach \(who(specific)); the LAN reaches this one" : "\(address.description) reaches \(who(specific)); other addresses this one"
            said.append(wild.id == first.id ? (.wildcardBesideSpecific, toWild, toSpecific) : (.wildcardBesideSpecific, toSpecific, toWild))
            break
        }
        return said
    }

    /// The v4-only holder and the v6-only one, each on loopback or its
    /// family's wildcard.
    package static func split(_ first: ActivityPortRow, _ second: ActivityPortRow) -> (ActivityPortRow, ActivityPortRow)? {
        func only(_ row: ActivityPortRow, v6: Bool) -> Bool {
            guard row.families == (v6 ? .v6 : .v4), !row.bound.isEmpty else { return false }
            return row.bound.allSatisfy { address in
                guard let address else { return false }
                switch address {
                case .v4: return !v6 && (address.isLoopback || address.isWildcard)
                case .v6: return v6 && (address.isLoopback || address.isWildcard)
                }
            }
        }
        if only(first, v6: false), only(second, v6: true) { return (first, second) }
        if only(second, v6: false), only(first, v6: true) { return (second, first) }
        return nil
    }

    /// `specific`'s one address when `wild` listens on its family's
    /// wildcard and it on that address alone.
    package static func specificBeside(wild: ActivityPortRow, specific: ActivityPortRow) -> ActivityAddress? {
        guard wild.bound.contains(where: { $0?.isWildcard == true }), specific.bound.count >= 1,
            let address = specific.bound.compactMap({ $0 }).first(where: { !$0.isWildcard }),
            specific.bound.allSatisfy({ $0?.isWildcard != true })
        else { return nil }
        let v6 = { if case .v6 = address { true } else { false } }()
        // A v4 address meets a v4 wildcard, or a dual-stack `::`.
        let wildFamilies = wild.families
        guard v6 ? wildFamilies.contains(.v6) : wildFamilies.contains(.v4) else { return nil }
        return address
    }

    package static func isAirPlay(_ row: ActivityPortRow) -> Bool {
        if case .known(let holder) = row.portOwner { return holder == KnownHolders.airPlay }
        return false
    }

    /// "vite (feature-x)": the process and its checkout, else its tab.
    package static func who(_ row: ActivityPortRow) -> String {
        if isAirPlay(row) { return "AirPlay Receiver" }
        if case .container(let name, _) = row.portOwner { return "container \(name)" }
        let name = row.process
        if let checkout = row.checkout { return "\(name) (\(checkout))" }
        if let tab = row.tabTitle { return "\(name) (“\(tab)”)" }
        return name
    }
}
