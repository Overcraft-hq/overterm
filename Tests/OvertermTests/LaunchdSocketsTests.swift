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
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// launchd's socket jobs (docs/design/activity/analysis.md, 6.8 rule 9):
/// fixture plists in folders the test hands over — as `AppEnvironment`
/// hands its own, none in a test run —, service names through a services
/// file of the fixture's, every name invented.
final class LaunchdSocketsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/launchd-sockets")

    private func services() throws -> [String: [String: Int]] {
        LaunchdSockets.services(try String(contentsOf: Self.fixtures.appendingPathComponent("services"), encoding: .utf8))
    }

    private func folders() -> [LaunchdSockets.Folder] {
        [
            LaunchdSockets.Folder(url: Self.fixtures.appendingPathComponent("system"), domain: .system),
            LaunchdSockets.Folder(url: Self.fixtures.appendingPathComponent("user"), domain: .user),
        ]
    }

    func testServiceNamesThroughTheServicesFile() throws {
        let services = try services()
        XCTAssertEqual(services["fake-ssh"]?["tcp"], 2222)
        XCTAssertEqual(services["fake-shell"]?["tcp"], 2222, "an alias too")
        XCTAssertEqual(services["fake-sync"]?["udp"], 4111)
        XCTAssertNil(services["#"], "comments are no names")
        XCTAssertTrue(LaunchdSockets.services("broken 99999/tcp\nworse x/udp\nalone\n").isEmpty)
    }

    func testTheFixturesJobs() throws {
        let jobs = LaunchdSockets.jobs(in: folders(), services: try services())
        XCTAssertEqual(
            Set(jobs),
            [
                LaunchdSockets.Job(label: "com.acme.fake-proxy", port: 8021, proto: "tcp", domain: .system),
                LaunchdSockets.Job(label: "com.apple.fake-login", port: 2222, proto: "tcp", domain: .system),
                LaunchdSockets.Job(label: "com.apple.fake-login", port: 4111, proto: "udp", domain: .system),
                LaunchdSockets.Job(label: "com.globex.dev", port: 8080, proto: "tcp", domain: .user),
            ], "a number or a name, a dict or an array of them, dgram as UDP; a unix socket's, no Sockets, a broken plist left out")
        let proxy = try XCTUnwrap(LaunchdSockets.job(port: 8021, proto: "tcp", in: jobs))
        XCTAssertFalse(proxy.isApple)
        XCTAssertTrue(proxy.sentence.contains("sudo launchctl bootout system/com.acme.fake-proxy"), proxy.sentence)
        let login = try XCTUnwrap(LaunchdSockets.job(port: 2222, proto: "tcp", in: jobs))
        XCTAssertTrue(login.isApple)
        XCTAssertTrue(login.sentence.hasPrefix("launchd holds :2222 for com.apple.fake-login, part of macOS"), login.sentence)
        XCTAssertNil(LaunchdSockets.job(port: 2222, proto: "udp", in: jobs), "by protocol too")
        let mine = try XCTUnwrap(LaunchdSockets.job(port: 8080, proto: "tcp", in: jobs))
        XCTAssertEqual(mine.domain, .user)
        XCTAssertTrue(mine.sentence.contains("launchctl bootout gui/"), mine.sentence)
    }

    /// The user's own plist is anyone's to write, and may be stale: it
    /// names a socket only when no other job does; when both do, neither
    /// is stopped, and both are named.
    func testTheUsersJobNamesASocketOnlyAlone() throws {
        let system = LaunchdSockets.Job(label: "com.acme.system", port: 9000, proto: "tcp", domain: .system)
        let mine = LaunchdSockets.Job(label: "com.acme.mine", port: 9000, proto: "tcp", domain: .user)
        let shared = try XCTUnwrap(LaunchdSockets.job(port: 9000, proto: "tcp", in: [mine, system]))
        XCTAssertEqual(shared.label, "com.acme.system")
        XCTAssertEqual(shared.sharedWith, "com.acme.mine")
        XCTAssertEqual(shared.sentence, "launchd holds :9000 for com.acme.system or your job com.acme.mine — both name it, so neither is stopped from here")
        XCTAssertEqual(LaunchdSockets.job(port: 9000, proto: "tcp", in: [mine]), mine, "alone, the user's own")
    }

    /// `/Library/LaunchAgents`' jobs load into each user's gui domain: the
    /// route says so, never the system domain.
    func testAGlobalAgentIsStoppedInTheGuiDomain() {
        XCTAssertEqual(LaunchdSockets.defaultFolders(home: URL(fileURLWithPath: "/tmp/fake-home")).map(\.domain), [.system, .system, .agents, .user])
        let agent = LaunchdSockets.Job(label: "com.globex.sync", port: 7100, proto: "tcp", domain: .agents)
        XCTAssertTrue(agent.sentence.contains("`launchctl bootout gui/\(getuid())/com.globex.sync`"), agent.sentence)
        XCTAssertFalse(agent.sentence.contains("sudo"), agent.sentence)
        XCTAssertFalse(agent.sentence.contains("system/"), agent.sentence)
    }

    /// A label from a plist anyone may write never goes into a command a
    /// person would paste: `$(…)`, a newline, a bidi control.
    func testAnUnusualLabelGetsNoCommand() {
        for label in ["com.evil.$(rm -rf ~)", "com.evil.x\nrm -rf ~", "com.evil.\u{202E}gnp", "com.evil x; true"] {
            for domain in [LaunchdSockets.Domain.user, .system, .agents] {
                let sentence = LaunchdSockets.Job(label: label, port: 7000, proto: "tcp", domain: domain).sentence
                XCTAssertFalse(sentence.contains("launchctl"), sentence)
                XCTAssertTrue(sentence.contains("stop it where its plist is defined"), sentence)
                XCTAssertFalse(sentence.contains("\n") || sentence.contains("\u{202E}"), sentence)
            }
        }
    }

    func testATestRunReadsNoneButItsOwn() {
        XCTAssertTrue(AppEnvironment.launchdSocketFolders.isEmpty, "a unit test reads no launchd folder of this Mac's")
        LaunchdSockets.standIn = folders()
        defer { LaunchdSockets.standIn = nil }
        XCTAssertEqual(AppEnvironment.launchdSocketFolders, folders())
        XCTAssertEqual(LaunchdSockets.cachedJobs(in: []), [])
    }
}
