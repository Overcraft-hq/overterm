import Foundation

/// A key and its type, as the browser lists it.
package struct RedisKeyEntry: Hashable, Sendable {
    package var name: String
    package var type: String

    package init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// Keys as folders, Redis Insight's way: `user:1:profile` sits in `user`,
/// then `1` — split on a delimiter (`:` unless the connection says
/// otherwise). Pure, so it is tested without a server.
package struct RedisKeyTree: Equatable {
    package struct Folder: Equatable {
        /// Its own segment: `1`.
        package var name: String
        /// Everything up to it, delimiter included: `user:1:` — a pattern's start.
        package var prefix: String
        package var folders: [Folder]
        package var keys: [RedisKeyEntry]
        /// Keys anywhere under it.
        package var count: Int

        package init(name: String, prefix: String, folders: [Folder], keys: [RedisKeyEntry], count: Int) {
            self.name = name
            self.prefix = prefix
            self.folders = folders
            self.keys = keys
            self.count = count
        }
    }

    package var root: Folder

    package init(_ keys: [RedisKeyEntry], delimiter: String = ":") {
        root = Self.folder(name: "", prefix: "", keys: keys.map { ($0, $0.name) }, delimiter: delimiter)
    }

    private static func folder(name: String, prefix: String, keys: [(entry: RedisKeyEntry, rest: String)], delimiter: String) -> Folder {
        var leaves: [RedisKeyEntry] = []
        var groups: [String: [(RedisKeyEntry, String)]] = [:]
        var order: [String] = []
        for (entry, rest) in keys {
            // A key that ends at the delimiter, or has nothing before it, is a leaf.
            if !delimiter.isEmpty, let range = rest.range(of: delimiter), range.lowerBound != rest.startIndex, range.upperBound != rest.endIndex {
                let head = String(rest[..<range.lowerBound])
                if groups[head] == nil { order.append(head) }
                groups[head, default: []].append((entry, String(rest[range.upperBound...])))
            } else {
                leaves.append(entry)
            }
        }
        // A folder of one key is only that key: no click to reach it.
        var folders: [Folder] = []
        for head in order {
            let members = groups[head] ?? []
            if members.count == 1 {
                leaves.append(members[0].0)
            } else {
                folders.append(folder(name: head, prefix: prefix + head + delimiter, keys: members, delimiter: delimiter))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        leaves.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Folder(name: name, prefix: prefix, folders: folders, keys: leaves, count: keys.count)
    }
}

/// What a key's type is called, and its colour's name, as Insight badges them.
package enum RedisKeyType {
    package static func label(_ type: String) -> String {
        switch type {
        case "string": "STRING"
        case "hash": "HASH"
        case "list": "LIST"
        case "set": "SET"
        case "zset": "ZSET"
        case "stream": "STREAM"
        case "ReJSON-RL": "JSON"
        case "TSDB-TYPE": "TS"
        case "MBbloom--": "BLOOM"
        default: type.uppercased()
        }
    }

    /// The types a new key can be.
    package static let creatable = ["string", "hash", "list", "set", "zset", "stream", "ReJSON-RL"]
}

/// INFO, read: its fields, and what the server's page says from them.
package struct RedisInfo: Equatable {
    package var fields: [String: String] = [:]

    package init(_ text: String) {
        for row in RedisResult.info(text) {
            if let key = row[0], let value = row[1] { fields[key] = value }
        }
    }

    package init() {}

    package subscript(_ key: String) -> String? { fields[key] }
    package func number(_ key: String) -> Double? { fields[key].flatMap(Double.init) }

    package var version: String? { self["redis_version"] ?? self["valkey_version"] }
    package var keyspace: [(db: Int, keys: Int, expires: Int)] {
        fields.compactMap { key, value in
            guard key.hasPrefix("db"), let db = Int(key.dropFirst(2)) else { return nil }
            func field(_ name: String) -> Int {
                value.split(separator: ",").first { $0.hasPrefix(name + "=") }.flatMap { Int($0.dropFirst(name.count + 1)) } ?? 0
            }
            return (db, field("keys"), field("expires"))
        }
        .sorted { $0.db < $1.db }
    }

    package var totalKeys: Int { keyspace.reduce(0) { $0 + $1.keys } }

    /// Hits over lookups, nil before there was one.
    package var hitRatio: Double? {
        guard let hits = number("keyspace_hits"), let misses = number("keyspace_misses"), hits + misses > 0 else { return nil }
        return hits / (hits + misses)
    }

    package var uptime: String? { number("uptime_in_seconds").map { RedisKeyInfo.duration(Int($0)) } }
}

/// SLOWLOG GET's entries.
package struct RedisSlowEntry: Equatable, Identifiable {
    package var id: Int
    package var date: Date
    package var micros: Int
    package var command: String
    package var client: String

    package static func parse(_ value: RedisValue) -> [RedisSlowEntry] {
        guard case .array(let items?) = value else { return [] }
        return items.compactMap { item in
            guard case .array(let parts?) = item, parts.count >= 4, case .integer(let id) = parts[0], case .integer(let time) = parts[1],
                case .integer(let micros) = parts[2], case .array(let args?) = parts[3]
            else { return nil }
            let command = args.map { RedisProtocol.quoted($0.text ?? "") }.joined(separator: " ")
            return RedisSlowEntry(
                id: id, date: Date(timeIntervalSince1970: TimeInterval(time)), micros: micros, command: command,
                client: parts.count > 4 ? parts[4].text ?? "" : "")
        }
    }
}

/// CLIENT LIST's lines: `id=3 addr=… name=… db=0 cmd=client|list …`.
package enum RedisClients {
    package static func parse(_ text: String) -> [[String: String]] {
        text.split(whereSeparator: \.isNewline).map { line in
            var fields: [String: String] = [:]
            for pair in line.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }
            return fields
        }
    }
}

/// A connection URL pasted into the form: `redis://user:pass@host:6380/2`,
/// `rediss://` for TLS.
package struct RedisURL: Equatable {
    package var host: String
    package var port: Int?
    package var user: String
    package var password: String?
    package var database: String
    package var tls: Bool

    package init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            scheme == "redis" || scheme == "rediss" || scheme == "valkey" || scheme == "valkeys"
        else { return nil }
        tls = scheme == "rediss" || scheme == "valkeys"
        host = components.host ?? ""
        port = components.port
        // `redis://:secret@host` is a password with no user.
        user = components.user?.removingPercentEncoding ?? ""
        password = components.password?.removingPercentEncoding
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        database = Int(path).map(String.init) ?? ""
    }
}
