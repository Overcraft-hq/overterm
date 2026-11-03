import AppKit
import SwiftUI

/// ⌘K: one search over what you have run, your snippets, your tabs and
/// worktrees, and the app's own actions.
struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject var theme: ChromeTheme
    /// (item, run) — the window closes the palette and performs it.
    let onChoose: (PaletteItem, Bool) -> Void
    let onDismiss: () -> Void

    /// One size, whatever is selected: the card grew to 860 pt for an item
    /// with a detail and shrank to 580 for one without, and stepping
    /// through the list or the tabs made it jump.
    static let width: CGFloat = 780
    static let bodyHeight: CGFloat = 380
    static let detailWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss.
            Color.black.opacity(0.001)
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(15))).foregroundStyle(theme.text3)
                    PaletteField(
                        text: $model.query,
                        onMove: { model.move($0) },
                        onSubmit: { run in model.selected.map { onChoose($0, run) } },
                        onCancel: onDismiss,
                        onTab: { model.cycleScope($0) },
                        textColor: NSColor(theme.text)
                    )
                }
                .frame(height: ChromeMetrics.row(50))
                .padding(.horizontal, 16)
                scopes
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 0) {
                    results.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    Divider().opacity(0.4)
                    Group {
                        if let selected = model.selected {
                            PaletteDetail(item: selected, model: model, theme: theme)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.detailWidth)
                }
                .frame(height: Self.bodyHeight)
                Divider().opacity(0.4)
                footer
            }
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.dimText.opacity(0.22)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.38), radius: 30, y: 12)
            .padding(.top, 70)
        }
    }

    /// All and the groups, each with what the query finds — under the field
    /// as ⌘F's are; ⇥ steps through.
    private var scopes: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.tabs.enumerated()), id: \.offset) { _, group in
                tab(group)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func title(of group: PaletteItem.Group?) -> String {
        switch group {
        case nil: "All"
        case .snippet: "Snippets"
        case .action: "Actions"
        case .tab: "Tabs"
        case .worktree: "Worktrees"
        case .history: "History"
        case .container: "Docker"
        case .kubernetes: "Kubernetes"
        }
    }

    private func tab(_ group: PaletteItem.Group?) -> some View {
        let on = model.scope == group
        return Button {
            model.scope = group
        } label: {
            HStack(spacing: 4) {
                Text(title(of: group)).font(.system(size: ChromeMetrics.text(12), weight: on ? .semibold : .regular))
                Text(verbatim: "\(model.count(of: group))").font(.system(size: ChromeMetrics.text(11))).monospacedDigit()
                    .foregroundStyle(on ? theme.text : theme.text3)
            }
            .foregroundStyle(on ? theme.text : theme.text2)
            .padding(.horizontal, 10)
            .frame(height: ChromeMetrics.row(24))
            .background(Capsule().fill(on ? theme.selected : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("palette.scope.\(group?.rawValue ?? "all")")
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↩", model.selected.map(Self.verb) ?? "open")
            if let group = model.selected?.group, group == .history || group == .snippet { hint("⌥↩", "type without running") }
            hint("⇥", "next tab")
            Spacer()
            hint("esc", "close")
        }
        .padding(.horizontal, 16)
        .frame(height: ChromeMetrics.row(32))
    }

    /// What Return does with it, in a word or three.
    static func verb(_ item: PaletteItem) -> String {
        switch item.group {
        case .history, .snippet: "run in the terminal"
        case .action: "do it"
        case .tab: "go to the tab"
        case .worktree: "open the worktree"
        case .container: "show it on the Docker page"
        case .kubernetes: "show it on the Kubernetes page"
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(.system(size: ChromeMetrics.text(11), weight: .medium))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 5)
                .frame(height: ChromeMetrics.row(18))
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.iconBg))
            Text(what).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        // With nothing typed the list is in its groups: say which.
                        if model.query.isEmpty, model.scope == nil, index == 0 || model.results[index - 1].group != item.group {
                            Text(title(of: item.group).uppercased())
                                .font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                                .foregroundStyle(theme.text3)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                        }
                        row(item, selected: index == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture { onChoose(item, true) }
                    }
                    if model.results.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(20))).foregroundStyle(theme.text3)
                            Text(verbatim: model.query.isEmpty ? "Nothing here" : "Nothing matches “\(model.query)”")
                                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedIndex) { index in
                if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                // History shows how it went last time instead of a clock.
                if let failed = item.failed {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? TabStatusStyle.failed : TabStatusStyle.done)
                } else {
                    Image(systemName: item.symbol).foregroundStyle(selected ? theme.text : theme.text2)
                }
            }
            .font(.system(size: ChromeMetrics.text(12)))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.iconBg))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: ChromeMetrics.text(13), weight: selected ? .medium : .regular, design: item.group == .history ? .monospaced : .default))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: ChromeMetrics.text(11), design: item.group == .snippet ? .monospaced : .default))
                        .foregroundStyle(theme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            // In a search the groups are mixed: say which each one is.
            if !model.query.isEmpty || model.scope != nil {
                Text(title(of: item.group)).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ChromeMetrics.row(item.subtitle == nil ? 36 : 44))
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? theme.selected : .clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(theme.accent).frame(width: 3, height: 18).offset(x: -1) }
        }
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
    /// ⇥ (1) and ⇧⇥ (-1), where a list has tabs to step through.
    var onTab: ((Int) -> Void)? = nil
    var placeholder = "Search tabs, worktrees, snippets, actions…"
    /// The chrome is dark whatever the system appearance; the field's default
    /// label colour would follow the system and go dark-on-dark.
    var textColor: NSColor = .white
    /// Takes the keyboard once it is in a window (a picker over a page);
    /// the palette's is given it by the window.
    var focusesOnAppear = false
    var fontSize: CGFloat = 16

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: ChromeMetrics.text(fontSize))
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: textColor.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: ChromeMetrics.text(fontSize))])
        field.delegate = context.coordinator
        if focusesOnAppear { Self.focus(field) }
        return field
    }

    /// The keyboard to the field once it is in a window — SwiftUI puts it
    /// there after making it; tried again shortly.
    static func focus(_ field: NSTextField, attempts: Int = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 10 ? 0 : 0.05)) { [weak field] in
            guard let field else { return }
            if let window = field.window {
                window.makeFirstResponder(field)
            } else if attempts > 0 {
                focus(field, attempts: attempts - 1)
            }
        }
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
            case #selector(NSResponder.insertTab(_:)) where parent.onTab != nil:
                parent.onTab?(1)
            case #selector(NSResponder.insertBacktab(_:)) where parent.onTab != nil:
                parent.onTab?(-1)
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
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: ChromeMetrics.text(16)))
                    .foregroundStyle(theme.text2)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.iconBg))
                Text(item.group.rawValue.uppercased())
                    .font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            Text(item.title)
                .font(.system(size: ChromeMetrics.text(14), weight: .semibold, design: item.group == .history ? .monospaced : .default))
                .foregroundStyle(theme.text)
                .lineLimit(3)
            if let subtitle = item.subtitle, item.group != .snippet {
                Text(subtitle)
                    .font(.system(size: ChromeMetrics.text(12)))
                    .foregroundStyle(theme.text2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle = item.subtitle, item.group == .snippet {
                Text(subtitle)
                    .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                    .foregroundStyle(theme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.term))
            }
            ForEach(item.placeholders, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                    TextField(
                        name, text: Binding(get: { model.values[name] ?? "" }, set: { model.values[name] = $0 })
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: ChromeMetrics.text(13), design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: ChromeMetrics.row(28))
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.term))
                }
            }
            Spacer(minLength: 0)
            if let detail = item.detail {
                Text(detail).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
            }
            Text(verbatim: "↩ \(PaletteView.verb(item))")
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.text3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
