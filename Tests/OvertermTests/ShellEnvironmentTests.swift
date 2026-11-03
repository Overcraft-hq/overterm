import XCTest

@testable import Overterm

final class ShellEnvironmentTests: XCTestCase {
    private func output(_ fields: [String]) -> Data {
        Data(fields.joined(separator: "\0").utf8) + Data([0])
    }

    func testParseReadsTheEntriesAfterTheMarker() {
        let data = output(["PATH=/opt/homebrew/bin:/usr/bin", "HOME=/Users/me", "NOTE=two\nlines", "EMPTY=", "EQ=a=b"])
        let parsed = ShellEnvironment.parse(Data((ShellEnvironment.marker).utf8) + Data([0]) + data)
        XCTAssertEqual(parsed?["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(parsed?["HOME"], "/Users/me")
        XCTAssertEqual(parsed?["NOTE"], "two\nlines")
        XCTAssertEqual(parsed?["EMPTY"], "")
        XCTAssertEqual(parsed?["EQ"], "a=b")
    }

    func testWhatTheStartupFilesPrintIsNotTheEnvironment() {
        let data = output(["Welcome back!\nFAKE=1\n" + ShellEnvironment.marker, "PATH=/usr/bin", "LANG=en_US.UTF-8"])
        let parsed = ShellEnvironment.parse(data)
        XCTAssertNil(parsed?["FAKE"])
        XCTAssertNil(parsed?["Welcome back!\nFAKE"])
        XCTAssertEqual(parsed, ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
    }

    func testNoMarkerOrNoPathIsNoAnswer() {
        XCTAssertNil(ShellEnvironment.parse(output(["PATH=/usr/bin"])))
        XCTAssertNil(ShellEnvironment.parse(output([ShellEnvironment.marker, "HOME=/Users/me"])))
        XCTAssertNil(ShellEnvironment.parse(Data()))
    }

    func testExecutableIsTheFirstOnThePath() {
        let environment = ["PATH": "/nowhere::/opt/homebrew/bin:/usr/local/bin"]
        let there: Set<String> = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/local/bin/kubectl-oidc_login"]
        XCTAssertEqual(ShellEnvironment.executable("aws", in: environment, isExecutable: there.contains)?.path, "/opt/homebrew/bin/aws")
        XCTAssertEqual(
            ShellEnvironment.executable("kubectl-oidc_login", in: environment, isExecutable: there.contains)?.path, "/usr/local/bin/kubectl-oidc_login")
        XCTAssertNil(ShellEnvironment.executable("claude", in: environment, isExecutable: there.contains))
        XCTAssertNil(ShellEnvironment.executable("bin/aws", in: environment, isExecutable: { _ in true }))
        XCTAssertNil(ShellEnvironment.executable("", in: environment, isExecutable: { _ in true }))
        XCTAssertNil(ShellEnvironment.executable("aws", in: [:], isExecutable: { _ in true }))
    }

    /// The script the login shell is given, run by a plain sh (never the
    /// user's own shell or its startup files), parses back.
    func testTheScriptParsesBack() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo noise; " + ShellEnvironment.script]
        process.environment = ["PATH": "/usr/bin:/bin", "OVERTERM_TEST_VALUE": "a\nb=c"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parsed = try XCTUnwrap(ShellEnvironment.parse(data))
        XCTAssertEqual(parsed["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(parsed["OVERTERM_TEST_VALUE"], "a\nb=c")
        XCTAssertEqual(ShellEnvironment.executable("env", in: parsed)?.path, "/usr/bin/env")
    }

    func testTheShellIsStartedWithHistoryOff() {
        let launched = ShellEnvironment.launchEnvironment(["PATH": "/usr/bin", "HISTFILE": "/Users/me/.zsh_history"])
        XCTAssertEqual(launched["HISTFILE"], "/dev/null")
        XCTAssertEqual(launched["PATH"], "/usr/bin")
        XCTAssertEqual(ShellEnvironment.launchEnvironment(["PATH": "/usr/bin"])["HISTFILE"], "/dev/null")
    }

    func testTheUsersOwnHistoryFileIsPutBack() {
        let answer = ["PATH": "/usr/bin", "HISTFILE": "/dev/null"]
        XCTAssertEqual(
            ShellEnvironment.restoringHistory(answer, inherited: ["HISTFILE": "/Users/me/.zsh_history"]),
            ["PATH": "/usr/bin", "HISTFILE": "/Users/me/.zsh_history"])
        XCTAssertEqual(ShellEnvironment.restoringHistory(answer, inherited: [:]), ["PATH": "/usr/bin"])
        // One the startup files set themselves is theirs.
        let own = ["PATH": "/usr/bin", "HISTFILE": "/Users/me/.histfile"]
        XCTAssertEqual(ShellEnvironment.restoringHistory(own, inherited: ["HISTFILE": "/elsewhere"]), own)
    }

    /// What the shell is started with reaches it: a plain sh, given the
    /// script and the launch environment, sees HISTFILE=/dev/null.
    func testTheShellSeesHistoryOff() throws {
        let data = try XCTUnwrap(
            ShellEnvironment.run(
                URL(fileURLWithPath: "/bin/sh"), ["-c", ShellEnvironment.script],
                environment: ShellEnvironment.launchEnvironment(["PATH": "/usr/bin:/bin", "HISTFILE": "/Users/me/.zsh_history"]),
                timeout: 10))
        let parsed = try XCTUnwrap(ShellEnvironment.parse(data))
        XCTAssertEqual(parsed["HISTFILE"], "/dev/null")
        XCTAssertEqual(ShellEnvironment.restoringHistory(parsed, inherited: ["HISTFILE": "/Users/me/.zsh_history"])["HISTFILE"], "/Users/me/.zsh_history")
    }

    /// A shell whose startup waits is stopped at the timeout, not waited on.
    func testAShellThatHangsIsGivenUpOn() {
        let started = Date()
        let data = ShellEnvironment.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30; " + ShellEnvironment.script], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
