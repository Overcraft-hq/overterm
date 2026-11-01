import AppKit

/// A big review — 250 files, thousands of lines — scrolled by the page's
/// own scroll views (no system events), each step laid out and drawn, and
/// timed: the file list, and a long file's diff in both layouts.
extension E2ERunner {
    func reviewPerfScenario() async {
        let repo = scratch.appendingPathComponent("review-perf")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        func body(_ seed: Int, _ count: Int, changed: Bool) -> String {
            (0..<count).map { i in
                changed && i % 7 == 0
                    ? "    let value\(i) = compute(\(seed), \(i * 3)) // changed in this branch, a longer line to wrap"
                    : "    let value\(i) = compute(\(seed), \(i))"
            }.joined(separator: "\n") + "\n"
        }
        let folders = (0..<25).map { "packages/service\($0)/src/handlers" }
        for (index, folder) in folders.enumerated() {
            let dir = repo.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<10 {
                try? body(index * 10 + file, 40, changed: false).write(
                    to: dir.appendingPathComponent("handler\(file).swift"), atomically: true, encoding: .utf8)
            }
        }
        try? body(9999, 3000, changed: false).write(to: repo.appendingPathComponent("big.swift"), atomically: true, encoding: .utf8)
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        for (index, folder) in folders.enumerated() {
            for file in 0..<10 {
                try? body(index * 10 + file, 40, changed: true).write(
                    to: repo.appendingPathComponent(folder).appendingPathComponent("handler\(file).swift"), atomically: true, encoding: .utf8)
            }
        }
        try? body(9999, 3000, changed: true).write(to: repo.appendingPathComponent("big.swift"), atomically: true, encoding: .utf8)
        try? await git(["commit", "-q", "-am", "change"], in: repo)
        let head = ((try? await Git.run(["rev-parse", "HEAD"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let opened = Date()
        let review = app.openReview(.commits(from: head, to: head), in: repo)
        let loaded = await eventually(20) { review.phase == .loaded && review.selected.map { review.diffs[$0] != nil } == true }
        note("review of \(review.files.count) files ready in \(Int(Date().timeIntervalSince(opened) * 1000)) ms")
        check("a big review loads", loaded && review.files.count == 251, "\(review.phase) \(review.files.count)")
        await pause(0.5)

        // The file list, top to bottom.
        let list = await measureScroll(width: { $0 < 400 }, label: "file list")
        check("the file list scrolls in under 16 ms a step at worst (p95)", list.p95 < 16, "\(list)")

        // Picking files while the next ones load.
        var picks: [Double] = []
        for path in review.files.prefix(30).map(\.path) {
            let start = CACurrentMediaTime()
            review.select(path)
            app.reviewView?.layoutSubtreeIfNeeded()
            app.reviewView?.displayIfNeeded()
            picks.append((CACurrentMediaTime() - start) * 1000)
            await pause(0.02)
        }
        let pick = Self.summary(picks)
        note("picking a file: \(pick)")
        check("picking a file draws in under 50 ms (p95)", pick.p95 < 50, "\(pick)")

        // A 3,000-line file's diff, both ways.
        review.select("big.swift")
        _ = await eventually(10) { review.diffs["big.swift"] != nil }
        await pause(0.5)
        for layout in [ReviewModel.Layout.split, .unified] {
            review.layout = layout
            await pause(0.5)
            let diff = await measureScroll(width: { $0 >= 400 }, label: "diff (\(layout.rawValue))")
            check("a long diff scrolls in under 16 ms a step at worst (p95, \(layout.rawValue))", diff.p95 < 16, "\(diff)")
        }
        app.closeReview(review)
    }

    struct Timing: CustomStringConvertible {
        let median: Double
        let p95: Double
        let max: Double
        var description: String { String(format: "median %.1f ms, p95 %.1f ms, max %.1f ms", median, p95, max) }
    }

    static func summary(_ samples: [Double]) -> Timing {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return Timing(median: 0, p95: 0, max: 0) }
        return Timing(median: sorted[sorted.count / 2], p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], max: sorted.last!)
    }

    /// Scrolls the page's scroll view that `width` picks, a screen's third
    /// a step, top to bottom, each step laid out and drawn.
    private func measureScroll(width: (CGFloat) -> Bool, label: String) async -> Timing {
        guard let page = app.reviewView else { return Timing(median: 0, p95: 0, max: 0) }
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden { scrollViews.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(page)
        guard let scroll = scrollViews.filter({ width($0.frame.width) }).max(by: { $0.frame.height < $1.frame.height }) else {
            note("\(label): no scroll view (\(scrollViews.map(\.frame)))")
            return Timing(median: 0, p95: 0, max: 0)
        }
        var samples: [Double] = []
        var y: CGFloat = 0
        for _ in 0..<400 {
            let height = scroll.documentView?.frame.height ?? 0
            let visible = scroll.contentView.bounds.height
            guard y + visible < height else { break }
            y += visible / 3
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            page.layoutSubtreeIfNeeded()
            page.displayIfNeeded()
            samples.append((CACurrentMediaTime() - start) * 1000)
            // Let SwiftUI's own updates run between steps, as frames would.
            await Task.yield()
        }
        let timing = Self.summary(samples)
        note("\(label): \(samples.count) steps, \(timing)")
        return timing
    }
}
