import AppKit
import QuartzCore

/// Tab peek: three fingers down the trackpad (or ⇧⌘E) and every tab's
/// terminal comes into view — first as a row under the tab strip with the
/// selected terminal pushed down below it, then, if the fingers carry on,
/// as a grid.
///
/// The previews are the real terminals. Each tab's `SplitHostView` already
/// fills the container; the peek only puts a `CATransform3D` on its layer,
/// which moves pixels without touching a single frame — so no surface is
/// ever resized and nothing reflows. Splits come along for free, since what
/// is being scaled is the host that lays them out.
@MainActor
final class TabPeekController {
    let model = TabPeekModel()
    private(set) var stage: TabPeek.Stage = .closed
    var isOpen: Bool { stage != .closed }
    /// Closed, but the hosts are still flying back to their place. Until
    /// they land they all have to keep rendering, or the animation blinks.
    private(set) var isSettling = false

    private unowned let container: NSView
    weak var owner: TerminalWindowController?
    /// The dim, the group title and the cards' title bars, over the hosts.
    weak var chrome: TabPeekHostingView<TabPeekView>?

    private var gesture = TabPeekGesture()
    /// Panes past `TabPeek.liveLimit` stay occluded and are drawn by hand,
    /// so twenty tabs don't all run their renderer at full rate.
    private var slowPanes: [TerminalView] = []
    private var slowDraw: Timer?

    /// How long the peek takes to settle after the fingers leave.
    static let settle: TimeInterval = 0.18
    private static let slowFrameRate: TimeInterval = 1.0 / 6

    init(container: NSView) {
        self.container = container
    }

    // MARK: Opening and closing

    /// ⇧⌘E and the palette: straight to the grid, or back out.
    func toggle() {
        guard let owner, owner.store.tabs.count > 1 || isOpen else { return }
        isOpen ? close() : open(.overview)
    }

    func open(_ stage: TabPeek.Stage) {
        guard stage != .closed else { return close() }
        guard let owner, !owner.store.tabs.isEmpty else { return }
        // The stage first: `begin` installs the key monitor, which only
        // arms itself while the peek counts as open.
        let wasClosed = self.stage == .closed
        self.stage = stage
        if wasClosed { begin() }
        gesture.settled(at: stage)
        apply(progress: stage.progress, animated: true)
    }

