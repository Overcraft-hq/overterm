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
package final class TabPeekController {
    package let model = TabPeekModel()
    package private(set) var stage: TabPeek.Stage = .closed
    package var isOpen: Bool { stage != .closed }
    /// Closed, but the hosts are still flying back to their place. Until
    /// they land they all have to keep rendering, or the animation blinks.
    package private(set) var isSettling = false

    private unowned let container: NSView
    package weak var owner: TerminalWindowController?
    /// The dim, the group title and the cards' title bars, over the hosts.
    package weak var chrome: TabPeekHostingView<TabPeekView>?

    private var gesture = TabPeekGesture()
    /// Panes past `TabPeek.liveLimit` stay occluded and are drawn by hand,
    /// so twenty tabs don't all run their renderer at full rate.
    private var slowPanes: [TerminalView] = []
    private var slowDraw: Timer?

    /// How long the peek takes to settle after the fingers leave.
    package static let settle: TimeInterval = 0.18
    private static let slowFrameRate: TimeInterval = 1.0 / 6

    package init(container: NSView) {
        self.container = container
    }

    // MARK: Opening and closing

    /// ⇧⌘E and the palette: straight to the grid, or back out.
    package func toggle() {
        guard let owner, owner.store.drawnTabs.count > 1 || isOpen else { return }
        isOpen ? close() : open(.overview)
    }

    package func open(_ stage: TabPeek.Stage) {
        guard stage != .closed else { return close() }
        guard let owner, !owner.store.drawnTabs.isEmpty else { return }
        // The stage first: `begin` installs the key monitor, which only
        // arms itself while the peek counts as open.
        let wasClosed = self.stage == .closed
        self.stage = stage
        if wasClosed { begin() }
        gesture.settled(at: stage)
        apply(progress: stage.progress, animated: true)
    }

    package func close() {
        guard isOpen else { return }
        stage = .closed
        isSettling = true
        gesture.settled(at: .closed)
        stopSlowDraw()
        apply(progress: 0, animated: true)
        chrome?.isHidden = true
        model.cards = []
        model.progress = 0
        model.query = ""
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
        model.query = ""
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
    package func touched(fingers: Int, y: CGFloat, ended: Bool) {
        let required = Settings.shared.tabPeekGesture.count
        guard required > 0 else { return }
        let outcome = ended ? gesture.ended() : gesture.touched(count: fingers, y: y, required: required)
        switch outcome {
        case .none:
            break
        case .update(let progress):
            if !isOpen {
                guard let owner, owner.store.drawnTabs.count > 1 else { return }
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
    package func wantsTouches(_ count: Int) -> Bool {
        let required = Settings.shared.tabPeekGesture.count
        return required > 0 && (count == required || isOpen)
    }

    // MARK: The keyboard

    /// Returns true when the key was the peek's: the arrows and ⇥ among
    /// the cards the filter finds, ↩ or Space the highlighted one, 1–9 the
    /// nth of them, anything typed the filter, ⌫ its last character (PEEK-U1).
    package func handle(key event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let shown = model.shownCards
        let direction: TabPeek.Direction?
        switch Int(event.keyCode) {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: direction = nil
        }
        if let direction {
            if let highlighted = model.highlighted, shown.contains(where: { $0.id == highlighted }) {
                model.highlighted = TabPeek.move(direction, from: highlighted, in: shown)
            } else {
                model.highlighted = shown.first?.id
            }
            return true
        }
        let modifiers = !event.modifierFlags.intersection([.command, .control]).isEmpty
        switch event.charactersIgnoringModifiers {
        case "\r", " ":
            if let highlighted = model.highlighted, shown.contains(where: { $0.id == highlighted }) { choose(highlighted) }
            return true
        case "\t":
            if let highlighted = model.highlighted {
                model.highlighted = TabPeek.step(event.modifierFlags.contains(.shift) ? -1 : 1, from: highlighted, in: shown)
            }
            return true
        case let typed? where !modifiers && typed.count == 1 && ("1"..."9").contains(typed):
            if let nth = Int(typed), shown.indices.contains(nth - 1) { choose(shown[nth - 1].id) }
            return true
        default:
            guard
                let query = GroupSwitcherFilter.query(model.query, typing: event.characters, delete: event.keyCode == 51, modifiers: modifiers)
            else { return event.keyCode == 51 }
            setQuery(query)
            return true
        }
    }

    /// The filter changed: the highlight stays if the card is still found,
    /// else the first card found takes it.
    package func setQuery(_ query: String) {
        model.query = query
        let shown = model.shownCards
        if !shown.contains(where: { $0.id == model.highlighted }) { model.highlighted = shown.first?.id ?? model.highlighted }
    }

    /// Esc: the filter cleared first, then the peek closed.
    package func escape() {
        guard model.query.isEmpty else { return setQuery("") }
        close()
    }

    /// A waiting card's answer: typed into the pane that asked, as the
    /// Inbox's is — its screen read again first, so a question that changed
    /// meanwhile gets nothing. The card keeps no buttons after.
    package func answer(_ choice: AgentPrompt.Choice, on id: Tab.ID) {
        guard let owner, let asked = model.entries[id]?.prompt else { return }
        owner.answer(choice, in: id, asked: asked)
        model.entries[id]?.prompt = nil
    }

    package func choose(_ id: Tab.ID) {
        guard let tab = owner?.store.tabs.first(where: { $0.id == id }) else { return }
        close()
        owner?.store.reveal(tab)
        owner?.focusSelectedTerminal()
    }

    package func closeTab(_ id: Tab.ID) {
        guard let owner, let tab = owner.store.tabs.first(where: { $0.id == id }) else { return }
        // Closing may ask; the peek would be in the sheet's way.
        close()
        owner.closeTab(tab)
    }

    // MARK: Peeking into one collapsed island

    /// Hovering a collapsed group's chip shows that group's terminals as a
    /// row, live, without opening the full peek. Nil ends it.
    package func peekGroup(_ tabs: [Tab]?) {
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
            // Only the island's hosts are scaled into cards, so every other
            // one has to go: the selected tab's host fills the container and
            // would otherwise keep drawing at full size — its text across
            // the cards, the cards' own text inside them, both at once.
            let shown = Set(tabs.map(\.id))
            for tab in owner?.store.tabs ?? [] {
                owner?.host(of: tab)?.setVisible(shown.contains(tab.id))
            }
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
    package private(set) var groupPeek: [Tab.ID]?

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
    package func apply(progress: Double, animated: Bool) {
        guard let owner else { return }
        let bounds = container.bounds
        let cards = TabPeek.placements(
            tabs: owner.store.drawnTabs.map(\.id), selected: owner.store.selectedID,
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
    package func relayout() {
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
        // What the strip draws only (PEEK-U2): a stashed or collapsed island's
        // tabs, or another island's while focusing, stay hidden — hidden here too, as
        // a peek opened again before the last one settled left them shown.
        let offered = owner.store.drawnTabs
        let ids = Set(offered.map(\.id))
        for tab in owner.store.tabs where !ids.contains(tab.id) && tab.id != owner.store.selectedID {
            owner.host(of: tab)?.setVisible(false)
        }
        for tab in offered {
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
            uniqueKeysWithValues: owner.store.drawnTabs.map {
                (
                    $0.id,
                    TabPeekModel.Entry(
                        title: $0.title, color: $0.color, activity: $0.activity, agent: $0.agent, panes: $0.terminals.count,
                        checkout: $0.checkoutSource?.root.lastPathComponent, prompt: owner.askedChoices($0))
                )
            })
        model.group = owner.store.selected?.checkoutSource.map { $0.root.lastPathComponent } ?? "Tabs"
    }
}
