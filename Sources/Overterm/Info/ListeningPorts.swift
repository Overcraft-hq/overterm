import Foundation

/// A TCP port a tab's process is listening on — typically a dev server —
/// or one a container of the tab's checkout publishes (Docker's own
/// process holds those, so lsof never finds them under the tab).
struct ListeningPort: Identifiable, Hashable {
    let pid: pid_t
    let process: String
    let port: Int
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`).
    let address: String
    /// The container publishing it; its service is `process`, `pid` is 0.
    var container: String? = nil
    /// The port the compose file asks for, when Up on Free Ports moved it
    /// here for this checkout (`ComposePorts`).
    var movedFrom: Int? = nil

    var id: String { container.map { "\($0):\(port)" } ?? "\(pid):\(port)" }

    /// Loopback or wildcard: reachable as localhost.
    var url: URL? { URL(string: "http://localhost:\(port)") }
}

enum ListeningPorts {
    static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// Whoever on this Mac listens on `port`, if anything does.
    static func holder(of port: Int) async -> ListeningPort? {
        let output =
            (try? await Git.run(
                lsof, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pcn"], in: URL(fileURLWithPath: "/"), success: [0, 1])) ?? ""
        return parse(output).first { $0.port == port }
    }

    /// Whether something on this Mac holds `port` — what Docker's own bind
    /// for a published port would run into. A bind with SO_REUSEADDR on
    /// 0.0.0.0, 127.0.0.1, :: and ::1, each closed at once: a listener on
    /// one address is only met binding that one, TIME_WAIT doesn't count,
    /// and nothing listens, so no firewall asks. Any user's socket counts,
    /// unlike lsof's. A family this Mac can't make counts as free.
    static func isBound(_ port: Int, proto: String = "tcp") -> Bool {
        guard (1...65535).contains(port) else { return false }
        let type = proto == "udp" ? SOCK_DGRAM : SOCK_STREAM
        for (family, address) in [(AF_INET, "0.0.0.0"), (AF_INET, "127.0.0.1"), (AF_INET6, "::"), (AF_INET6, "::1")] {
            let fd = socket(family, type, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var on: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
            let result: Int32
            if family == AF_INET {
                var socketAddress = sockaddr_in()
                socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                socketAddress.sin_family = sa_family_t(AF_INET)
                socketAddress.sin_port = in_port_t(UInt16(port)).bigEndian
                inet_pton(AF_INET, address, &socketAddress.sin_addr)
                result = withUnsafePointer(to: &socketAddress) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            } else {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, size)
                var socketAddress = sockaddr_in6()
                socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                socketAddress.sin6_family = sa_family_t(AF_INET6)
                socketAddress.sin6_port = in_port_t(UInt16(port)).bigEndian
                inet_pton(AF_INET6, address, &socketAddress.sin6_addr)
                result = withUnsafePointer(to: &socketAddress) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
            if result != 0, errno == EADDRINUSE { return true }
        }
        return false
    }

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