    func close() {
        guard isOpen else { return }
        stage = .closed
        isSettling = true
        gesture.settled(at: .closed)
        stopSlowDraw()
        apply(progress: 0, animated: true)
        chrome?.isHidden = true
        model.cards = []
        model.progress = 0
        owner?.installPeekKeys()
        // Let the hosts fly back before their occlusion is taken away: hiding
        // them mid-animation would blink.
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stage == .closed, self.generation == generation else { return }
                self.isSettling = false
                self.resetLayers()
                self.owner?.applyTabVisibility()
            }
        }
        owner?.focusSelectedTerminal()
    }

    /// Bumped on every open so a close that is undone before its animation
    /// ends doesn't tear down the peek that followed it.
    private var generation = 0

    private func begin() {
        generation &+= 1
        isSettling = false
        // Since macOS 14 a view doesn't clip; without this the pushed-down
        // terminal paints over the editor and changes panes beside it.
        container.clipsToBounds = true
        model.highlighted = owner?.store.selectedID
        refreshEntries()
        showPanes()
        guard let chrome else { return }
        chrome.isHidden = false
        chrome.superview?.addSubview(chrome, positioned: .above, relativeTo: nil)
        owner?.window?.makeFirstResponder(chrome)
        owner?.installPeekKeys()
    }

    // MARK: The gesture

    /// A terminal or the peek itself reporting the trackpad.
    func touched(fingers: Int, y: CGFloat, ended: Bool) {
        let required = Settings.shared.tabPeekGesture.count
        guard required > 0 else { return }
        let outcome = ended ? gesture.ended() : gesture.touched(count: fingers, y: y, required: required)
        switch outcome {
        case .none:
            break
        case .update(let progress):
            if !isOpen {
                guard let owner, owner.store.tabs.count > 1 else { return }
                stage = .peek
                begin()
            }
            apply(progress: progress, animated: false)
        case .settle(let stage):
            if stage == .closed {
                close()
            } else {
                self.stage = stage
                apply(progress: stage.progress, animated: true)
            }
        }
    }

    /// Whether a swipe should be taken from the terminal rather than sent on
    /// to libghostty. Only the configured finger count is ours; two-finger
    /// scrolling stays the terminal's.
    func wantsTouches(_ count: Int) -> Bool {
        let required = Settings.shared.tabPeekGesture.count
        return required > 0 && (count == required || isOpen)
    }

    // MARK: The keyboard

    /// Returns true when the key was the peek's.
    func handle(key event: NSEvent) -> Bool {
        guard isOpen, let highlighted = model.highlighted else { return false }
        let direction: TabPeek.Direction?
        switch Int(event.keyCode) {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: direction = nil
        }
        if let direction {
            model.highlighted = TabPeek.move(direction, from: highlighted, in: model.cards)
            return true
        }
        switch event.charactersIgnoringModifiers {
        case "\r", " ":
            choose(highlighted)
            return true
        case "\t":
            model.highlighted = TabPeek.step(event.modifierFlags.contains(.shift) ? -1 : 1, from: highlighted, in: model.cards)
            return true
        default:
            return false
        }
    }

    func choose(_ id: Tab.ID) {
        guard let tab = owner?.store.tabs.first(where: { $0.id == id }) else { return }
        close()
        owner?.store.select(tab)
        owner?.focusSelectedTerminal()
    }

    func closeTab(_ id: Tab.ID) {
        guard let owner, let tab = owner.store.tabs.first(where: { $0.id == id }) else { return }
        // Closing may ask; the peek would be in the sheet's way.
        close()
        owner.closeTab(tab)
    }

    // MARK: Peeking into one collapsed island

    /// Hovering a collapsed group's chip shows that group's terminals as a
    /// row, live, without opening the full peek. Nil ends it.
    func peekGroup(_ tabs: [Tab]?) {
        guard stage == .closed || groupPeek != nil else { return }
        if let tabs, !tabs.isEmpty {
            if groupPeek == nil {
                container.clipsToBounds = true
                refreshEntries()
                chrome?.isHidden = false
                chrome?.superview?.addSubview(chrome!, positioned: .above, relativeTo: nil)
            }
            let first = groupPeek == nil
            groupPeek = tabs.map(\.id)
            for tab in tabs { owner?.host(of: tab)?.setVisible(true) }
            applyGroupPeek(animated: first)
        } else {
            guard groupPeek != nil else { return }
            groupPeek = nil
            chrome?.isHidden = true
            model.cards = []
            model.progress = 0
            resetLayers()
            owner?.applyTabVisibility()
        }
    }

    /// The tabs of the island being hovered, if any.
    private(set) var groupPeek: [Tab.ID]?

    private func applyGroupPeek(animated: Bool) {
        guard let ids = groupPeek else { return }
        let bounds = container.bounds
        let cards = TabPeek.row(tabs: ids, in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        for card in cards {
            guard let tab = owner?.store.tabs.first(where: { $0.id == card.id }),
                let host = owner?.host(of: tab)
            else { continue }
            host.peekTransform = TabPeek.transform(from: bounds, to: card.content)
            host.layer?.masksToBounds = true
            host.layer?.cornerRadius = bounds.width > 0 ? TabPeek.cornerRadius / (card.content.width / bounds.width) : 0
            host.layer?.minificationFilter = .trilinear
        }
        CATransaction.commit()
        model.progress = 1
        model.cards = cards
    }

    // MARK: Laying the hosts out

    /// Puts every host where `progress` says, by transform only.
    func apply(progress: Double, animated: Bool) {
        guard let owner else { return }
        let bounds = container.bounds
        let cards = TabPeek.placements(
            tabs: owner.store.tabs.map(\.id), selected: owner.store.selectedID,
            progress: progress, in: bounds)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(Self.settle)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        for card in cards {
            guard let tab = owner.store.tabs.first(where: { $0.id == card.id }),
                let host = owner.host(of: tab), let layer = host.layer
            else { continue }
            // No flip: the host's layer has its geometry flipped (the view
            // is), so its own origin is the container's top-left — which is
            // where the placements are measured from too.
            let target = card.content
            // Through the host, which puts it back whenever AppKit's layout
            // resets the layer (SplitHostView.peekTransform).
            host.peekTransform = TabPeek.transform(from: bounds, to: target)
            let scale = bounds.width > 0 ? target.width / bounds.width : 1
            layer.cornerRadius = scale > 0 ? TabPeek.cornerRadius / scale : 0
            layer.masksToBounds = true
            layer.minificationFilter = .trilinear
        }
        CATransaction.commit()

        model.progress = progress
        model.cards = cards
    }

    /// The window resized, or a tab came or went, while the peek is up.
    func relayout() {
        guard isOpen else { return }
        refreshEntries()
        showPanes()
        apply(progress: stage.progress, animated: false)
    }

    private func resetLayers() {
        for tab in owner?.store.tabs ?? [] {
            guard let host = owner?.host(of: tab), let layer = host.layer else { continue }
            host.peekTransform = CATransform3DIdentity
            layer.masksToBounds = false
            layer.cornerRadius = 0
        }
    }

    // MARK: What renders while the peek is up

    private func showPanes() {
        guard let owner else { return }
        stopSlowDraw()
        var live = 0
        for tab in owner.store.tabs {
            guard let host = owner.host(of: tab) else { continue }
            if live < TabPeek.liveLimit {
                // Un-occluding draws a frame at once, so the card is current
                // and not the one left over from when the tab was hidden.
                host.setVisible(true)
                live += tab.terminals.count
            } else {
                host.setPreviewing(true)
                slowPanes.append(contentsOf: tab.terminals)
            }
        }
        guard !slowPanes.isEmpty else { return }
        slowPanes.forEach { $0.drawNow() }
        slowDraw = Timer.scheduledTimer(withTimeInterval: Self.slowFrameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowPanes.forEach { $0.drawNow() } }
        }
    }

    private func stopSlowDraw() {
        slowDraw?.invalidate()
        slowDraw = nil
        slowPanes = []
    }

    private func refreshEntries() {
        guard let owner else { return }
        model.entries = Dictionary(
            uniqueKeysWithValues: owner.store.tabs.map {
                ($0.id, TabPeekModel.Entry(title: $0.title, color: $0.color, activity: $0.activity, agent: $0.agent, panes: $0.terminals.count))
            })
        model.group = owner.store.selected?.checkoutSource.map { $0.root.lastPathComponent } ?? "Tabs"
    }
}
