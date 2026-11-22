import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell

/// An agent's folder's checkout, walked off the main thread (docs/design/
/// activity/analysis.md, 7.2): the main thread is answered from what was
/// walked, and asks for the rest.
final class AgentTreeRootsTests: XCTestCase {
    func testAFolderIsWalkedOffTheMainThreadThenKnown() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-roots-\(UUID().uuidString)")
        let nested = checkout.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let roots = AgentTreeRoots()
        XCTAssertNil(roots.root(for: nested.path), "not walked yet: asked for, never walked on the caller's thread")
        let deadline = Date().addingTimeInterval(5)
        while roots.root(for: nested.path) == nil, Date() < deadline { usleep(5_000) }
        XCTAssertEqual(roots.root(for: nested.path), FileTreeModel.treeRoot(for: nested.path))
        let other = checkout.appendingPathComponent("src")
        roots.prime([other.path])
        XCTAssertEqual(roots.root(for: other.path)?.standardizedFileURL, checkout.standardizedFileURL, "primed on a GCD thread: known at once")
    }
}
