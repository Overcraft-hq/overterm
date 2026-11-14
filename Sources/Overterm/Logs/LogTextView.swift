import AppKit
import SwiftUI

/// Lines of text in an AppKit text view — a log, an inspect's JSON, an
/// object's YAML. A
/// SwiftUI list of thousands of lines doesn't scroll; a text view also
/// selects across lines and copies. New lines are appended rather than the
/// whole text set again, and the view keeps to the bottom while it was
/// there (`follow`).
struct LogTextView: NSViewRepresentable {
    /// How many lines there are, and the ones in a range, drawn — only the
    /// new ones are drawn as a log grows. `revision` changes when the text
    /// is something other than the old one with lines added (a filter, a
    /// cleared log).
    let count: Int
    let revision: Int
    let render: (Range<Int>) -> [NSAttributedString]
    var wrap = true
    var follow = true
    /// Lines picked out of it, to an agent (⌘L, its right-click menu): a
    /// log's; nil for what isn't one (Inspect's JSON, a build's log).
    var ask: ((String) -> Void)? = nil
    /// The text view's accessibility identifier, which the scenarios find
    /// it by: Docker's page's are `docker.text`.
    var identifier = "log.text"
    /// The newest line on top: new lines go in above, and the view keeps
    /// to the top while it was there.
    var newestFirst = false
    /// Bumped when older lines went in before the others (`LogFeed.prepended`):
    /// the text is drawn again, the line read kept in its place.
    var prepended = 0
    /// Scrolled to the oldest line (the top; the bottom, newest first):
    /// older ones may be asked for. Nil: nothing older to ask for.
    var onOldest: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView { Self.makeScroll(identifier: identifier) }

