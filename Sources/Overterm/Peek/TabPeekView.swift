import AppKit
import SwiftUI

/// What the peek draws over the terminals: the dim, the group title, and
/// one title bar and border per card. The terminals themselves are the real,
/// live `SplitHostView`s underneath — this layer never draws their content,
/// it only frames them, from the very same rectangles (`TabPeek.placements`)
/// the controller gave their layers.
@MainActor
package final class TabPeekModel: ObservableObject {
    package init() {}

    /// What a card's title bar shows. Taken from the tab, not from a
    /// process scan: the peek has to keep up with a finger.
    package struct Entry: Equatable {
        package let title: String
        package let color: TabColor?
        package let activity: TabActivity
        package let agent: Agent?
        package let panes: Int
        /// The checkout it works in (its folder's name — a worktree's is its branch's).
        package let checkout: String?
        /// A waiting agent's question with its choices, as the Inbox reads it.
        package var prompt: AgentPrompt?

        package init(
            title: String, color: TabColor?, activity: TabActivity, agent: Agent?, panes: Int, checkout: String? = nil, prompt: AgentPrompt? = nil
        ) {
            self.title = title
            self.color = color
            self.activity = activity
            self.agent = agent
            self.panes = panes
            self.checkout = checkout
            self.prompt = prompt
        }

        /// Whether `query` finds it: its title, its checkout or its agent,
        /// the palette's matching (PEEK-U1).
        package func matches(_ query: String) -> Bool {
            guard !query.isEmpty else { return true }
            return [title, checkout, agent?.name].compactMap { $0 }.contains { FuzzyMatch.score(query, in: $0) != nil }
        }
    }

    @Published package var cards: [TabPeek.Card] = []
    @Published package var entries: [Tab.ID: Entry] = [:]
    /// What Return would choose, and where the arrow keys are.
    @Published package var highlighted: Tab.ID?
    @Published package var progress: Double = 0
    /// The checkout the tabs belong to, above the grid.
    @Published package var group: String = ""
    /// What has been typed: the cards it doesn't find are dimmed where they
    /// are — none moves (PEEK-U1).
    @Published package var query = ""

    package func matches(_ id: Tab.ID) -> Bool { entries[id]?.matches(query) ?? query.isEmpty }

    /// The cards the arrows and the digits reach: those the query finds, in place order.
    package var shownCards: [TabPeek.Card] { cards.filter { matches($0.id) } }
}

package struct TabPeekView: View {
    @ObservedObject package var model: TabPeekModel
    @ObservedObject package var theme: ChromeTheme
    package let onChoose: (Tab.ID) -> Void
    package let onClose: (Tab.ID) -> Void
    package let onAnswer: (Tab.ID, AgentPrompt.Choice) -> Void
    package let onDismiss: () -> Void

    package init(
        model: TabPeekModel, theme: ChromeTheme, onChoose: @escaping (Tab.ID) -> Void, onClose: @escaping (Tab.ID) -> Void,
        onAnswer: @escaping (Tab.ID, AgentPrompt.Choice) -> Void = { _, _ in }, onDismiss: @escaping () -> Void
    ) {
        self._model = ObservedObject(wrappedValue: model)
        self._theme = ObservedObject(wrappedValue: theme)
        self.onChoose = onChoose
        self.onClose = onClose
        self.onAnswer = onAnswer
        self.onDismiss = onDismiss
    }

    /// 0 in the strip, 1 in the grid — the group title and the deeper dim
    /// belong to the second stage.
    private var deep: Double { min(max(model.progress - 1, 0), 1) }

    package var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.2 + 0.25 * deep)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if deep > 0.01 {
                HStack(spacing: 10) {
                    Text(verbatim: model.group)
                        .font(.system(size: ChromeMetrics.text(13), weight: .semibold))
                        .foregroundStyle(theme.text)
                    // What was typed; the keys go to the peek, not a field.
                    Text(verbatim: model.query.isEmpty ? "Type to filter · 1–9 to pick" : "Filter: \(model.query)")
                        .font(.system(size: ChromeMetrics.text(12)))
                        .foregroundStyle(model.query.isEmpty ? theme.dimText : theme.text)
                        .accessibilityIdentifier("tabPeek.query")
                }
                .opacity(deep)
                .padding(.leading, TabPeek.margin)
                .padding(.top, TabPeek.margin)
            }

            ForEach(model.cards, id: \.id) { card in
                TabPeekCard(
                    card: card, entry: model.entries[card.id], theme: theme,
                    isHighlighted: model.highlighted == card.id, isDimmed: !model.matches(card.id), showsChoices: deep > 0.5,
                    onChoose: { onChoose(card.id) }, onClose: { onClose(card.id) }, onAnswer: { onAnswer(card.id, $0) }
                )
                .frame(width: card.frame.width, height: card.frame.height)
                .position(x: card.frame.midX, y: card.frame.midY)
            }
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

