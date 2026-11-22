import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

/// Collisions on Listening (docs/design/activity/analysis.md, 6.8): one
/// port split across IPv4 and IPv6 by two holders, a specific address
/// beside a wildcard, two holders' own sockets on one address and port
/// (`SO_REUSEPORT`), AirPlay Receiver beside a server — each said on both
/// rows from its own side; never one holder with itself, nor processes
/// sharing one socket. Every name is invented.
final class PortCollisionsTests: XCTestCase {
    private func address(_ text: String) -> ActivityAddress? {
        if text.contains(":") {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
            return ActivityAddress(v6: raw)
        }
        var raw = in_addr()
        guard inet_pton(AF_INET, text, &raw) == 1 else { return nil }
        return ActivityAddress(v4: raw)
    }

    private func row(
        _ pid: pid_t, _ name: String, port: Int = 3000, proto: String = "tcp", bound: [String], families: SocketRecord.Families, socket: UInt64,
        checkout: String? = nil
    ) -> ActivityPortRow {
        var row = ActivityPortRow(
            id: "\(pid):\(proto):\(port)", port: port, proto: proto, address: bound.first ?? "*", families: families, scope: .thisMac, process: name,
            holder: ActivityProcessID(pid: pid, start: UInt64(pid) * 1_000))
        row.bound = bound.map(address)
        row.sockets = [socket]
        row.checkout = checkout
        return row
    }

    func testAPortSplitAcrossIPv4AndIPv6() {
        let v4 = row(10, "vite", bound: ["127.0.0.1"], families: .v4, socket: 1, checkout: "feature-x")
        let v6 = row(11, "vite", bound: ["::1"], families: .v6, socket: 2, checkout: "main")
        let found = PortCollisions.find([v4, v6])
        XCTAssertEqual(found[v4.id]?.map(\.kind), [.split])
        XCTAssertEqual(found[v6.id]?.first?.sentence, "localhost may reach either: vite (feature-x) on IPv4, vite (main) on IPv6")
        XCTAssertEqual(found[v4.id]?.first?.sentence, found[v6.id]?.first?.sentence, "said on both rows")
    }

    func testASpecificAddressBesideAWildcard() {
        let wild = row(20, "acme-lan", bound: ["0.0.0.0"], families: .v4, socket: 3, checkout: "main")
        let local = row(21, "acme-dev", bound: ["127.0.0.1"], families: .v4, socket: 4, checkout: "feature-x")
        let found = PortCollisions.find([wild, local])
        XCTAssertEqual(found[local.id]?.first?.kind, .wildcardBesideSpecific)
        XCTAssertEqual(found[local.id]?.first?.sentence, "local clients reach this one; the LAN reaches acme-lan (main)")
        XCTAssertEqual(found[wild.id]?.first?.sentence, "local clients reach acme-dev (feature-x); the LAN reaches this one")
        // A dual-stack `::` is IPv4's wildcard too; a v6-only one isn't.
        let dual = row(22, "acme-dual", bound: ["::"], families: [.v4, .v6], socket: 5)
        XCTAssertEqual(PortCollisions.find([dual, local])[local.id]?.first?.kind, .wildcardBesideSpecific)
        let v6Only = row(23, "acme-v6", bound: ["::"], families: .v6, socket: 6)
        XCTAssertNil(PortCollisions.find([v6Only, row(24, "acme-lan2", bound: ["192.0.2.4"], families: .v4, socket: 7)])["24:tcp:3000"])
    }

    func testTwoHoldersOwnSocketsOnOneAddressShareIt() {
        let one = row(30, "acme-api", bound: ["127.0.0.1"], families: .v4, socket: 8, checkout: "feature-x")
        let two = row(31, "acme-api", bound: ["127.0.0.1"], families: .v4, socket: 9, checkout: "main")
        let found = PortCollisions.find([one, two])
        XCTAssertEqual(found[one.id]?.map(\.kind), [.sharedPort])
        XCTAssertEqual(found[two.id]?.first?.sentence, "two servers share :3000 — connections go to either: acme-api (feature-x) and acme-api (main)")
    }

    func testAirPlayReceiverBesideAServer() {
        var airPlay = row(40, "ControlCenter", port: 5000, bound: ["0.0.0.0"], families: .v4, socket: 10)
        airPlay.portOwner = .known(KnownHolders.airPlay)
        let server = row(41, "acme-flask", port: 5000, bound: ["127.0.0.1"], families: .v4, socket: 11, checkout: "feature-x")
        let found = PortCollisions.find([airPlay, server])
        let kinds = found[server.id]?.map(\.kind) ?? []
        XCTAssertTrue(kinds.contains(.knownHolder) && kinds.contains(.wildcardBesideSpecific))
        XCTAssertEqual(found[server.id]?.first { $0.kind == .wildcardBesideSpecific }?.sentence, "local clients reach this one; the LAN reaches AirPlay Receiver")
        XCTAssertTrue(found[server.id]?.contains { $0.sentence.contains("AirDrop & Handoff") } == true, "where to turn it off")
        XCTAssertEqual(found[airPlay.id]?.first { $0.kind == .knownHolder }?.sentence, "acme-flask (feature-x) holds :5000 too")
    }

    func testNoCollisionForOneHolderOneSocketOrAnotherPort() {
        let parent = row(50, "acme-master", bound: ["0.0.0.0"], families: .v4, socket: 12)
        var worker = row(51, "acme-worker", bound: ["0.0.0.0"], families: .v4, socket: 12)
        XCTAssertTrue(PortCollisions.find([parent, worker]).isEmpty, "one socket, inherited: not two servers")
        worker = row(50, "acme-master", proto: "udp", bound: ["0.0.0.0"], families: .v4, socket: 13)
        XCTAssertTrue(PortCollisions.find([parent, worker]).isEmpty, "another protocol")
        let other = row(52, "acme-other", port: 3001, bound: ["0.0.0.0"], families: .v4, socket: 14)
        XCTAssertTrue(PortCollisions.find([parent, other]).isEmpty, "another port")
        var connection = row(53, "acme-client", bound: ["127.0.0.1"], families: .v4, socket: 15)
        connection.kind = .connection
        XCTAssertTrue(PortCollisions.find([parent, connection]).isEmpty, "a connection is no listener")
    }

    func testACollisionIsOnTheBuiltRowsNote() throws {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, _ name: String, _ socket: socket_fdinfo) {
            var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: 1, name: name))
            process.name = name
            process.path = "/opt/acme/bin/\(name)"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 1)
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", [name])
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: socket]
            kernel.add(process)
        }
        var launchd = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1_000, parent: 0, uid: 0, name: "launchd"))
        launchd.name = "launchd"
        kernel.add(launchd)
        add(60, "acme-v4", FakeActivityKernel.tcp(local: "127.0.0.1", port: 4000, handle: 20))
        add(61, "acme-v6", FakeActivityKernel.tcp(local: "::1", port: 4000, handle: 21))
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext(appPID: 2)))
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options())
        let rows = content.ports.filter { $0.port == 4000 }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.collisions == [.split] && $0.note?.hasPrefix("localhost may reach either") == true })
        XCTAssertTrue(rows.allSatisfy { $0.accessibilityLabel.contains("localhost may reach either") }, "VoiceOver says it too")
        XCTAssertEqual(ActivityRows.content(of: snapshot, ActivityRows.Options(portFilter: "is:collision")).ports.count, 2)
    }
}
