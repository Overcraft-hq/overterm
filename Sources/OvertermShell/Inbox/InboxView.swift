import AppKit
import SwiftUI

/// What the inbox can do to an entry.
package struct InboxActions {
    /// Type a choice's key and Return into that tab's agent.
    package var answer: (Tab.ID, AgentPrompt.Choice) -> Void
    package var open: (Tab.ID) -> Void
    /// Ask Why on a cluster's mark (KubeAttention): the brief to the tab's agent.
    package var askWhy: (Tab.ID) -> Void = { _ in }
    /// Show on a Left Behind note: Activity's Left Behind for the tab.
    package var showLeftBehind: (Tab.ID) -> Void = { _ in }
    /// A CI card's Show Log: the pull request in the pane, the failed logs open.
    package var showCILog: (Tab.ID) -> Void = { _ in }
    /// A CI card's Ask Agent to Fix: the brief typed into the tab's agent, not sent.
    package var fixCI: (Tab.ID) -> Void = { _ in }
    /// Dismiss (X): a finished or failed entry let go of without going to its tab (AGT-U6).
    package var dismiss: (Tab.ID) -> Void = { _ in }
    package var close: () -> Void
}

/// The column of everything waiting on you.
package struct InboxView: View {
    @ObservedObject package var model: InboxModel
    @ObservedObject package var theme: ChromeTheme
    package let actions: InboxActions

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Inbox").font(.system(size: ChromeMetrics.text(13), weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Text("J / K to move · ⌘I to close")
                    .font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if model.isEmpty {
                Spacer()
                Text("Nothing is waiting for you")
                    .font(.system(size: ChromeMetrics.text(12)))
                    .foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.entries) { entry in
                            InboxCard(
                                entry: entry, highlighted: entry.id == model.highlighted, theme: theme,
                                actions: actions)
                        }
                    }
                }
            }
            Text("Also the Dock badge, and the menu bar while something waits.")
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

private struct InboxCard: View {
    let entry: InboxModel.Entry
    let highlighted: Bool
    @ObservedObject var theme: ChromeTheme
    let actions: InboxActions

    private var glyph: (String, Color) {
        if let approval = entry.approval {
            return ("hand.raised.fill", approval.confirmation.production ? WriteConfirmationColors.production : TabStatusStyle.waiting)
        }
        if let ask = entry.terraform { return ("exclamationmark.octagon.fill", ask.isProduction ? TerraformPanelView.production : TabStatusStyle.waiting) }
        switch entry.mark {
        case .waiting: return ("exclamationmark.circle.fill", TabStatusStyle.waiting)
        case .failed: return ("xmark.circle.fill", TabStatusStyle.failed)
        case .done: return ("checkmark.circle.fill", TabStatusStyle.done)
        case .none: return ("circle", theme.text3)
        }
    }

