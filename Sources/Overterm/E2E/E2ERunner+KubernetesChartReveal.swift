import AppKit
import Foundation

/// A chart below the fold, scrolled to as a person scrolls to it. A tab's
/// charts sit in a `LazyVStack`, which builds nothing past what shows: a
/// chart off screen is in no registry, and a check that reads one there
/// passed only when SwiftUI happened to build it ahead — which it does or
/// not by the window's height and its timing.
extension E2ERunner {
    /// Scrolls the charts on screen in `scope` until `identifier` is laid
    /// out: down from the top of their scroll view, a part of a page at a
    /// time. `top` then puts it at the top of what shows, so the chart
    /// under it shows too (a hover over two). Whether it is on screen.
    @discardableResult
    func revealChart(_ identifier: String, scope: ObjectIdentifier?, top: Bool = false) async -> Bool {
        let charts = KubeChartRegistry.shared
        func laidOut() -> Bool { (charts.chart(identifier, in: scope)?.size.height ?? 0) > 1 }
        if !top, laidOut() { return true }
        // The tab's first charts, to find what they scroll in.
        _ = await eventually(15) { !charts.identifiers(in: scope).isEmpty }
        // Its tree, built for the frames below: off again after, as it was.
        defer { Self.accessibilityTree(false) }
        guard let scroll = await chartsScroll(scope: scope) else {
            note("no charts' scroll view to scroll to \(identifier) in")
            return await eventually(5, laidOut)
        }
        // Built already (by the view's last scroll): only put at the top.
        if !laidOut() {
            var offset: CGFloat = 0
            while !laidOut() {
                guard let height = scroll.documentView?.frame.height else { break }
                let clip = scroll.contentView.bounds.height
                Self.scroll(scroll, toTop: offset)
                if await eventually(1.5, laidOut) { break }
                guard offset < height - clip else { break }
                offset += max(80, clip * 0.6)
            }
        }
        guard laidOut() else {
            note("\(identifier) never laid out; on screen: \(charts.identifiers(in: scope).joined(separator: ", "))")
            return false
        }
        if top, let element = await overviewElement(identifier, timeout: 3), let document = scroll.documentView {
            let rect = document.convert(window.convertFromScreen(element.frame), from: nil)
            let fromTop = document.isFlipped ? rect.minY : document.frame.height - rect.maxY
            Self.scroll(scroll, toTop: fromTop - 6)
        }
        return await eventually(5, laidOut)
    }

    /// The charts on screen in `scope` back at the top of their list, as
    /// the scenario found them: the list keeps where it was scrolled to for
    /// the next object's tab, whose charts further down — read only while
    /// shown — would show from the start.
    func chartsToTop(scope: ObjectIdentifier?) async {
        defer { Self.accessibilityTree(false) }
        guard let scroll = await chartsScroll(scope: scope) else { return }
        Self.scroll(scroll, toTop: 0)
        await pause(0.3)
    }

    /// The page's element of that accessibility identifier scrolled into
    /// view in the scroll view it is in — an Overview's card or caption
    /// below the fold, as a person scrolls to it. Whether it was found.
    @discardableResult
    func revealElement(_ identifier: String) async -> Bool {
        defer { Self.accessibilityTree(false) }
        var found = await overviewElement(identifier, timeout: 2)
        // Not built yet — below the fold of a lazy stack: the page's tallest
        // scroll view stepped down until it is.
        if found == nil, let scroll = tallestScroll() {
            var offset: CGFloat = 0
            while found == nil, let height = scroll.documentView?.frame.height {
                let clip = scroll.contentView.bounds.height
                offset += max(80, clip * 0.6)
                Self.scroll(scroll, toTop: offset)
                found = await overviewElement(identifier, timeout: 1.5)
                guard offset < height - clip else { break }
            }
        }
        guard let element = found else {
            note("\(identifier): not found by its identifier; the page scrolled down past the fold instead")
            return false
        }
        let rect = window.convertFromScreen(element.frame)
        guard let scroll = verticalScroll(containing: rect), let document = scroll.documentView else {
            note("\(identifier): in no scroll view")
            return false
        }
        document.scrollToVisible(document.convert(rect, from: nil))
        await pause(0.3)
        return true
    }

    /// The scroll view the charts on screen in `scope` scroll in: the one
    /// one of them is in (by its accessibility frame).
    private func chartsScroll(scope: ObjectIdentifier?) async -> NSScrollView? {
        for id in KubeChartRegistry.shared.identifiers(in: scope) {
            guard let element = await overviewElement(id, timeout: 2) else { continue }
            if let scroll = verticalScroll(containing: window.convertFromScreen(element.frame)) { return scroll }
        }
        return nil
    }

    /// The page's scroll view with the tallest content that scrolls up and down, not a table's.
    private func tallestScroll() -> NSScrollView? {
        guard let root = app.kubernetesView else { return nil }
        var found: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView,
                !(document is NSTableView), !(document is NSTextView), document.frame.height > scroll.contentView.bounds.height + 1,
                document.frame.height > (found?.documentView?.frame.height ?? 0)
            {
                found = scroll
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The innermost scroll view of the page that scrolls up and down and
    /// whose content holds `rect` (window points) — below the fold or not,
    /// so not by a hit test, which finds what is drawn there now.
    private func verticalScroll(containing rect: CGRect) -> NSScrollView? {
        guard let root = app.kubernetesView else { return nil }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        var found: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView,
                !(document is NSTableView), !(document is NSTextView), document.frame.height > scroll.contentView.bounds.height + 1,
                document.convert(document.bounds, to: nil).contains(point)
            {
                found = scroll
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// `scroll` moved to show its document from `offset` below its top, kept inside it.
    private static func scroll(_ scroll: NSScrollView, toTop offset: CGFloat) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView.bounds.height
        let clamped = min(max(0, offset), max(0, document.frame.height - clip))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? clamped : max(0, document.frame.height - clip - clamped)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
