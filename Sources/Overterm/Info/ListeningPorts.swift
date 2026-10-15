import Foundation

/// A TCP port a tab's process is listening on — typically a dev server.
struct ListeningPort: Identifiable, Hashable {
    let pid: pid_t
    let process: String
    let port: Int
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`).
    let address: String

    var id: String { "\(pid):\(port)" }

    /// Loopback or wildcard: reachable as localhost.
    var url: URL? { URL(string: "http://localhost:\(port)") }
}

enum ListeningPorts {
    static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// The listening TCP sockets of `pids`.
    static func of(_ pids: [pid_t]) async -> [ListeningPort] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // -a: AND the filters (these pids AND listening TCP); -n/-P: no DNS or
        // service names; -F: machine-readable fields. Exit 1 = none found.
        let output =
            (try? await Git.run(
                lsof, ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", list, "-F", "pcn"],
                in: URL(fileURLWithPath: "/"), success: [0, 1])) ?? ""
        return parse(output)
    }

    /// Parses `lsof -F pcn`: `p<pid>` and `c<command>` start a process, each
    /// `n<address:port>` is one of its sockets. IPv4 and IPv6 bindings of the
    /// same port collapse into one entry.
    static func parse(_ output: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid: pid_t = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = pid_t(value) ?? 0
            case "c":
                command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let key = "\(pid):\(port)"
                guard seen.insert(key).inserted else { continue }
                result.append(ListeningPort(pid: pid, process: command, port: port, address: String(value[..<colon])))
            default:
                continue
            }
        }
        return result.sorted { $0.port < $1.port }
    }
}
