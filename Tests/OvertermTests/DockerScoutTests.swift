import Foundation
import XCTest

@testable import Overterm

/// Docker Scout's SARIF, read: Scout 1.17's shape (Fixtures/scout-cves.sarif.json,
/// written after real reports), 0.6's, and what isn't a report at all; its
/// failures said plainly; its progress line.
final class DockerScoutTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/scout-cves.sarif.json")

    private func report() throws -> DockerScoutReport {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        return try XCTUnwrap(DockerScoutReport.parse(text))
    }

    private func finding(_ report: DockerScoutReport, _ id: String, _ name: String? = nil) -> DockerScoutFinding? {
        report.findings.first { $0.vulnerability == id && (name == nil || $0.package.name == name) }
    }

    func testAReportIsReadFromScoutsSARIF() throws {
        let report = try report()
        XCTAssertEqual(report.findings.count, 7, "the same CVE in the same package once")
        XCTAssertEqual(report.count(.critical), 2)
        XCTAssertEqual(report.count(.high), 0)
        XCTAssertEqual(report.count(.medium), 1)
        XCTAssertEqual(report.count(.low), 3)
        XCTAssertEqual(report.count(.unspecified), 1)
        XCTAssertEqual(report.scoutVersion, "1.17.1")
        XCTAssertEqual(report.packages, 7)
        let curl = try XCTUnwrap(finding(report, "CVE-2021-22945"))
        XCTAssertEqual(curl.package.displayName, "curl")
        XCTAssertEqual(curl.package.type, "deb")
        XCTAssertEqual(curl.package.version, "7.74.0-1.3+deb11u1")
        XCTAssertEqual(curl.fixedIn, "7.74.0-1.3+deb11u2")
        XCTAssertEqual(curl.affected, "<7.74.0-1.3+deb11u2")
        XCTAssertEqual(curl.score, 9.1)
        XCTAssertEqual(curl.severity, .critical)
        XCTAssertEqual(curl.advisory?.host, "scout.docker.com")
        XCTAssertEqual(curl.epss, 0.0047)
        let summary = try XCTUnwrap(curl.summary)
        XCTAssertTrue(summary.hasPrefix("When curl >= 7.7.0"), summary)
        XCTAssertFalse(summary.contains("---") || summary.contains("|"), summary)
        XCTAssertLessThanOrEqual(summary.count, 400)
        XCTAssertFalse(summary.contains("\n"))
        let rejected = try XCTUnwrap(finding(report, "CVE-2023-5129")?.summary)
        XCTAssertFalse(rejected.contains("REJECTED"), rejected)
    }

    /// One rule covers every package a CVE is in, its properties only the
    /// first's: each result's message says what holds for its package.
    func testEachPackageOfARuleIsItsOwnFinding() throws {
        let report = try report()
        let nghttp2 = try XCTUnwrap(finding(report, "CVE-2023-44487", "nghttp2"))
        let nginx = try XCTUnwrap(finding(report, "CVE-2023-44487", "nginx"))
        XCTAssertTrue(nghttp2.fixable)
        XCTAssertEqual(nghttp2.fixedIn, "1.43.0-1+deb11u1")
        XCTAssertNil(nginx.fixedIn, "the rule's fix is nghttp2's")
        XCTAssertEqual(nginx.affected, ">=1.18.0-6.1+deb11u3")
        XCTAssertEqual(nginx.package.version, "1.21.6-1~bullseye")
        XCTAssertNotEqual(nghttp2.id, nginx.id)
    }

    func testPackageURLs() throws {
        let shadow = try XCTUnwrap(DockerScoutPackage(purl: "pkg:deb/debian/shadow@1%3A4.8.1-1?os_distro=bullseye&os_name=debian&os_version=11"))
        XCTAssertEqual(shadow.version, "1:4.8.1-1")
        XCTAssertEqual(shadow.namespace, "debian")
        XCTAssertEqual(shadow.displayName, "shadow")
        let babel = try XCTUnwrap(DockerScoutPackage(purl: "pkg:npm/%40babel/traverse@7.22.5"))
        XCTAssertEqual(babel.displayName, "@babel/traverse")
        XCTAssertEqual(babel.version, "7.22.5")
        XCTAssertEqual(babel.type, "npm")
        let net = try XCTUnwrap(DockerScoutPackage(purl: "pkg:golang/golang.org/x/net@v0.17.0"))
        XCTAssertEqual(net.displayName, "golang.org/x/net")
        XCTAssertEqual(net.version, "v0.17.0")
        let netty = try XCTUnwrap(DockerScoutPackage(purl: "pkg:maven/io.netty/netty-codec-http2@4.1.100.Final"))
        XCTAssertEqual(netty.displayName, "io.netty:netty-codec-http2")
        let qualified = try XCTUnwrap(DockerScoutPackage(purl: "pkg:pypi/django@1.11.1?repository_url=https://x.example/simple#src/django"))
        XCTAssertEqual(qualified.name, "django")
        XCTAssertEqual(qualified.version, "1.11.1")
        XCTAssertNil(qualified.namespace)
        let scoped = try XCTUnwrap(DockerScoutPackage(purl: "pkg:npm/@babel/core"))
        XCTAssertEqual(scoped.displayName, "@babel/core", "an unencoded scope isn't a version")
        XCTAssertNil(scoped.version)
        XCTAssertNil(DockerScoutPackage(purl: "not-a-purl"))
        XCTAssertNil(DockerScoutPackage(purl: "pkg:"))
        let old = try XCTUnwrap(DockerScoutPackage.from(message: "net 0.3.1-0.2022"))
        XCTAssertEqual(old.name, "net")
        XCTAssertEqual(old.version, "0.3.1-0.2022")
        XCTAssertEqual(DockerScoutPackage.from(message: "pkg:apk/alpine/busybox@1.36.1-r2")?.displayName, "busybox")
        XCTAssertEqual(DockerScoutPackage(name: "x", version: "1").reference, "x@1")
    }

    /// Scout 0.6: no purls, no score, the package as `name version`.
    func testOlderScout() throws {
        let sarif = #"""
            {"version":"2.1.0","runs":[{"tool":{"driver":{"fullName":"Docker Scout","name":"docker scout","version":"v0.6.0","rules":[
              {"id":"GMS-2023-418","name":"GolangPackageVulnerability","shortDescription":{"text":"Improper rendering of text nodes in golang.org/x/net/html"},
               "helpUri":"https://dso.docker.com/cve/GMS-2023-418","help":{"text":"Improper rendering of text nodes in golang.org/x/net/html\n  Package : net\n  Affected range : <0.7.0\n"},
               "properties":{"affected_version":"<0.7.0","cvssV3_severity":"UNSPECIFIED","fixed_version":"0.7.0","tags":["UNSPECIFIED"]}}]}},
              "results":[{"ruleId":"GMS-2023-418","ruleIndex":0,"kind":"fail","level":"none",
               "message":{"text":"  Vulnerability   : GMS-2023-418\n  Severity        : UNSPECIFIED\n  Package         : net 0.3.1-0.20221206200815-1e63c2f08a10\n  Affected range  : <0.7.0\n  Fixed version   : 0.7.0\n"}}]}]}
            """#
        let report = try XCTUnwrap(DockerScoutReport.parse(sarif))
        XCTAssertEqual(report.findings.count, 1)
        let net = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(net.package.name, "net")
        XCTAssertEqual(net.package.version, "0.3.1-0.20221206200815-1e63c2f08a10")
        XCTAssertNil(net.package.purl)
        XCTAssertNil(net.score)
        XCTAssertEqual(net.severity, .unspecified)
        XCTAssertEqual(net.fixedIn, "0.7.0")
        XCTAssertEqual(net.advisory?.absoluteString, "https://dso.docker.com/cve/GMS-2023-418")
        XCTAssertEqual(net.summary, "Improper rendering of text nodes in golang.org/x/net/html")
        XCTAssertEqual(report.scoutVersion, "v0.6.0")
    }

    func testWhatIsntAReport() {
        for text in ["", "{}", "<html>", #"{"runs":"x"}"#, #"{"version":"2.1.0","runs":[{"tool":"#] {
            XCTAssertNil(DockerScoutReport.parse(text), text)
        }
        let empty = DockerScoutReport.parse(#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"docker scout","rules":[]}},"results":[]}]}"#)
        XCTAssertEqual(empty?.findings, [])
        XCTAssertEqual(empty?.sentence, "No known vulnerabilities")
        XCTAssertEqual(empty?.shortSummary, "no CVEs")
    }

    /// scout-cli#78: a "What's next" block printed after the report.
    func testTextAfterTheReport() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        let trailer = text + "\nWhat's next:\n    View base image update recommendations → docker scout recommendations x\n"
        XCTAssertEqual(DockerScoutReport.parse(trailer)?.findings.count, 7)
        let braced = text + "\nWhat's next: {see docs}\n"
        XCTAssertEqual(DockerScoutReport.parse(braced)?.findings.count, 7, "a brace in the trailer")
        let before = "    ✓ SBOM of image already cached, 245 packages indexed\n" + text
        XCTAssertEqual(DockerScoutReport.parse(before)?.findings.count, 7, "a line before it")
    }

    func testFieldsOfTheWrongKind() throws {
        func one(rule: String, result: String) -> DockerScoutReport? {
            DockerScoutReport.parse(#"{"runs":[{"tool":{"driver":{"rules":["# + rule + #"]}},"results":["# + result + #"]}]}"#)
        }
        let numeric = one(
            rule: #"{"id":"CVE-1","properties":{"security-severity":7.5,"cvssV3_severity":"HIGH"}}"#, result: #"{"ruleId":"CVE-1","ruleIndex":0}"#)
        XCTAssertEqual(numeric?.findings.first?.score, 7.5)
        XCTAssertEqual(numeric?.findings.first?.severity, .high, "the rule's severity when the message has none")
        let words = one(rule: #"{"id":"CVE-1","properties":{"security-severity":"n/a"}}"#, result: #"{"ruleId":"CVE-1"}"#)
        XCTAssertNil(words?.findings.first?.score)
        let big = one(rule: #"{"id":"CVE-1","properties":{"security-severity":42}}"#, result: #"{"ruleId":"CVE-1"}"#)
        XCTAssertNil(big?.findings.first?.score)
        let flag = one(rule: #"{"id":"CVE-1","properties":{"security-severity":true}}"#, result: #"{"ruleId":"CVE-1"}"#)
        XCTAssertNil(flag?.findings.first?.score)
        // An index past the rules: the id says which.
        let moved = DockerScoutReport.parse(
            #"{"runs":[{"tool":{"driver":{"rules":[{"id":"CVE-1","properties":{"fixed_version":"1.1"}},{"id":"CVE-2","properties":{"fixed_version":"2.2"}}]}},"results":[{"ruleId":"CVE-2","ruleIndex":9},{"ruleId":"CVE-2","ruleIndex":0}]}]}"#
        )
        XCTAssertEqual(moved?.findings.map(\.fixedIn), ["2.2"], "both are CVE-2's, read from its rule, once")
        let nameless = one(rule: #"{"id":"CVE-1"}"#, result: #"{"level":"error"}"#)
        XCTAssertEqual(nameless?.findings, [], "a result with neither ruleId nor ruleIndex says nothing")
        let script = one(rule: #"{"id":"CVE-2024-1","helpUri":"javascript:alert(1)"}"#, result: #"{"ruleId":"CVE-2024-1"}"#)
        XCTAssertEqual(script?.findings.first?.advisory?.absoluteString, "https://scout.docker.com/v/CVE-2024-1")
        let other = one(rule: #"{"id":"X-1","helpUri":"file:///etc/passwd"}"#, result: #"{"ruleId":"X-1"}"#)
        XCTAssertNil(other?.findings.first?.advisory)
        XCTAssertEqual(DockerScoutSeverity(word: "Moderate"), .medium)
        XCTAssertEqual(DockerScoutSeverity(word: "negligible"), .low)
        XCTAssertEqual(DockerScoutSeverity(word: "weird"), .unspecified)
        XCTAssertEqual(DockerScoutSeverity(word: nil), .unspecified)
        let wrong = DockerScoutReport.parse(#"{"runs":[{"tool":{"driver":{"rules":"x","version":3}},"results":[7,{"ruleId":5},{"ruleId":"CVE-9","message":"x"}]}]}"#)
        XCTAssertEqual(wrong?.findings.map(\.vulnerability), ["CVE-9"])
        XCTAssertEqual(wrong?.findings.first?.package.name, "unknown")
        XCTAssertNil(wrong?.scoutVersion)
        // No message: the rule's properties say it all.
        let bare = try XCTUnwrap(
            one(
                rule:
                    #"{"id":"CVE-3","properties":{"purls":["pkg:deb/debian/tar@1.34"],"affected_version":"<1.35","fixed_version":"1.35","cvssV3_severity":"LOW"}}"#,
                result: #"{"ruleId":"CVE-3","ruleIndex":0}"#)?.findings.first)
        XCTAssertEqual(bare.package.displayName, "tar")
        XCTAssertEqual(bare.affected, "<1.35")
        XCTAssertEqual(bare.fixedIn, "1.35")
        XCTAssertEqual(bare.severity, .low)
    }

    func testSeverityFromTheLevelWhenNothingElseSays() {
        func severity(_ level: String) -> DockerScoutSeverity? {
            DockerScoutReport.parse(#"{"runs":[{"tool":{"driver":{"rules":[{"id":"CVE-1"}]}},"results":[{"ruleId":"CVE-1","level":""# + level + #""}]}]}"#)?
                .findings.first?.severity
        }
        XCTAssertEqual(severity("error"), .high)
        XCTAssertEqual(severity("warning"), .medium)
        XCTAssertEqual(severity("note"), .low)
        XCTAssertEqual(severity("none"), .unspecified)
        XCTAssertEqual(severity("odd"), .unspecified)
    }

    func testFilterAndGroups() throws {
        let report = try report()
        var filter = DockerScoutFilter()
        XCTAssertTrue(filter.isEmpty)
        let groups = filter.groups(report.findings)
        XCTAssertEqual(groups.map(\.severity), [.critical, .medium, .low, .unspecified], "the worst first, none empty")
        XCTAssertEqual(groups.first?.findings.map(\.score), [9.3, 9.1])
        filter.fixableOnly = true
        XCTAssertFalse(filter.isEmpty)
        let fixable = filter.groups(report.findings).flatMap(\.findings)
        XCTAssertEqual(Set(fixable.map(\.package.name)), ["curl", "nghttp2", "traverse", "net"])
        filter = DockerScoutFilter(severities: [.low])
        XCTAssertEqual(filter.groups(report.findings).map(\.severity), [.low])
        filter = DockerScoutFilter(text: "BABEL")
        XCTAssertEqual(filter.groups(report.findings).flatMap(\.findings).map(\.vulnerability), ["GHSA-67hx-6x53-jw92"])
        filter = DockerScoutFilter(text: "cve-2021")
        XCTAssertEqual(filter.groups(report.findings).flatMap(\.findings).map(\.package.name), ["curl"])
        filter = DockerScoutFilter(text: "deb nginx")
        XCTAssertEqual(filter.groups(report.findings).flatMap(\.findings).map(\.package.name), ["nginx"], "every word, in its purl too")
        filter = DockerScoutFilter(severities: [])
        XCTAssertEqual(filter.groups(report.findings), [])
    }

    func testFailuresSaidPlainly() {
        func failure(_ status: Int32, _ stderr: String, stdout: String = "") -> DockerScoutFailure {
            DockerScoutFailure.classify(status: status, stderr: stderr, stdout: stdout, image: "redis:7", timeoutMinutes: 10)
        }
        let signedOut = failure(1, "Log in with your Docker ID or email address to use docker scout.\nRun docker login.\n")
        XCTAssertEqual(signedOut, .signedOut)
        XCTAssertTrue(signedOut.message.contains("docker login"))
        XCTAssertEqual(failure(1, "image not found in containerd store: x"), .notFound("redis:7"))
        XCTAssertEqual(failure(1, "Error response from daemon: No such image: redis:7"), .notFound("redis:7"))
        XCTAssertEqual(failure(-1, "docker timed out after 600 s"), .timedOut(minutes: 10))
        XCTAssertTrue(DockerScoutFailure.timedOut(minutes: 10).message.contains("10 minutes"))
        XCTAssertEqual(failure(1, "docker: 'scout' is not a docker command.\nSee 'docker --help'"), .notInstalled)
        XCTAssertEqual(failure(0, "", stdout: "Log in with your Docker ID"), .signedOut, "stdout is read when it isn't a report")
        let coloured = String(repeating: "\u{1B}[31mfailed to index\u{1B}[0m: layer \u{1B}]0;title\u{07}sha256:abc is broken in a long way\n", count: 30)
        guard case .failed(let words) = failure(2, coloured + "⠋\n✓\n") else { return XCTFail("not a failure of its own") }
        XCTAssertFalse(words.contains("\u{1B}"), words)
        XCTAssertFalse(words.contains("title"), words)
        XCTAssertTrue(words.contains("failed to index: layer sha256:abc"), words)
        XCTAssertLessThanOrEqual(words.count, 600)
        XCTAssertEqual(words.split(separator: "\n").count, 6, "the last six lines, glyphs alone left out")
        XCTAssertEqual(failure(3, ""), .failed("docker scout exited with 3"))
        XCTAssertEqual(DockerScoutFailure.failed("x").message, "Docker Scout: x")
    }

    func testProgressIsScoutsLastLine() {
        let stderr = "\u{1B}[2K\r ⠋ Indexing\r    ✓ SBOM of image already cached, 245 packages indexed\n"
        XCTAssertEqual(DockerScout.progress(in: stderr), "SBOM of image already cached, 245 packages indexed")
        XCTAssertEqual(DockerScout.indexedPackages(in: stderr), 245)
        XCTAssertEqual(DockerScout.indexedPackages(in: "    ✓ Indexed 3 packages.\n"), 3)
        XCTAssertNil(DockerScout.indexedPackages(in: "nothing"))
        XCTAssertNil(DockerScout.progress(in: "⠋\r⠙\r⠹\r"))
        XCTAssertNil(DockerScout.progress(in: ""))
        // Half of a UTF-8 character at a chunk's end.
        var data = Data("    ✓ Indexed 3 packages\n    Analyzing →".utf8)
        data.removeLast()
        XCTAssertEqual(DockerScout.progress(in: String(decoding: data, as: UTF8.self)), "Analyzing")
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(DockerScout.progress(in: long)?.count, 160)
        let output = DockerScoutOutput()
        XCTAssertEqual(output.append(Data("⠋ Indexing\r".utf8)), "Indexing")
        XCTAssertNil(output.append(Data("⠙ Indexing\r".utf8)), "the same line again says nothing")
        XCTAssertEqual(output.append(Data("✓ Indexed 3 packages\n".utf8)), "Indexed 3 packages")
    }

    func testTheCommand() throws {
        XCTAssertEqual(DockerScout.arguments(for: "redis:7", platform: nil), ["scout", "cves", "--format", "sarif", "local://redis:7"])
        XCTAssertEqual(
            DockerScout.arguments(for: "redis:7", platform: "linux/amd64"), ["scout", "cves", "--format", "sarif", "--platform", "linux/amd64", "local://redis:7"])
        XCTAssertEqual(DockerPlatform(os: "linux", architecture: "arm", variant: "v7")?.description, "linux/arm/v7")
        XCTAssertEqual(DockerPlatform(os: "linux", architecture: "amd64", variant: "v8")?.description, "linux/amd64")
        XCTAssertNil(DockerPlatform(os: "linux", architecture: nil, variant: nil))
        let report = try report()
        XCTAssertEqual(report.shortSummary, "2C 1M 3L 1?")
        XCTAssertEqual(report.sentence, "2 critical, 1 medium, 3 low, 1 unspecified (4 fixable)")
        let ordered = DockerScoutFilter().groups(report.findings).flatMap(\.findings)
        let lines = report.lines(ordered, limit: 3).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(
            lines[1].hasPrefix(
                "- CVE-2021-22945 critical 9.1: curl 7.74.0-1.3+deb11u1 (deb) — fixed in 7.74.0-1.3+deb11u2 — https://scout.docker.com/v/CVE-2021-22945"),
            lines[1])
        XCTAssertEqual(lines.last, "… and 4 more")
        let all = report.lines(ordered)
        XCTAssertTrue(all.contains("- CVE-2023-5129 unspecified: libwebp 0.6.1-2.1 (deb) — no fix yet"), all)
        XCTAssertTrue(all.contains("@babel/traverse 7.22.5 (npm) — fixed in 7.23.2"), all)
    }
}

/// The app's scans, against a stub `docker`: progress, then findings; one
/// at a time per image; signed out said so; Cancel and the timeout stop
/// Scout; nothing real ever runs from a test.
@MainActor
final class DockerScoutScansTests: XCTestCase {
    private var dir: URL!
    private var stub: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ot-scout-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stub = dir.appendingPathComponent("docker")
        try """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$DOCKER_CONTEXT|$*" >> "$dir/calls"
        case "$*" in
          *local://ot/scanned:1)
            echo '    ⠋ Indexing' >&2; sleep 0.3
            echo '    ✓ Indexed 3 packages' >&2; sleep 0.6
            cat "$dir/report.json" ;;
          *local://ot/private:1)
            echo 'Log in with your Docker ID or email address to use docker scout.' >&2; exit 1 ;;
          *local://ot/slow:1)
            echo $$ > "$dir/pid"; exec sleep 30 ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try FakeDockerEngine.scoutReport.write(to: dir.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func scans() -> DockerScoutScans {
        let scans = DockerScoutScans()
        let stub = stub!
        scans.locate = { DockerCLI(executable: stub, endpoint: $0) }
        return scans
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private let colima = DockerEndpoint(address: .unix("/c.sock"), context: "colima", source: "context colima")

    func testAScanReportsItsProgressThenItsFindings() async {
        let scans = scans()
        scans.scan(imageID: "sha256:aa", name: "ot/scanned:1", endpoint: colima, engine: nil)
        XCTAssertEqual(scans.scan(for: "sha256:aa")?.state.isScanning, true, "scanning at once")
        let said = await eventually {
            if case .scanning(_, let progress) = scans.scan(for: "sha256:aa")?.state { return progress == "Indexed 3 packages" }
            return false
        }
        XCTAssertTrue(said, "\(String(describing: scans.scan(for: "sha256:aa")))")
        let found = await eventually { scans.scan(for: "sha256:aa")?.state.report != nil }
        XCTAssertTrue(found, "\(String(describing: scans.scan(for: "sha256:aa")))")
        let report = scans.scan(for: "sha256:aa")?.state.report
        XCTAssertEqual(report?.shortSummary, "1C 1H 1M 1L")
        XCTAssertEqual(report?.packagesIndexed, 3)
        XCTAssertEqual(calls(), ["colima|scout cves --format sarif local://ot/scanned:1"])
        XCTAssertEqual(scans.scan(matching: "ot/scanned:1", images: [])?.imageID, "sha256:aa")
    }

    func testAScanAlreadyRunningIsntStartedTwice() async {
        let scans = scans()
        scans.scan(imageID: "sha256:aa", name: "ot/scanned:1", endpoint: colima, engine: nil)
        scans.scan(imageID: "sha256:aa", name: "ot/scanned:1", endpoint: colima, engine: nil)
        let found = await eventually { scans.scan(for: "sha256:aa")?.state.report != nil }
        XCTAssertTrue(found)
        XCTAssertEqual(calls().count, 1)
    }

    func testSignedOutSaysSo() async {
        let scans = scans()
        scans.scan(imageID: "sha256:bb", name: "ot/private:1", endpoint: nil, engine: nil)
        let failed = await eventually {
            if case .failed(.signedOut, _) = scans.scan(for: "sha256:bb")?.state { return true }
            return false
        }
        XCTAssertTrue(failed, "\(String(describing: scans.scan(for: "sha256:bb")))")
    }

    func testCancelStopsScout() async throws {
        let scans = scans()
        scans.scan(imageID: "sha256:cc", name: "ot/slow:1", endpoint: nil, engine: nil)
        let pidFile = dir.appendingPathComponent("pid")
        let started = await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(100))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "it runs")
        scans.cancel("sha256:cc")
        XCTAssertNil(scans.scan(for: "sha256:cc"), "forgotten at once")
        let gone = await eventually(3) { kill(pid, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(gone, "Scout stopped")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(scans.scan(for: "sha256:cc"), "and its end doesn't bring it back")
    }

    func testATimeoutSaysSo() async {
        let scans = scans()
        scans.timeout = 0.5
        scans.scan(imageID: "sha256:dd", name: "ot/slow:1", endpoint: nil, engine: nil)
        let timedOut = await eventually(5) {
            if case .failed(.timedOut, _) = scans.scan(for: "sha256:dd")?.state { return true }
            return false
        }
        XCTAssertTrue(timedOut, "\(String(describing: scans.scan(for: "sha256:dd")))")
    }

    /// The guard on `make test`: a scan from a test, with no stub, reaches
    /// no Docker and no Docker service.
    func testNothingRealRunsInATestProcess() {
        let override = DockerCLI.override
        DockerCLI.override = nil
        defer { DockerCLI.override = override }
        XCTAssertFalse(DockerScout.mayRunReal)
        let scans = DockerScoutScans()
        scans.scan(imageID: "sha256:ee", name: "redis:7", endpoint: nil, engine: nil)
        guard case .failed(.isolated, _) = scans.scan(for: "sha256:ee")?.state else {
            return XCTFail("\(String(describing: scans.scan(for: "sha256:ee")))")
        }
        XCTAssertTrue(DockerScoutScans.shared !== scans)
    }

    func testFinishedScansAreFoundByNameOrID() {
        let scans = DockerScoutScans()
        let report = DockerScoutReport.parse(FakeDockerEngine.scoutReport)
        scans.finish("sha256:" + String(repeating: "a", count: 64), image: "nginx:1.27", report.map { .success($0) })
        let images = [ImageSummary(Id: "sha256:" + String(repeating: "a", count: 64), RepoTags: ["nginx:1.27", "web:latest"], Created: 0, Size: 1)]
        XCTAssertNotNil(scans.scan(matching: "nginx:1.27", images: []))
        XCTAssertNotNil(scans.scan(matching: "aaaaaaaaaaaa", images: []))
        XCTAssertNotNil(scans.scan(matching: "sha256:aaaaaaaaaaaaaaaa", images: []))
        XCTAssertNotNil(scans.scan(matching: "web", images: images), "another tag, latest by default")
        XCTAssertNil(scans.scan(matching: "redis:7", images: images))
        scans.finish("sha256:x", image: "x:1", nil)
        XCTAssertNil(scans.scan(for: "sha256:x"))
    }

    /// A rebuild moves the tag to another image: the name means that one
    /// now, scanned or not — never the old one's report. With no image
    /// holding the name, the latest scan by it answers, whatever order
    /// the store keeps them in.
    func testATagThatMovedMeansTheNewImage() throws {
        let scans = DockerScoutScans()
        let old = "sha256:" + String(repeating: "a", count: 64)
        let new = "sha256:" + String(repeating: "b", count: 64)
        let report = try XCTUnwrap(DockerScoutReport.parse(FakeDockerEngine.scoutReport))
        scans.finish(old, image: "app:latest", .success(report))
        let rebuilt = [
            ImageSummary(Id: new, RepoTags: ["app:latest"], Created: 1, Size: 1),
            ImageSummary(Id: old, RepoTags: ["<none>:<none>"], Created: 0, Size: 1),
        ]
        XCTAssertNil(scans.scan(matching: "app:latest", images: rebuilt), "the rebuilt image is unscanned")
        XCTAssertNil(scans.scan(matching: "app", images: rebuilt))
        XCTAssertEqual(scans.scan(matching: "aaaaaaaaaaaa", images: rebuilt)?.imageID, old, "the old one, by its ID")
        Thread.sleep(forTimeInterval: 0.01)
        scans.finish(new, image: "app:latest", .failure(.signedOut))
        for _ in 0..<20 {
            XCTAssertEqual(scans.scan(matching: "app:latest", images: rebuilt)?.imageID, new)
            XCTAssertEqual(scans.scan(matching: "app:latest", images: [])?.imageID, new, "the latest by the name")
        }
        // A registry's port is not a tag.
        let local = "sha256:" + String(repeating: "c", count: 64)
        scans.finish(local, image: "localhost:5000/app:latest", .success(report))
        let pushed = [ImageSummary(Id: local, RepoTags: ["localhost:5000/app:latest"], Created: 0, Size: 1)]
        XCTAssertEqual(scans.scan(matching: "localhost:5000/app", images: pushed)?.imageID, local)
    }
}
