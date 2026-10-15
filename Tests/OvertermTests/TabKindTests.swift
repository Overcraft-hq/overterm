import XCTest

@testable import Overterm

/// What a tab's icon says it is. The rule decides a glyph people read
/// without looking, so it has to be boring and predictable.
final class TabKindTests: XCTestCase {
    func testAnAgentTabIsAnAgentWhateverItsTitleSays() {
        XCTAssertEqual(TabKind.of(agent: .claude, title: "ssh prod-eu-1", hasPort: true), .agent)
    }

    func testSshIsToldFromTheCommandAndFromTheRemotePrompt() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "ssh prod-eu-1", hasPort: false), .ssh)
        XCTAssertEqual(TabKind.of(agent: nil, title: "mosh box", hasPort: false), .ssh)
        XCTAssertEqual(TabKind.of(agent: nil, title: "deploy@prod-eu-1:~", hasPort: false), .ssh)
    }

    /// A path has an @ in it often enough (node_modules/@scope, an email in
    /// a cwd) that it must not read as a machine.
    func testAPathIsNotAMachine() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "~/src/@scope/pkg", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "@", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "me@", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "@host", hasPort: false), .shell)
    }

    /// Listening is what makes a shell a server — the title alone never says
    /// so ("pnpm dev" could be anything).
    func testAListeningTabIsAServer() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "pnpm dev", hasPort: true), .server)
        XCTAssertEqual(TabKind.of(agent: nil, title: "pnpm dev", hasPort: false), .shell)
    }

    func testAPlainShellIsTheFallback() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "zsh", hasPort: false), .shell)
    }
}
