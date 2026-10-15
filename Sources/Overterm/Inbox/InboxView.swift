import AppKit
import SwiftUI

/// What the inbox can do to an entry.
struct InboxActions {
    /// Type a choice's key and Return into that tab's agent.
    var answer: (Tab.ID, AgentPrompt.Choice) -> Void
    var open: (Tab.ID) -> Void
    var close: () -> Void
}

/// The column of everything waiting on you.
struct InboxView: View {
    @ObservedObject var model: InboxModel
    @ObservedObject var theme: ChromeTheme
    let actions: InboxActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Inbox").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Text("J / K to move · ⌘I to close")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if model.isEmpty {
                Spacer()
                Text("Nothing is waiting for you")
                    .font(.system(size: 12))
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
                .font(.system(size: 11))
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
        switch entry.mark {
        case .waiting: ("exclamationmark.circle.fill", TabStatusStyle.waiting)
        case .failed: ("xmark.circle.fill", TabStatusStyle.failed)
        case .done: ("checkmark.circle.fill", TabStatusStyle.done)
        case .none: ("circle", theme.text3)
        }
    }

    /// A question gets a card; anything else is a line.
    private var isQuestion: Bool { entry.prompt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: glyph.0).font(.system(size: 12)).foregroundStyle(glyph.1)
                Text(entry.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 6)
                if let group = entry.group {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(group.color.color).frame(width: 7, height: 7)
                        Text(verbatim: group.name).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    }
                }
            }
            if let prompt = entry.prompt {
                if !prompt.preview.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(prompt.preview.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
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
                        button("Deny  ⌫") { actions.answer(entry.id, deny) }
                    }
                    Spacer(minLength: 0)
                    button("Open tab") { actions.open(entry.id) }
                }
            } else if entry.note != nil || entry.mark != .waiting {
                HStack {
                    Spacer(minLength: 0)
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
                .font(.system(size: 12, weight: filled ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
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
final class InboxHostingView<Content: View>: NSHostingView<Content> {
    var onKey: ((String) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode == 53 ? "escape" : (event.keyCode == 36 ? "return" : (event.charactersIgnoringModifiers ?? ""))
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, onKey?(key) == true { return }
        super.keyDown(with: event)
    }
}
