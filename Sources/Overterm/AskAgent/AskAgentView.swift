import AppKit
import SwiftUI

struct SelectionActions {
    var ask: () -> Void
    var copy: () -> Void
    var copyAsMarkdown: () -> Void
    var search: () -> Void
    /// Into today's note — nil while notes are off.
    var toNote: (() -> Void)? = nil
}

/// The strip that appears over a selection: the four things you do with
/// terminal text you have just picked out.
///
/// It can be placed because the selection is the one region libghostty
/// reports a position for (`ghostty_text_s.tl_px_x/y`) — and only while
/// it is on screen, which is also the only time a toolbar over it would
/// make sense.
struct SelectionBar: View {
    @ObservedObject var theme: ChromeTheme
    let actions: SelectionActions

    var body: some View {
        HStack(spacing: 2) {
            Button(action: actions.ask) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text("Ask Agent").font(.system(size: 12, weight: .semibold))
                    Text(verbatim: "⌘L").font(.system(size: 12)).opacity(0.8)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(TabColor.purple.color.opacity(0.28)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TabColor.purple.color)
            plain("Copy", actions.copy)
            plain("Copy as Markdown", actions.copyAsMarkdown)
            plain("Search the Web", actions.search)
            if let toNote = actions.toNote, Settings.shared.notesEnabled { plain("To Note", toNote) }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.menu)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.menuEdge, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        )
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func plain(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }
}

/// Where the selection goes, what goes with it, and what to say about it.
struct AskAgentView: View {
    @ObservedObject var model: AskAgentModel
    @ObservedObject var theme: ChromeTheme
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Send to")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.targets) { target in
                    Button {
                        model.chosen = target.id
                    } label: {
                        HStack(spacing: 8) {
                            if let color = target.color {
                                RoundedRectangle(cornerRadius: 2).fill(color.color).frame(width: 8, height: 8)
                            } else {
                                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(theme.text3)
                            }
                            Text(target.title).font(.system(size: 13))
                            Spacer(minLength: 8)
                            Text(target.detail).font(.system(size: 11)).opacity(0.85)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(model.chosen == target.id ? TabStatusStyle.working : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.chosen == target.id ? Color.white : theme.text)
                }
            }
            label("Include")
            HStack(spacing: 6) {
                chip(model.subject ?? "\(model.lines) selected line\(model.lines == 1 ? "" : "s")", .constant(true), fixed: true)
                if model.command != nil { chip("command", $model.extras.command) }
                if model.command?.exit != nil { chip("exit code", $model.extras.exit) }
                if model.canDiff { chip("git diff", $model.extras.diff) }
            }
            // What else came with it (a container's logs, its compose
            // service), a chip each.
            if !model.parts.isEmpty {
                HStack(spacing: 6) {
                    // By the part, not its place: a sheet given other parts
                    // reuses no chip for a different one.
                    ForEach($model.parts) { $part in chip(part.title, $part.on) }
                }
            }
            TextField("What should it do with this?", text: $model.message)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.term))
                .onSubmit(send)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Send  ⌘↩", action: send).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
    }

    private func chip(_ title: String, _ on: Binding<Bool>, fixed: Bool = false) -> some View {
        Button {
            if !fixed { on.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(on.wrappedValue ? TabStatusStyle.working : theme.text3)
                // A container's name can be long; the sheet is 380 pt.
                Text(title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(theme.iconBg))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(fixed ? 0.75 : 1)
    }
}
