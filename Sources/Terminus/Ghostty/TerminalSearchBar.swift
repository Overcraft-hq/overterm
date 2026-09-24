import AppKit
import SwiftUI

/// The find bar over the terminal: needle, "3/12", previous / next, close.
/// Return = next match, Shift-Return = previous, Escape = close (or, with
/// text, back to the terminal keeping the highlights), as in Ghostty.
struct TerminalSearchBar: View {
    @ObservedObject var search: TerminalSearch
    let theme: ChromeTheme
    /// Give the keyboard back to the terminal.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SearchField(
                text: $search.needle,
                onNext: search.next,
                onPrevious: search.previous,
                onEscape: {
                    if search.needle.isEmpty { search.end() }
                    onDismiss()
                }
            )
            .frame(width: 190, height: 22)
            Text(verbatim: counter)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.dimText)
                .frame(minWidth: 44, alignment: .trailing)
            button("chevron.up", help: "Previous (⇧↩)", action: search.previous)
            button("chevron.down", help: "Next (↩)", action: search.next)
            button("xmark", help: "Close (Esc)") {
                search.end()
                onDismiss()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.strip))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private var counter: String {
        switch (search.selected, search.total) {
        case (let selected?, let total?): "\(selected + 1)/\(total)"
        case (nil, let total?): "–/\(total)"
        default: search.needle.isEmpty ? "" : "…"
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
        .help(help)
    }
}

/// AppKit field: Return vs Shift-Return and Escape need the field editor's
/// commands (SwiftUI's onKeyPress is macOS 14+).
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { parent.onPrevious() } else { parent.onNext() }
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onPrevious()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
            default:
                return false
            }
            return true
        }
    }
}