/// One card's frame: the title bar above the live terminal, a border
/// around both. The middle stays clear — the terminal shows through.
private struct TabPeekCard: View {
    let card: TabPeek.Card
    let entry: TabPeekModel.Entry?
    @ObservedObject var theme: ChromeTheme
    let isHighlighted: Bool
    /// Not found by what was typed: dimmed where it is.
    let isDimmed: Bool
    /// In the grid, a waiting card offers its question's answers.
    let showsChoices: Bool
    let onChoose: () -> Void
    let onClose: () -> Void
    let onAnswer: (AgentPrompt.Choice) -> Void
    @State private var hovering = false

    private var radius: CGFloat { TabPeek.cornerRadius }

    var body: some View {
        VStack(spacing: 0) {
            if card.hasHeader { header }
            // Over the live terminal: a fill dims it without moving it.
            Color.black.opacity(isDimmed ? 0.6 : 0)
            if showsChoices, !isDimmed, let prompt = entry?.prompt, !prompt.choices.isEmpty { choices(prompt) }
        }
        .background(
            // Only behind the title bar: a fill over the whole card would
            // hide the terminal it is framing.
            VStack(spacing: 0) {
                if card.hasHeader {
                    theme.strip.frame(height: TabPeek.headerHeight)
                }
                Color.clear
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(border, lineWidth: isHighlighted ? 2 : 1)
        )
        .shadow(color: .black.opacity(card.hasHeader ? 0.35 : 0), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onChoose)
    }

    /// The question's answers, as the Inbox offers them: one typed into the
    /// pane that asked, after its screen is read again.
    private func choices(_ prompt: AgentPrompt) -> some View {
        HStack(spacing: 4) {
            ForEach(prompt.choices.prefix(4), id: \.key) { choice in
                Button {
                    onAnswer(choice)
                } label: {
                    Text(verbatim: "\(choice.key) \(choice.label)")
                        .font(.system(size: ChromeMetrics.text(10), weight: choice.isDefault ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: ChromeMetrics.row(20))
                        .background(Capsule().fill(choice.isDefault ? TabStatusStyle.signal.opacity(0.35) : theme.strip))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text)
                .help(choice.label)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(theme.strip.opacity(0.92))
        .accessibilityIdentifier("tabPeek.choices")
    }

    private var border: Color {
        if isHighlighted { return TabStatusStyle.signal.opacity(0.9) }
        if entry?.activity.mark == .waiting { return TabStatusStyle.signal.opacity(0.7) }
        return theme.dimText.opacity(hovering ? 0.5 : 0.22)
    }

    private var header: some View {
        HStack(spacing: 5) {
            status.frame(width: 13)
            if let color = entry?.color { Circle().fill(color.color).frame(width: 6, height: 6) }
            Text(verbatim: entry?.title ?? "")
                .font(.system(size: ChromeMetrics.text(11), weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if let panes = entry?.panes, panes > 1 {
                Image(systemName: "rectangle.split.2x1").font(.system(size: ChromeMetrics.text(9))).foregroundStyle(theme.dimText)
            }
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(9), weight: .semibold)).foregroundStyle(theme.dimText)
                }
                .buttonStyle(.plain)
                .help("Close this tab")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: TabPeek.headerHeight)
    }

    @ViewBuilder private var status: some View {
        if let activity = entry?.activity {
            if activity.mark == .waiting {
                WaitingDot()
            } else if activity.isWorking {
                WorkingGlyph(symbol: entry?.agent?.symbol ?? "terminal", size: 10)
            } else if activity.mark == .failed || activity.mark == .done {
                ResultMark(failed: activity.mark == .failed, size: 10)
            } else {
                Image(systemName: entry?.agent?.symbol ?? "terminal").font(.system(size: ChromeMetrics.text(9))).foregroundStyle(theme.dimText)
            }
        }
    }
}

/// The peek's host: it takes the keyboard while shown, so Esc closes it and
/// the arrows move between cards (there is no text field to catch them). It
/// also keeps receiving the trackpad, so a swipe that started on a terminal
/// carries on once the peek is over it.
package final class TabPeekHostingView<Content: View>: NSHostingView<Content> {
    package var onEscape: (() -> Void)?
    package var onKey: ((NSEvent) -> Bool)?
    /// `(fingers, averageY, ended)`; see TabPeekGesture.
    package var onTouches: ((Int, CGFloat, Bool) -> Void)?

    package override var acceptsFirstResponder: Bool { true }

    package override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    package override func cancelOperation(_ sender: Any?) { onEscape?() }

    // MARK: The trackpad

    package override func touchesBegan(with event: NSEvent) { report(event, ended: false) }
    package override func touchesMoved(with event: NSEvent) { report(event, ended: false) }
    package override func touchesEnded(with event: NSEvent) { report(event, ended: true) }
    package override func touchesCancelled(with event: NSEvent) { report(event, ended: true) }

    private func report(_ event: NSEvent, ended: Bool) {
        let touches = event.touches(matching: .touching, in: self)
        onTouches?(touches.count, TabPeekTouches.averageY(touches), ended)
    }
}

/// Reading a touch set, kept apart from the views so both the terminal and
/// the peek report the same thing.
package enum TabPeekTouches {
    package static func averageY(_ touches: Set<NSTouch>) -> CGFloat {
        guard !touches.isEmpty else { return 0 }
        return touches.reduce(0) { $0 + $1.normalizedPosition.y } / CGFloat(touches.count)
    }
}
