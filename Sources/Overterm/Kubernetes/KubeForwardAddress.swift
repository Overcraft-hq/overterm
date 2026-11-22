import Darwin
import Foundation

/// The listen address: an IP literal or `localhost`. Pure.
package enum KubeForwardAddress {
    package static let loopback = "127.0.0.1"

    /// Why `text` can't be one; nil when it can.
    package static func problem(_ text: String) -> String? {
        let address = text.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "Give an address to listen on (127.0.0.1)." }
        if address == "localhost" { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 { return nil }
        return "\(address) isn't an IP address (127.0.0.1, 0.0.0.0, ::1)."
    }

    /// Whether only this Mac can reach it.
    package static func isLoopback(_ address: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(address) || address.hasPrefix("127.")
    }

    /// Who can reach a forward listening on `address` (docs/design/
    /// activity/analysis.md, 6.8's Scope): a wildcard the network, loopback
    /// this Mac, any other address that one.
    package static func scope(_ address: String) -> ListeningPort.Scope {
        if ["0.0.0.0", "::", "*"].contains(address) { return .network }
        return isLoopback(address) ? .thisMac : .oneAddress
    }

    /// Where a browser reaches it: the address kubectl listens on, never
    /// `localhost` — which a browser may try as ::1 first, where a forward
    /// on 127.0.0.1 doesn't listen. A wildcard is reached on loopback; an
    /// IPv6 address in brackets.
    package static func host(for address: String) -> String {
        switch address {
        case "localhost", "0.0.0.0": return loopback
        case "::", "::1": return "[::1]"
        default: return address.contains(":") ? "[\(address)]" : address
        }
    }
}
