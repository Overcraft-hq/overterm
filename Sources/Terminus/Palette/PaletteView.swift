import AppKit
import SwiftUI

/// ⌘P: one search over actions, tabs, worktrees and snippets.
struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    let theme: ChromeTheme
    /// (item, run) — the window closes the palette and performs it.
    let onChoose: (PaletteItem, Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss.
            Color.black.opacity(0.001)
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                PaletteField(
                    text: $model.query,
                    onMove: { model.move($0) },
                    onSubmit: { run in model.selected.map { onChoose($0, run) } },
                    onCancel: onDismiss,
                    textColor: NSColor(theme.text)
                )
                .frame(height: 40)
                .padding(.horizontal, 14)
                Divider().opacity(0.4)
                results
            }
            .frame(width: 580)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.dimText.opacity(0.25)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 70)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture { onChoose(item, true) }
                    }
                    if model.results.isEmpty {
                        Text("No matches").foregroundStyle(theme.dimText).padding(14)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.selectedIndex) { index in
                if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(theme.dimText)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).foregroundStyle(theme.text).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: item.group == .snippet ? .monospaced : .default))
                        .foregroundStyle(theme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(item.group.rawValue).font(.system(size: 10)).foregroundStyle(theme.dimText)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

/// The search field. AppKit, because arrow keys, Return vs ⌥Return and
/// Escape need the field editor's commands (SwiftUI's onKeyPress is
/// macOS 14+; Terminus targets 13).
/// Shared by the palette and the ⌘F overlay.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: (_ run: Bool) -> Void
    let onCancel: () -> Void
    var placeholder = "Search tabs, worktrees, snippets, actions…"
    /// The chrome is dark whatever the system appearance; the field's default
    /// label colour would follow the system and go dark-on-dark.
    var textColor: NSColor = .white

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: textColor.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 16)])
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField

        init(parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(!(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false))
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥Return
                parent.onSubmit(false)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}