    /// A question gets a card; anything else is a line.
    private var isQuestion: Bool { entry.prompt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: glyph.0).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(glyph.1)
                Text(entry.headline).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 6)
                if let since = entry.since {
                    // Read again every half minute: the list itself isn't redrawn for it.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(verbatim: InboxModel.waited(since: since, now: context.date))
                            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1)
                            .accessibilityIdentifier("inbox.waited")
                    }
                }
                if let group = entry.group {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(group.color.color).frame(width: 7, height: 7)
                        Text(verbatim: group.name).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1)
                    }
                }
            }
            if let approval = entry.approval {
                MCPApprovalCard(request: approval, theme: theme, open: { actions.open(entry.id) })
            } else if let ask = entry.terraform {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(ask.preview.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                            .foregroundStyle(ask.isProduction ? Color.white : theme.text2)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(ask.isProduction ? TerraformPanelView.production : theme.term))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox.terraform")
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    // Never an answer: the person reads it in the tab and answers there.
                    button("Open tab") { actions.open(entry.id) }
                }
            } else if let prompt = entry.prompt {
                if !prompt.preview.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(prompt.preview.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                                .foregroundStyle(colour(of: line))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.term))
                }
                HStack(spacing: 6) {
                    if let answer = prompt.default {
                        button(answer.label.prefix(18) + "  ↩", filled: true) { actions.answer(entry.id, answer) }
                    }
                    if let always = prompt.always, always != prompt.default {
                        button(String(always.label.prefix(24))) { actions.answer(entry.id, always) }
                    }
                    if let deny = prompt.deny, deny != prompt.default {
                        button("Deny  ⌫") { actions.answer(entry.id, deny) }.accessibilityIdentifier("inbox.deny")
                    }
                    Spacer(minLength: 0)
                    button("Open tab") { actions.open(entry.id) }
                }
            } else if entry.note != nil || entry.mark != .waiting {
                HStack {
                    Spacer(minLength: 0)
                    if entry.asksWhy { button("Ask Why") { actions.askWhy(entry.id) } }
                    if entry.leftBehind { button("Show") { actions.showLeftBehind(entry.id) } }
                    if entry.ci != nil {
                        button("Show Log") { actions.showCILog(entry.id) }
                        button("Ask Agent to Fix") { actions.fixCI(entry.id) }
                    }
                    if InboxModel.dismissable(entry) {
                        button("Dismiss  X") { actions.dismiss(entry.id) }.accessibilityIdentifier("inbox.dismiss")
                    }
                    button("Open tab") { actions.open(entry.id) }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.rowSel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(highlighted ? TabStatusStyle.working : .clear, lineWidth: 1.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { actions.open(entry.id) }
    }

    /// A diff in the preview reads as one.
    private func colour(of line: String) -> Color {
        if line.contains(" - ") || line.hasPrefix("-") { return TabStatusStyle.failed }
        if line.contains(" + ") || line.hasPrefix("+") { return TabStatusStyle.done }
        return theme.text2
    }

    private func button(_ title: some StringProtocol, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(String(title))
                .font(.system(size: ChromeMetrics.text(12), weight: filled ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: ChromeMetrics.row(28))
                .background(RoundedRectangle(cornerRadius: 6).fill(filled ? TabStatusStyle.working : theme.iconBg))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(filled ? Color.white : theme.text)
    }
}

/// The inbox's panel, which takes the keyboard when you click into it so
/// J and K mean something.
///
/// It does not take it on its own: the inbox is a column you leave open,
/// and a panel that grabbed focus whenever it appeared would stop you
/// typing in the terminal beside it.
package final class InboxHostingView<Content: View>: NSHostingView<Content> {
    package var onKey: ((String) -> Bool)?

    package override var acceptsFirstResponder: Bool { true }

    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    package override func keyDown(with event: NSEvent) {
        // Delete is "delete": the Deny button says ⌫ (AGT-U1).
        let key =
            event.keyCode == 53 ? "escape" : event.keyCode == 36 ? "return" : event.keyCode == 51 ? "delete" : (event.charactersIgnoringModifiers ?? "")
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, onKey?(key) == true { return }
        super.keyDown(with: event)
    }
}

/// The colours an agent's write asked in the Inbox is drawn in.
@MainActor enum WriteConfirmationColors {
    static let production = Color(nsColor: WriteConfirmation.productionRed)
}

/// An agent's MCP write, asked in the Inbox (D-6 (b)): who asks, what and
/// where — every character of it —, the name to type where the write asks
/// for one, then Allow and Don't. Return answers nothing here.
private struct MCPApprovalCard: View {
    let request: MCPApprovals.Request
    @ObservedObject var theme: ChromeTheme
    let open: () -> Void
    @State private var typed = ""

    private var confirmation: WriteConfirmation { request.confirmation }
    private var matches: Bool { MCPApprovals.accepts(typed, name: confirmation.typedName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let asker = confirmation.asker {
                Text(verbatim: asker).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(2)
                    .accessibilityIdentifier("inbox.approval.asker")
            }
            if let scope = confirmation.scope {
                Text(verbatim: (confirmation.production ? WriteConfirmation.productionMark : "") + scope)
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                    .foregroundStyle(confirmation.production ? WriteConfirmationColors.production : theme.text2)
                    .lineLimit(2)
            }
            ScrollView {
                Text(verbatim: confirmation.detail)
                    .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                    .foregroundStyle(theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.term))
            .accessibilityIdentifier("inbox.approval.detail")
            if let name = confirmation.typedName {
                TextField("Type \(name) to allow", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                    .accessibilityIdentifier("inbox.approval.name")
            }
            HStack(spacing: 6) {
                Button(confirmation.button) { MCPApprovals.shared.answer(request.id, typed: typed) }
                    .disabled(!matches)
                    .accessibilityIdentifier("inbox.approval.allow")
                Button(confirmation.cancel) { MCPApprovals.shared.answer(request.id, typed: nil) }
                    .accessibilityIdentifier("inbox.approval.decline")
                Spacer(minLength: 0)
                Button("Open tab", action: open)
            }
            .controlSize(.small)
        }
    }
}
