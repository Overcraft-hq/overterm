import SwiftUI

/// What a press on the Start card asks of the window. Every one goes
/// through the window (`TerminalWindowController.performStartAction`),
/// which runs it and keeps the keyboard out of the card.
package enum StartCardAction: Equatable {
    /// The chevron, or the collapsed row.
    case toggle
    /// × or Done: put away for good.
    case close
    case turnOffTips
    /// The second step's Check Again: the probe asked again.
    case checkAgain
    /// New Task's agent picked: an agent's raw value, or "shell".
    case chooseAgent(String)
    /// A done-state tick.
    case setPanel(SidebarPanel, Bool)
    /// The hidden panels' Show: those a fresh install hid, on again.
    case showHidden
    /// A Settings page: the theme line's Change….
    case settings(SettingsSection)
    /// A step's button: the command it is, as its menu item runs it.
    case command(String)
}

/// The Start card at the foot of the sidebar's panel column (onboarding
/// 7.3): open — what the app is and the five steps —, collapsed to one
/// row, or done — the panels to keep. Hidden with the sidebar, and
/// nothing at all while `Start` says it isn't shown.
///
/// It never takes the keyboard by itself: no focus on appearing, no
/// timer, no animation but the system's. A press runs the menu item's own
/// action through `perform`; the keyboard lands where that action leaves
/// it. Its colours are the window's theme's, its sizes `ChromeMetrics`'.
/// It observes `Start` and the theme — never all of `Settings.shared` —
/// and the keys, so a rebinding shows at once.
package struct StartCardView: View {
    @ObservedObject private var start: Start
    @ObservedObject private var theme: ChromeTheme
    @ObservedObject private var keys: Keybindings
    private let inRepository: Bool
    /// The sidebar's column is open: the second step asks the login shell
    /// only then — a collapsed column's card is never seen.
    private let columnOpen: Bool
    /// Some tab of this window needs you: the fourth step offers Open
    /// Inbox, which opens this window's Inbox — another window's marks
    /// aren't in it.
    private let anyNeedsYou: Bool
    /// 40% of the sidebar's height: past it, the card scrolls inside itself.
    private let maxHeight: CGFloat
    private let perform: (StartCardAction) -> Void
    @State private var contentHeight: CGFloat = 0

    package init(
        start: Start, theme: ChromeTheme, keys: Keybindings = .shared, inRepository: Bool, maxHeight: CGFloat, columnOpen: Bool = true,
        anyNeedsYou: Bool = false, perform: @escaping (StartCardAction) -> Void
    ) {
        self._start = ObservedObject(wrappedValue: start)
        self._theme = ObservedObject(wrappedValue: theme)
        self._keys = ObservedObject(wrappedValue: keys)
        self.inRepository = inRepository
        self.columnOpen = columnOpen
        self.anyNeedsYou = anyNeedsYou
        self.maxHeight = maxHeight
        self.perform = perform
    }

    package var body: some View {
        if start.active, start.state.isShown {
            VStack(spacing: 0) {
                Rectangle().fill(theme.border).frame(height: 1)
                if start.state.card == .collapsed {
                    collapsed
                } else {
                    ScrollView(.vertical) {
                        Group {
                            if start.state.allDone { doneCard } else { openCard }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geometry in Color.clear.preference(key: StartCardHeightKey.self, value: geometry.size.height) })
                    }
                    .frame(height: min(max(contentHeight, 1), max(maxHeight, 80)))
                    .onPreferenceChange(StartCardHeightKey.self) { value in
                        MainActor.assumeIsolated { if abs(value - contentHeight) >= 1 { contentHeight = value } }
                    }
                }
            }
            .background(theme.card)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Getting Started")
            .accessibilityIdentifier("start.card")
        }
    }

    private var text: StartText {
        var bound: [String: String] = [:]
        for id in StartText.commands {
            if let key = KeyHints.key(id, keys: keys) { bound[id] = key }
        }
        return StartText(keys: bound)
    }

    private var facts: StartText.Facts {
        StartText.Facts(inRepository: inRepository, setup: start.setup, taskAgent: start.taskAgent, anyNeedsYou: anyNeedsYou)
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button {
            perform(.toggle)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: StartText.collapsed(start.state))
                    .font(.system(size: ChromeMetrics.text(11.5)))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up").font(.system(size: ChromeMetrics.text(9), weight: .semibold)).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StartText.collapsed(start.state))
        .accessibilityHint("Shows the steps")
        .accessibilityIdentifier("start.collapsed")
    }

    // MARK: Open

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(StartText.title, identifier: "start.title", collapsible: true)
            VStack(alignment: .leading, spacing: 2) {
                line(StartText.pitch, color: theme.text)
                line(StartText.privacy, color: theme.text3)
            }
            hiddenPanels
            VStack(alignment: .leading, spacing: 6) {
                ForEach(StartState.Step.allCases, id: \.self) { step in
                    stepView(step)
                }
            }
            .padding(.top, 2)
            // The foot: "Check Setup · Turn Off Tips" (7.3).
            HStack(spacing: 6) {
                Button(StartText.checkSetup) { perform(.command("help.setup")) }
                    .accessibilityIdentifier("start.foot.checkSetup")
                Text(verbatim: "·").foregroundStyle(theme.text3).accessibilityHidden(true)
                Button(StartText.turnOffTips) { perform(.turnOffTips) }
                    .accessibilityIdentifier("start.turnOffTips")
            }
            .buttonStyle(.plain)
            .font(.system(size: ChromeMetrics.text(11)))
            .foregroundStyle(theme.text3)
        }
    }

    private func header(_ title: String, identifier: String, collapsible: Bool) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: ChromeMetrics.text(12), weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 4)
            if collapsible {
                iconButton("chevron.down", label: "Collapse Getting Started", identifier: "start.chevron") { perform(.toggle) }
            }
            iconButton("xmark", label: StartText.close, identifier: "start.close") { perform(.close) }
        }
    }

    private func iconButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ChromeMetrics.text(9.5), weight: .semibold))
                .foregroundStyle(theme.text3)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func line(_ words: String, color: Color, size: CGFloat = 11) -> some View {
        Text(verbatim: words)
            .font(.system(size: ChromeMetrics.text(size)))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func stepView(_ step: StartState.Step) -> some View {
        let done = start.state.isDone(step)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: ChromeMetrics.text(10.5)))
                    .foregroundStyle(done ? theme.greenText : theme.text3)
                Text(verbatim: StartText.title(of: step))
                    .font(.system(size: ChromeMetrics.text(11.5), weight: step == start.state.current ? .medium : .regular))
                    .foregroundStyle(done ? theme.text2 : theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StartText.title(of: step))
            .accessibilityValue(StartText.accessibilityValue(done: done))
            .accessibilityIdentifier("start.step.\(step.rawValue)")
            // Only the first step not done is open: its line and its control.
            if step == start.state.current {
                VStack(alignment: .leading, spacing: 5) {
                    if step == .agent {
                        agentStep
                    } else {
                        line(text.line(of: step, facts: facts), color: theme.text2)
                        if let button = text.button(of: step, facts: facts) { stepButton(button) }
                    }
                }
                .padding(.leading, ChromeMetrics.text(10.5) + 6)
            }
        }
    }

    private func stepButton(_ button: StartText.StepButton) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(button.title) { perform(.command(button.command)) }
                    .controlSize(.small)
                    .disabled(button.disabledReason != nil)
                    .accessibilityLabel(button.accessibilityLabel)
                    .accessibilityIdentifier("start.button.\(button.command)")
                if let key = button.key {
                    Text(verbatim: key).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).accessibilityHidden(true)
                }
            }
            // Greyed with why, as a verb that can't be done is.
            if let reason = button.disabledReason { line(reason, color: theme.text3, size: 10.5) }
        }
    }

    // MARK: The second step

    @ViewBuilder private var agentStep: some View {
        switch StartText.agentStep(start.setup) {
        case .asking:
            line(StartText.asking, color: theme.text3)
        case .noneFound:
            line(StartText.noAgent, color: theme.orangeText)
            Button(StartText.shellOnly) { perform(.chooseAgent(StartText.shellChoice)) }
                .controlSize(.small)
                .accessibilityIdentifier("start.shellOnly")
        case .noAnswer:
            // Never "Asking…" for good: said, and what can be done now.
            line(StartText.noAnswer, color: theme.orangeText)
            Button(StartText.shellOnly) { perform(.chooseAgent(StartText.shellChoice)) }
                .controlSize(.small)
                .accessibilityIdentifier("start.shellOnly")
        case .choose(let choices):
            line(StartText.newTaskStarts, color: theme.text2)
            Menu {
                ForEach(choices, id: \.value) { choice in
                    Button {
                        perform(.chooseAgent(choice.value))
                    } label: {
                        if choice.value == start.taskAgent {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: choice.title)
                        }
                    }
                }
            } label: {
                Text(verbatim: StartText.choiceTitle(start.taskAgent)).font(.system(size: ChromeMetrics.text(11)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("New Task starts \(StartText.choiceTitle(start.taskAgent))")
            .accessibilityIdentifier("start.agentMenu")
        }
        ForEach(StartText.problems(start.setup), id: \.id) { row in
            line("\(row.title) — \(row.detail)", color: theme.orangeText, size: 10.5)
        }
        if let setup = start.setup {
            if setup.shellAnswered { line(StartText.probeNote, color: theme.text3, size: 10) }
            HStack(spacing: 10) {
                Button(StartText.checkAgain) { perform(.checkAgain) }
                    .accessibilityIdentifier("start.checkAgain")
                // The whole page: every tool, where Overterm looked.
                Button(StartText.checkSetup) { perform(.command("help.setup")) }
                    .accessibilityIdentifier("start.checkSetup")
            }
            .buttonStyle(.plain)
            .font(.system(size: ChromeMetrics.text(10.5)))
            .foregroundStyle(theme.accentText)
        }
        // Asked only while this step shows in an open sidebar column: the
        // login shell's first question may be this one, and it runs the
        // person's rc files. Opening the column asks then.
        Color.clear.frame(height: 0)
            .task(id: columnOpen) {
                if columnOpen { start.probe() }
            }
    }

    // MARK: Done

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(StartText.doneTitle, identifier: "start.doneTitle", collapsible: false)
            line(text.doneLine, color: theme.text2)
            hiddenPanels
            line(StartText.whatYouUse, color: theme.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(SidebarPanel.allCases.filter { $0.toggleKey != nil }) { panel in
                    Toggle(
                        isOn: Binding(get: { start.panels[panel] ?? true }, set: { on in perform(.setPanel(panel, on)) })
                    ) {
                        Text(verbatim: panel.title).font(.system(size: ChromeMetrics.text(11))).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("start.panel.\(panel.rawValue)")
                }
            }
            themeLine
            Button(StartText.done) { perform(.close) }
                .controlSize(.small)
                .accessibilityIdentifier("start.done")
        }
    }

    // MARK: A fresh install's own

    /// "Docker, Kubernetes hidden — not found on this Mac · Show": the
    /// panels a fresh install hid while they are still off. Show turns them
    /// on; the done state's ticks list them as every other.
    @ViewBuilder private var hiddenPanels: some View {
        if let words = FreshInstall.hiddenLine(start.stillHidden) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                line(words, color: theme.text2, size: 10.5)
                    .accessibilityIdentifier("start.hiddenPanels")
                Button(FreshInstall.show) { perform(.showHidden) }
                    .buttonStyle(.plain)
                    .font(.system(size: ChromeMetrics.text(10.5)))
                    .foregroundStyle(theme.accentText)
                    .accessibilityLabel("Show \(start.stillHidden.map(\.title).joined(separator: ", "))")
                    .accessibilityIdentifier("start.showHidden")
            }
        }
    }

    /// "Theme: … · Change…": the theme in force, and Settings ▸ Themes.
    private var themeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            line(StartText.themeLine(start.theme), color: theme.text2, size: 10.5)
                .accessibilityIdentifier("start.theme")
            Button(StartText.changeTheme) { perform(.settings(.themes)) }
                .buttonStyle(.plain)
                .font(.system(size: ChromeMetrics.text(10.5)))
                .foregroundStyle(theme.accentText)
                .accessibilityLabel("Change the theme")
                .accessibilityIdentifier("start.changeTheme")
        }
    }
}

private struct StartCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
