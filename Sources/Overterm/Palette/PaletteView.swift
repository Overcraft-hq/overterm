import AppKit
import SwiftUI

/// ⌘K: one search over what you have run, your snippets, your tabs and
/// worktrees, and the app's own actions.
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
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.text3)
                    PaletteField(
                        text: $model.query,
                        onMove: { model.move($0) },
                        onSubmit: { run in model.selected.map { onChoose($0, run) } },
                        onCancel: onDismiss,
                        textColor: NSColor(theme.text)
                    )
                    scopes
                }
                .frame(height: 48)
                .padding(.horizontal, 16)
                Divider().opacity(0.4)
                // One height for the list and the detail beside it: the
                // detail's spacer has no height of its own, and unbounded it
                // stretched the card down the whole window with the list
                // floating in the middle of it.
                HStack(alignment: .top, spacing: 0) {
                    results.frame(width: 470).frame(maxHeight: .infinity, alignment: .top)
                    if let selected = model.selected, selected.detail != nil || !selected.placeholders.isEmpty {
                        Divider().opacity(0.4)
                        PaletteDetail(item: selected, model: model, theme: theme)
                    }
                }
                .frame(height: Self.bodyHeight)
                Divider().opacity(0.4)
                footer
            }
            .frame(width: model.selected.map { $0.detail != nil || !$0.placeholders.isEmpty } == true ? 860 : 580)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.dimText.opacity(0.25)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 70)
        }
    }

    static let bodyHeight: CGFloat = 372

    /// All / History / Snippets / Actions — narrows what is searched.
    private var scopes: some View {
        HStack(spacing: 4) {
            chip("All", nil)
            ForEach(PaletteItem.Group.scopes, id: \.self) { group in
                chip(group == .snippet ? "Snippets" : group.rawValue, group)
            }
        }
    }

    private func chip(_ title: String, _ group: PaletteItem.Group?) -> some View {
        let on = model.scope == group
        return Button {
            model.scope = group
        } label: {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(on ? TabStatusStyle.working : theme.iconBg))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.white : theme.text2)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            hint("↩", "run")
            hint("⌥↩", "paste without running")
            Spacer()
            Text(verbatim: "⌘K").font(.system(size: 12)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key).font(.system(size: 12)).foregroundStyle(theme.text)
            Text(what).font(.system(size: 12)).foregroundStyle(theme.text3)
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
            // History shows how it went last time instead of a clock.
            if let failed = item.failed {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .frame(width: 18)
                    .foregroundStyle(failed ? TabStatusStyle.failed : TabStatusStyle.done)
            } else {
                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(theme.text2)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, design: item.group == .history ? .monospaced : .default))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
/// macOS 14+; Overterm targets 13).
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

/// What the selected thing is, beside the list: a snippet's fields to fill
/// in, and when a command last ran and how it went.
private struct PaletteDetail: View {
    let item: PaletteItem
    @ObservedObject var model: PaletteModel
    let theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.system(size: 13, weight: .bold, design: item.group == .history ? .monospaced : .default))
                .foregroundStyle(theme.text)
                .lineLimit(2)
            if let subtitle = item.subtitle, item.group == .snippet {
                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.term))
            }
            ForEach(item.placeholders, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 11)).foregroundStyle(theme.text2)
                    TextField(
                        name, text: Binding(get: { model.values[name] ?? "" }, set: { model.values[name] = $0 })
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.term))
                }
            }
            Spacer(minLength: 0)
            if let detail = item.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.text3)
            }
        }
        .padding(16)
        .frame(width: 390, alignment: .topLeading)
    }
}