    /// The scroll view and its text view, as `makeNSView` makes them.
    static func makeScroll(identifier: String) -> NSScrollView {
        // The class method makes the subclass's text view.
        let scroll = LogLinesTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.allowsUndo = false
        text.layoutManager?.allowsNonContiguousLayout = true
        text.setAccessibilityIdentifier(identifier)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(scroll, self) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// What the view has drawn, and whether it keeps to its newest edge.
    ///
    /// Whether it follows is a state of its own (`pinned`), which only a
    /// person's scroll changes — the wheel or a trackpad, a scroller, a
    /// key, a selection dragged past the edge — never worked out again from
    /// the geometry as lines come in. A
    /// view made with its first lines isn't laid out in its window yet (no
    /// size, then one SwiftUI changes again), a loaded machine lays it out
    /// after any one turn of the main queue, and the text's non-contiguous
    /// layout moves the clip by itself as it measures what it had
    /// estimated: worked out from the frames, the view stopped following
    /// in the middle of a busy pod's log. So while pinned, whatever moves
    /// or resizes the text but a person scrolls it to its newest edge again.
    /// A person's scroll is told by the scroll view's live-scroll
    /// notifications (a trackpad, its momentum, a scroller; a legacy
    /// mouse's wheel is a `didLiveScroll` alone) and by the text view's own
    /// keys and presses — never by overriding `scrollWheel`, which would
    /// take the text off responsive scrolling. While one goes on, lines
    /// coming in never pull the view back; where it ends settles the follow.
    @MainActor
    final class Coordinator {
        var shown = 0
        var revision = -1
        var prepended = 0
        var drawnNewestFirst = false
        var newestFirst = false
        var follow = true
        /// Kept to the newest edge (the bottom; the top, newest first).
        private(set) var pinned = true
        var onOldest: (() -> Void)?
        /// The text is being set or scrolled by the view: not a person's scroll.
        var moving = false
        private var wasAtOldest = false
        /// A person is scrolling: a live scroll, or a wheel's or a key's event being handled.
        private var live = false
        private var person = 0
        private var settling = false
        private var snapping = false
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private weak var scroll: NSScrollView?

        func update(_ scroll: NSScrollView, _ view: LogTextView) {
            (scroll.documentView as? LogLinesTextView)?.ask = view.ask
            (scroll.documentView as? LogLinesTextView)?.coordinator = self
            guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
            view.setWrap(view.wrap, scroll, text)
            onOldest = view.onOldest
            newestFirst = view.newestFirst
            follow = view.follow
            watch(scroll)
            let clip = scroll.contentView.bounds
            let height = scroll.documentView?.frame.height ?? 0
            let fromBottom = height - clip.minY
            // A person scrolling: nothing pulls the view back meanwhile.
            let scrolling = live || person > 0
            let reset = revision != view.revision || view.count < shown || drawnNewestFirst != view.newestFirst
            // Older lines came in: drawn again, but the line read stays put.
            let older = reset && prepended != view.prepended && revision != -1 && drawnNewestFirst == view.newestFirst
            moving = true
            defer { moving = false }
            if reset {
                storage.setAttributedString(LogTextView.joined(view.render(0..<view.count), reversed: view.newestFirst))
                revision = view.revision
                drawnNewestFirst = view.newestFirst
            } else if view.count > shown {
                let added = LogTextView.joined(view.render(shown..<view.count), reversed: view.newestFirst)
                if view.newestFirst {
                    if storage.length > 0 { storage.insert(NSAttributedString(string: "\n"), at: 0) }
                    storage.insert(added, at: 0)
                } else {
                    if storage.length > 0 { storage.append(NSAttributedString(string: "\n")) }
                    storage.append(added)
                }
            } else {
                prepended = view.prepended
                return
            }
            shown = view.count
            prepended = view.prepended
            guard follow else { return }
            if older {
                // Older lines went in at the far end: the line read kept.
                if newestFirst {
                    LogTextView.scroll(scroll, text, toY: clip.minY)
                } else {
                    LogTextView.scroll(scroll, text, fromBottom: fromBottom)
                }
            } else if reset || (pinned && !scrolling) {
                pinned = true
                toNewest()
            } else if newestFirst {
                // New lines above, the line read further down kept in view.
                LogTextView.scroll(scroll, text, fromBottom: fromBottom)
            }
            // Pinned or not, a line read further up stays where it is.
        }

        /// Scrolled to the newest edge, and once more after the main queue's
        /// next turn — the window may lay the view out in between.
        private func toNewest() {
            guard let scroll, let text = scroll.documentView as? NSTextView else { return }
            let was = moving
            moving = true
            // Laying out the end can make the text taller (its layout is
            // non-contiguous, the rest estimated): scrolled again until it holds.
            for _ in 0..<3 {
                if newestFirst { text.scrollToBeginningOfDocument(nil) } else { text.scrollToEndOfDocument(nil) }
                if atNewest { break }
            }
            moving = was
            guard !settling else { return }
            settling = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settling = false
                if self.pinned, self.follow, !self.live, self.person == 0, !self.atNewest { self.toNewest() }
            }
        }

        private var atNewest: Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            let clip = scroll.contentView.bounds
            return newestFirst ? clip.minY <= 24 : clip.maxY >= document.frame.height - 24
        }

        /// What a person does to scroll it: followed again only at the
        /// newest edge, let go anywhere else.
        func byPerson(_ body: () -> Void) {
            person += 1
            body()
            person -= 1
            guard person == 0, !live else { return }
            personScrolled()
        }

        private func personScrolled() {
            if follow { pinned = atNewest }
            if let scroll, let document = scroll.documentView { oldest(scroll.contentView.bounds, document) }
        }

