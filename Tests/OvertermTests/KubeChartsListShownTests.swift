import AppKit
import SwiftUI
import XCTest

@testable import Overterm

/// A Metrics tab's group read only while on screen (a workload's saved
/// queries, a node's top pods, its disks and network) is said shown only
/// while its header is inside what the tab shows: the `LazyVStack` builds
/// rows below the fold ahead of a scroll, and its `onAppear` there asked
/// Prometheus for a group nobody could see (the `kubernetesCharts`
/// scenario's saved queries, their header at 893 pt in 540).
@MainActor
final class KubeChartsListShownTests: XCTestCase {
    private final class Calls {
        var said: [(String, Bool)] = []
        func shown(_ title: String) -> Bool? { said.last { $0.0 == title }?.1 }
    }

    private func chart(_ index: Int, now: Date) -> KubePodCharts.Chart {
        KubePodCharts.Chart(
            data: KubeChartData(
                id: "test.\(index)", title: "Chart \(index)", unit: .cores,
                series: ["api-1", "api-2", "api-3"].map { name in
                    KubeChartSeries(
                        id: name, name: name,
                        points: (0..<120).map { KubeSeriesPoint(time: now.addingTimeInterval(Double($0 - 120) * 30), value: Double($0 % 7) / 10) })
                },
                start: now.addingTimeInterval(-3600), end: now, step: 30),
            headline: nil)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testAHeaderBuiltBelowTheFoldIsNotOnScreen() {
        XCTAssertFalse(KubeObjectChartsList.onScreen(CGRect(x: 14, y: 893, width: 700, height: 14), viewport: 540), "built ahead, below the fold")
        XCTAssertTrue(KubeObjectChartsList.onScreen(CGRect(x: 14, y: 520, width: 700, height: 14), viewport: 540), "at the bottom edge")
        XCTAssertTrue(KubeObjectChartsList.onScreen(CGRect(x: 14, y: -10, width: 700, height: 14), viewport: 540), "half scrolled off the top")
        XCTAssertFalse(KubeObjectChartsList.onScreen(CGRect(x: 14, y: -20, width: 700, height: 14), viewport: 540), "scrolled off the top")
        XCTAssertFalse(KubeObjectChartsList.onScreen(CGRect(x: 14, y: 10, width: 700, height: 14), viewport: 0), "not laid out yet")
    }

    func testAGroupReadWhenShownIsShownOnlyWhileItsHeaderIsOnScreen() async throws {
        try await scrolled(savedCharts: 0)
    }

    /// A group taller than the tab — six saved queries — stays shown while
    /// its charts are, its header scrolled off above: said gone there, its
    /// queries would stop with the charts on screen.
    func testAGroupStaysShownWhileItsChartsAreOnScreen() async throws {
        try await scrolled(savedCharts: 6)
    }

    /// The Deployment's six charts, then the saved queries' group with
    /// `savedCharts` (none: pending): never shown below the fold, shown at
    /// the bottom, gone back at the top.
    private func scrolled(savedCharts: Int) async throws {
        let now = Date()
        let saved = KubeSavedCharts.groupTitle
        let charts = KubeObjectCharts(
            range: .hour,
            groups: [
                KubeObjectCharts.Group(title: "Deployment", charts: (0..<6).map { chart($0, now: now) }),
                KubeObjectCharts.Group(
                    title: saved, charts: (0..<savedCharts).map { chart(10 + $0, now: now) }, readsWhenShown: true, pending: savedCharts == 0),
            ], caption: "", span: "last 1 h", hasSamples: true)
        let calls = Calls()
        let theme = ChromeTheme(background: .black, foreground: .white)
        // 540 pt for the charts: the Deployment's six fill it and more,
        // the saved queries' header below the fold.
        let cursor = KubeChartCursor()
        func tab(_ charts: KubeObjectCharts?) -> some View {
            // As the Metrics tab lays it out: its controls above, the list
            // made once Prometheus has answered.
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Last 1 hour").frame(height: 40)
                Rectangle().frame(height: 1)
                if let charts {
                    KubeObjectChartsList(charts: charts, cursor: cursor, theme: theme, groupShown: { calls.said.append(($0, $1)) })
                } else {
                    Text(verbatim: "Asking Prometheus…")
                    Spacer()
                }
            }
            .frame(width: 760, height: 581)
        }
        let host = NSHostingView(rootView: tab(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 581), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await settle(host)
        host.rootView = tab(charts)
        try await settle(host)
        XCTAssertNotEqual(calls.shown(saved), true, "below the fold, never said shown: \(calls.said)")

        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = scrollView(subview) { return found } }
            return nil
        }
        let scroll = try XCTUnwrap(scrollView(host))
        let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 0, "the tab scrolls")
        let flipped = scroll.documentView?.isFlipped ?? true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? bottom : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        XCTAssertEqual(calls.shown(saved), true, "scrolled to, shown: \(calls.said)")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 0 : bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        XCTAssertEqual(calls.shown(saved), false, "scrolled away, no longer: \(calls.said)")
    }
}
