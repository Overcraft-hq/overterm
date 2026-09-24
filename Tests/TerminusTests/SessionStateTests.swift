import XCTest

@testable import Terminus

final class SessionStateTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-session-\(UUID().uuidString)/session.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testRoundTrips() throws {
        let state = SessionState(
            tabs: [
                .init(workingDirectory: "/repo", customTitle: "main", color: "blue", isPinned: true, agent: nil),
                .init(workingDirectory: "/repo-wt-x", customTitle: nil, color: nil, isPinned: false, agent: .claude, attachedCheckout: "/repo-wt-y"),
            ],
            selectedIndex: 1)
        try state.save(to: url)
        XCTAssertEqual(SessionState.load(from: url), state)
    }

    func testASessionFromBeforeAttachingStillLoads() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"selectedIndex":0,"tabs":[{"workingDirectory":"/repo","isPinned":false}]}"#.utf8).write(to: url)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.first?.attachedCheckout, nil)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.count, 1)
    }

    func testASplitTabsLayoutRoundTrips() throws {
        final class Pane {
            let directory: String?
            init(_ directory: String?) { self.directory = directory }
        }
        let a = Pane("/a"), b = Pane("/b"), c = Pane(nil)
        let tree = SplitTree.leaf(a).inserting(b, at: a, .right).inserting(c, at: b, .down).settingRatio(0.3, at: [])
        let layout = SessionState.PaneLayout(tree, directory: \.directory)
        var state = SessionState(tabs: [.init(workingDirectory: "/b", isPinned: false, panes: layout, focusedPane: 1)], selectedIndex: 0)
        try state.save(to: url)
        state = try XCTUnwrap(SessionState.load(from: url))
        let rebuilt = try XCTUnwrap(state.tabs.first?.panes).tree(Pane.init)
        XCTAssertEqual(rebuilt.leaves.map(\.directory), ["/a", "/b", nil])
        guard case .split(let axis, let ratio, _, .split(let inner, _, _, _)) = rebuilt else { return XCTFail("shape lost") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
        XCTAssertEqual(inner, .vertical)
        XCTAssertEqual(state.tabs.first?.focusedPane, 1)
    }

    func testMissingOrCorruptFileIsNil() throws {
        XCTAssertNil(SessionState.load(from: url))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
    }

    func testUnknownAgentIsACorruptFileNotACrash() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tabs":[{"isPinned":false,"agent":"gemini"}]}"#.utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
    }
}