        /// The clip's bounds and frame, the text's frame, and a person's
        /// live scroll, watched — the follow, and the oldest edge.
        func watch(_ scroll: NSScrollView) {
            guard observers.isEmpty else { return }
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            // Posted on the main thread, as the views change: run there, at once.
            func on(_ name: Notification.Name, _ object: NSObject?, _ run: @escaping @MainActor (Coordinator) -> Void) {
                observers.append(
                    center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { if let self { run(self) } }
                    })
            }
            on(NSView.boundsDidChangeNotification, scroll.contentView) { $0.changed() }
            on(NSView.frameDidChangeNotification, scroll.contentView) { $0.changed() }
            on(NSView.frameDidChangeNotification, scroll.documentView) { $0.changed() }
            on(NSScrollView.willStartLiveScrollNotification, scroll) { $0.live = true }
            // A legacy mouse's wheel: no start or end, posted after the
            // clip moved — the snap `changed` asked for waits a turn for it.
            on(NSScrollView.didLiveScrollNotification, scroll) {
                if !$0.live, $0.person == 0 { $0.personScrolled() }
            }
            on(NSScrollView.didEndLiveScrollNotification, scroll) {
                $0.live = false
                if $0.person == 0 { $0.personScrolled() }
            }
        }

        private func changed() {
            guard !moving, let scroll, let document = scroll.documentView else { return }
            if follow, pinned, !live, person == 0 {
                // Laid out again, clamped to a new size, moved by the layout
                // or by code: the newest edge kept while it was there — after
                // a turn, as a legacy wheel says it was a person's only once
                // the clip has moved. Not the oldest edge either way: it is
                // left again at once, and nobody scrolled there.
                if !atNewest { snapSoon() }
                return
            }
            oldest(scroll.contentView.bounds, document)
        }

        private func snapSoon() {
            guard !snapping else { return }
            snapping = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.snapping = false
                if self.pinned, self.follow, !self.live, self.person == 0, !self.atNewest { self.toNewest() }
            }
        }

        private func oldest(_ clip: CGRect, _ document: NSView) {
            guard let onOldest else { return }
            // Shorter than the view: nothing was scrolled to.
            guard document.frame.height > clip.height + 8 else { return }
            let atOldest = newestFirst ? clip.maxY >= document.frame.height - 4 : clip.minY <= 4
            defer { wasAtOldest = atOldest }
            if atOldest && !wasAtOldest { onOldest() }
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// The same distance from the end as before: what was read stays in view.
    fileprivate static func scroll(_ scroll: NSScrollView, _ text: NSTextView, fromBottom: CGFloat) {
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        let height = scroll.documentView?.frame.height ?? 0
        Self.scroll(scroll, text, toY: max(0, height - fromBottom))
    }

    fileprivate static func scroll(_ scroll: NSScrollView, _ text: NSTextView, toY y: CGFloat) {
        let height = scroll.documentView?.frame.height ?? 0
        let top = min(max(0, y), max(0, height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func joined(_ lines: [NSAttributedString], reversed: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in (reversed ? lines.reversed() : lines).enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(line)
        }
        return out
    }

    fileprivate func setWrap(_ wrap: Bool, _ scroll: NSScrollView, _ text: NSTextView) {
        guard let container = text.textContainer, container.widthTracksTextView != wrap else { return }
        container.widthTracksTextView = wrap
        text.isHorizontallyResizable = !wrap
        if wrap {
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            text.frame.size.width = scroll.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        scroll.hasHorizontalScroller = !wrap
    }
}

/// A log's text view: lines picked out of it go to an agent, widened to
/// whole lines — ⌘L (Edit's Ask an Agent About the Selection, which
/// reaches it before the terminal hidden under the page) and its
/// right-click menu. Without a selection, or a log, ⌘L goes on up the
/// responder chain: the window then asks about what its page has selected
/// (a container). Who asks scrubs the text (Docker's: `DockerSecrets`).
final class LogLinesTextView: NSTextView {
    var ask: ((String) -> Void)?
    /// Told of a person's scrolls by keys and presses (a selection dragged
    /// past the edge scrolls inside `mouseDown`'s tracking). The wheel and
    /// the trackpad are the scroll view's live-scroll notifications: an
    /// override of `scrollWheel` would take the text off responsive scrolling.
    weak var coordinator: LogTextView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return super.mouseDown(with: event) }
        coordinator.byPerson { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        coordinator.byPerson { super.keyDown(with: event) }
    }

    @objc func askAboutSelection(_ sender: Any?) {
        let range = selectedRange()
        if let ask, range.length > 0 { return ask(Self.wholeLines(of: string, range)) }
        if nextResponder?.tryToPerform(#selector(askAboutSelection(_:)), with: sender) != true { NSSound.beep() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(askAboutSelection(_:)) ? true : super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(askAboutSelection(_:)) ? true : super.validateUserInterfaceItem(item)
    }

    /// A selection widened to the whole lines it touches. Pure.
    nonisolated static func wholeLines(of text: String, _ range: NSRange) -> String {
        let string = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        return string.substring(with: string.lineRange(for: clamped)).trimmingCharacters(in: .newlines)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard ask != nil, selectedRange().length > 0 else { return menu }
        // A copy: the text view's menu may be one it keeps.
        let shown = (menu?.copy() as? NSMenu) ?? NSMenu()
        let item = NSMenuItem(title: "Ask an Agent About These Lines", action: #selector(askAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        shown.insertItem(.separator(), at: 0)
        shown.insertItem(item, at: 0)
        return shown
    }
}
