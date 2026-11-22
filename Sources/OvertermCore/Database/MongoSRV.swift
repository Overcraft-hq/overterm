import Foundation
import dnssd

/// `mongodb+srv://`'s lookup: `_mongodb._tcp.<name>`'s SRV records are the
/// hosts, its TXT record the options it may set (authSource, replicaSet) —
/// asked of the system's resolver through dnssd, no shelling out. Read
/// again at every connect: a cluster's members change.
package enum MongoSRV {
    package struct Found: Equatable {
        package var hosts: [(host: String, port: Int)]
        package var options: [String: String]

        package static func == (a: Found, b: Found) -> Bool {
            a.options == b.options && a.hosts.map { "\($0.host):\($0.port)" } == b.hosts.map { "\($0.host):\($0.port)" }
        }
    }

    package struct Failure: LocalizedError {
        package let message: String

        package init(message: String) {
            self.message = message
        }
        package var errorDescription: String? { message }
    }

    package static func resolve(_ name: String) async throws -> Found {
        let name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard name.split(separator: ".").count >= 3 else {
            throw Failure(message: "An srv name has at least three parts — cluster0.example.mongodb.net; “\(name)” hasn't.")
        }
        let srv = try await query("_mongodb._tcp." + name, type: UInt16(kDNSServiceType_SRV))
        guard !srv.records.isEmpty else {
            throw Failure(message: "No SRV record for _mongodb._tcp.\(name)\(srv.error.map { " (\($0))" } ?? "") — is the name right?")
        }
        let txt = try await query(name, type: UInt16(kDNSServiceType_TXT))
        var options: [String: String] = [:]
        for record in txt.records {
            for string in strings(record) {
                for pair in string.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    // Only these may come from DNS.
                    if ["authsource", "replicaset", "loadbalanced"].contains(parts[0].lowercased()) { options[parts[0].lowercased()] = parts[1] }
                }
            }
        }
        let hosts = try srv.records.compactMap(target).map { found -> (host: String, port: Int) in
            guard sharesDomain(found.host, with: name) else {
                throw Failure(message: "\(name)'s SRV record names \(found.host), outside its own domain — refused, as every driver refuses it.")
            }
            return found
        }
        return Found(hosts: hosts.sorted { $0.host < $1.host }, options: options)
    }

    /// A host the record names must be in the srv name's parent domain.
    package static func sharesDomain(_ host: String, with name: String) -> Bool {
        let parent = name.split(separator: ".").dropFirst().joined(separator: ".").lowercased()
        return host.lowercased().hasSuffix("." + parent)
    }

    /// SRV's rdata: priority, weight, port, then the target as DNS labels.
    package static func target(_ rdata: Data) -> (host: String, port: Int)? {
        let bytes = [UInt8](rdata)
        guard bytes.count > 7 else { return nil }
        let port = Int(bytes[4]) << 8 | Int(bytes[5])
        var labels: [String] = []
        var at = 6
        while at < bytes.count {
            let length = Int(bytes[at])
            if length == 0 { break }
            guard length < 64, at + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(at + 1)..<(at + 1 + length)], as: UTF8.self))
            at += 1 + length
        }
        guard !labels.isEmpty else { return nil }
        return (labels.joined(separator: "."), port)
    }

    /// TXT's rdata: strings, each its length first.
    package static func strings(_ rdata: Data) -> [String] {
        let bytes = [UInt8](rdata)
        var out: [String] = []
        var at = 0
        while at < bytes.count {
            let length = Int(bytes[at])
            guard at + 1 + length <= bytes.count else { break }
            out.append(String(decoding: bytes[(at + 1)..<(at + 1 + length)], as: UTF8.self))
            at += 1 + length
        }
        return out
    }

    // MARK: dnssd

    private final class Answers: @unchecked Sendable {
        var records: [Data] = []
        var error: String?
        var more = false
    }

    /// One query's records, waited for on a thread of its own: dnssd
    /// answers on the socket it gives, read here until it has said all
    /// it has at once, or five seconds pass.
    nonisolated private static func query(_ name: String, type: UInt16) async throws -> (records: [Data], error: String?) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(records: [Data], error: String?), Error>) in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let answers = Answers()
                let reply: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
                    guard let context else { return }
                    let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
                    answers.more = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
                    guard error == kDNSServiceErr_NoError else {
                        answers.error = error == kDNSServiceErr_NoSuchRecord || error == kDNSServiceErr_NoSuchName ? "no such record" : "dnssd error \(error)"
                        return
                    }
                    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, length > 0 {
                        answers.records.append(Data(bytes: data, count: Int(length)))
                    }
                }
                var ref: DNSServiceRef?
                let context = Unmanaged.passRetained(answers).toOpaque()
                defer { Unmanaged<Answers>.fromOpaque(context).release() }
                let started = DNSServiceQueryRecord(
                    &ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name, type, UInt16(kDNSServiceClass_IN), reply, context)
                guard started == kDNSServiceErr_NoError, let ref else {
                    continuation.resume(throwing: Failure(message: "Couldn't ask DNS for \(name) (dnssd error \(started))."))
                    return
                }
                defer { DNSServiceRefDeallocate(ref) }
                let socket = DNSServiceRefSockFD(ref)
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&poller, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
                    if ready <= 0 { break }
                    guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { break }
                    if (answers.error != nil || !answers.records.isEmpty), !answers.more { break }
                }
                if answers.records.isEmpty, answers.error == nil, Date() >= deadline {
                    continuation.resume(returning: ([], "no answer in 5 s"))
                    return
                }
                continuation.resume(returning: (answers.records, answers.error))
            }
        }
    }
}
