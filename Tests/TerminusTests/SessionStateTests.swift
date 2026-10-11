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

    func testAnIslandFromBeforeTheBindingWasADecisionComesBackUnbound() throws {
        // Every island used to bind its checkout by itself, and the binding
        // now decides where new tabs go: read back, those files would hand
        // every old group the binding this rule exists to undo.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tab = #"{"workingDirectory":"/repo","isPinned":false,"group":0}"#
        let island = #"{"name":"klaim","color":"purple","isCollapsed":false,"isStashed":false,"folder":"/repo","restoresOnLaunch":true}"#
        try Data(#"{"selectedIndex":0,"tabs":[\#(tab)],"groups":[\#(island)]}"#.utf8).write(to: url)
        let loaded = SessionState.load(from: url)
        XCTAssertEqual(loaded?.groups?.count, 1)
        XCTAssertNil(loaded?.groups?.first?.boundFolder)
        XCTAssertNil(loaded?.groups?.first?.takesNewTabs)
        XCTAssertEqual(loaded?.tabs.first?.group, 0, "the island itself still comes back")
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
        let rebuilt = try XCTUnwrap(state.tabs.first?.panes).tree { directory, _ in Pane(directory) }
        XCTAssertEqual(rebuilt.leaves.map(\.directory), ["/a", "/b", nil])
        guard case .split(let axis, let ratio, _, .split(let inner, _, _, _)) = rebuilt else { return XCTFail("shape lost") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
        XCTAssertEqual(inner, .vertical)
        XCTAssertEqual(state.tabs.first?.focusedPane, 1)
    }

    func testPanesCarryTheirSavedText() throws {
        final class Pane {
            let directory: String
            init(_ directory: String) { self.directory = directory }
        }
        let a = Pane("/a"), b = Pane("/b")
        let layout = SessionState.PaneLayout(
            SplitTree.leaf(a).inserting(b, at: a, .down), directory: \.directory, scrollback: { $0 === b ? "b.txt" : nil })
        XCTAssertEqual(layout.scrollbackFiles, ["b.txt"])
        var files: [String?] = []
        _ = layout.tree { directory, scrollback in
            files.append(scrollback)
            return Pane(directory ?? "")
        }
        XCTAssertEqual(files, [nil, "b.txt"])
    }

    func testASessionFromBeforeScrollbackStillLoads() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"tabs":[{"isPinned":false,"panes":{"split":{"axis":"horizontal","ratio":0.5,"first":{"pane":{"directory":"/a"}},"second":{"pane":{"directory":"/b"}}}}}]}"#
                .utf8
        ).write(to: url)
        let tab = try XCTUnwrap(SessionState.load(from: url)?.tabs.first)
        XCTAssertNil(tab.scrollback)
        XCTAssertEqual(tab.panes?.scrollbackFiles, [])
    }

    func testMissingOrCorruptFileIsNil() throws {
        XCTAssertNil(SessionState.load(from: url))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
        // Set aside, so the autosave that follows doesn't write over it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let aside = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session.unreadable-") }
        XCTAssertEqual(try aside.first.map { try String(contentsOf: $0, encoding: .utf8) }, "{not json")
    }

    func testUnknownAgentIsACorruptFileNotACrash() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tabs":[{"isPinned":false,"agent":"gemini"}]}"#.utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
    }
}
