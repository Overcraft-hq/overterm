import AppKit
import XCTest

@testable import Overterm

/// The pages over the body as declared (`WorkspacePage`) and made
/// (`WorkspacePages`): no window, plain views.
@MainActor
final class WorkspacePagesTests: XCTestCase {
    private func content() -> NSView { NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }

    func testAPageWithoutAViewMadeLaterIsNotMade() {
        let pages = WorkspacePages()
        pages.declare(WorkspacePage(.settings))
        XCTAssertNil(pages.made(.settings), "nothing made, nowhere to put it")
        let view = NSView()
        let content = content()
        pages.add(.settings, view, in: content, below: content.topAnchor)
        XCTAssertTrue(pages.made(.settings) === view)
        XCTAssertTrue(view.isHidden, "added hidden, until shown")
        XCTAssertFalse(view.translatesAutoresizingMaskIntoConstraints)
    }

    func testAViewIsMadeOnceTheFirstTimeItIsAskedFor() {
        let pages = WorkspacePages()
        var made = 0
        var docker = WorkspacePage(.docker)
        docker.makeView = {
            made += 1
            return NSView()
        }
        pages.declare(docker)
        XCTAssertNil(pages.made(.docker), "no page added yet: no where")
        XCTAssertEqual(made, 0)

        let content = content()
        let settings = NSView()
        pages.add(.settings, settings, in: content, below: content.topAnchor)
        // Something floating over the pages (the palette) stays over a page made later.
        let palette = NSView()
        content.addSubview(palette)
        let view = pages.made(.docker)
        XCTAssertNotNil(view)
        XCTAssertTrue(pages.made(.docker) === view)
        XCTAssertEqual(made, 1)
        XCTAssertTrue(view?.superview === content)
        XCTAssertTrue(pages.view(.docker) === view)
        let order = content.subviews
        XCTAssertLessThan(order.firstIndex(of: view!)!, order.firstIndex(of: palette)!, "beside the pages, under what floats")
    }

    func testAPageThatCantBeMadeYetIsAskedAgain() {
        let pages = WorkspacePages()
        // A box, not a captured var: the closure is main-actor, so Sendable.
        let ready = Flag()
        var docker = WorkspacePage(.docker)
        docker.makeView = { ready.value ? NSView() : nil }
        pages.declare(docker)
        let content = content()
        pages.add(.settings, NSView(), in: content, below: content.topAnchor)
        XCTAssertNil(pages.made(.docker))
        ready.value = true
        XCTAssertNotNil(pages.made(.docker))
    }

    func testTheDeclaredPagesComeInTheOverlaysOrder() {
        let pages = WorkspacePages()
        pages.declare(WorkspacePage(.docker))
        pages.declare(WorkspacePage(.settings))
        XCTAssertEqual(pages.all.map(\.overlay), [.settings, .docker])
        XCTAssertNotNil(pages[.docker])
    }

    func testTheListIsThePagesFirstTableAndOnlyAListPagesOwn() {
        let pages = WorkspacePages()
        let page = NSView()
        let list = NSTableView()
        let detail = NSView()
        let steps = NSTableView()
        let side = NSView()
        side.addSubview(list)
        detail.addSubview(steps)
        page.addSubview(side)
        page.addSubview(detail)
        let content = content()
        pages.declare(WorkspacePage(.docker))
        pages.add(.docker, page, in: content, below: content.topAnchor)
        XCTAssertNil(pages.list(.docker), "a page without a list has none")

        var docker = WorkspacePage(.docker)
        docker.hasList = true
        pages.declare(docker)
        XCTAssertTrue(pages.list(.docker) === list, "depth first: the list, not a detail's steps")
        XCTAssertTrue(WorkspacePages.firstTable(in: detail) === steps)
        XCTAssertNil(WorkspacePages.firstTable(in: NSView()))
    }

    func testOnlyAKeyWithoutCommandControlOrOptionIsTheLists() {
        XCTAssertTrue(WorkspacePage.isListKey([]))
        XCTAssertTrue(WorkspacePage.isListKey(.shift), "D is compose down")
        XCTAssertFalse(WorkspacePage.isListKey(.command))
        XCTAssertFalse(WorkspacePage.isListKey(.control))
        XCTAssertFalse(WorkspacePage.isListKey([.option, .shift]))
    }

    func testEveryOverlayIsListed() {
        XCTAssertEqual(WorkspaceOverlay.allCases, [.settings, .docker, .kubernetes])
    }
}

/// A value a main-actor closure reads after the test changes it.
@MainActor
private final class Flag {
    var value = false
}
