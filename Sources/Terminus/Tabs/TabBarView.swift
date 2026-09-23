import AppKit
import SwiftUI

/// What the strip asks its window to do. Closures rather than a reference to
/// the controller, so the hosting view does not retain it.
struct TabBarActions {
    var select: (Tab) -> Void
    var close: (Tab) -> Void
    var newTab: () -> Void
    /// Editing a name ended (committed or cancelled): give the keyboard back
    /// to the terminal.
    var renameEnded: () -> Void
}

/// Chrome-style tab strip, living in the window's title bar.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    let theme: TabBarTheme
    /// Room for the traffic lights on the left.
    let leadingInset: CGFloat
    let actions: TabBarActions

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            ForEach(store.tabs) { tab in
                TabItemView(
                    tab: tab,
                    store: store,
                    theme: theme,
                    actions: actions
                )
            }
            Button(action: actions.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("New Tab (⌘T)")
            .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(WindowDragArea())
    }
}

/// Colours derived from the terminal theme so the strip reads as part of it:
/// the selected tab *is* the terminal's background, the strip sits a step
/// away from it.
struct TabBarTheme {
    let strip: Color
    let selected: Color
    let hover: Color
    let text: Color
    let dimText: Color

    @MainActor
    init(background: NSColor, foreground: NSColor) {
        let bg = background.usingColorSpace(.sRGB) ?? background
        let isDark = bg.brightnessComponent < 0.5
        let stripColor = isDark ? bg.blended(withFraction: 0.35, of: .black) : bg.blended(withFraction: 0.08, of: .black)
        strip = Color(nsColor: stripColor ?? bg)
        selected = Color(nsColor: bg)
        hover = Color(nsColor: bg.withAlphaComponent(0.5))
        text = Color(nsColor: foreground)
        dimText = Color(nsColor: foreground.withAlphaComponent(0.6))
    }
}

private struct TabItemView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: TabBarTheme
    let actions: TabBarActions
    @State private var hovering = false

    private var isSelected: Bool { tab.id == store.selectedID }
    private var isRenaming: Bool { tab.id == store.renamingID }

    var body: some View {
        HStack(spacing: 6) {
            if let color = tab.color {
                Circle().fill(color.color).frame(width: 8, height: 8)
            }
            if isRenaming {
                TabRenameField(tab: tab, store: store, theme: theme, onEnd: actions.renameEnded)
            } else {
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? theme.text : theme.dimText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: { actions.close(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .opacity(isSelected || hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 60, idealWidth: 200, maxWidth: 220, minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
        )
        .background(
            // A coloured tab carries a faint wash of its colour, so it is
            // findable in a full strip even when not selected.
            RoundedRectangle(cornerRadius: 7)
                .fill(tab.color?.color.opacity(isSelected ? 0.0 : 0.14) ?? .clear)
        )
        .overlay(alignment: .bottom) {
            if isSelected, let color = tab.color {
                Capsule().fill(color.color).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        // Single and double tap together, not exclusively: an exclusive double
        // tap would delay every plain click by the double-click interval.
        .onTapGesture { actions.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingID = tab.id })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Tab…") {
                actions.select(tab)
                store.renamingID = tab.id
            }
            if tab.customTitle != nil {
                Button("Reset Name") { tab.customTitle = nil }
            }
            Menu("Color") {
                ForEach(TabColor.allCases) { color in
                    Toggle(color.name, isOn: Binding(get: { tab.color == color }, set: { tab.color = $0 ? color : nil }))
                }
                Divider()
                Button("None") { tab.color = nil }.disabled(tab.color == nil)
            }
            Divider()
            Button("Close Tab") { actions.close(tab) }
        }
        .help(tab.title)
        .padding(.horizontal, 2)
    }
}

/// In-place name editor. Return commits, Escape cancels, an empty name goes
/// back to following the shell title.
private struct TabRenameField: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: TabBarTheme
    let onEnd: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            .focused($focused)
            .onAppear {
                draft = tab.title
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand(perform: finish)
            .onChange(of: focused) { isFocused in
                // Clicking elsewhere commits, as in Chrome.
                if !isFocused, store.renamingID == tab.id { commit() }
            }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        tab.customTitle = name.isEmpty || name == tab.shellTitle ? nil : name
        finish()
    }

    private func finish() {
        guard store.renamingID == tab.id else { return }
        store.renamingID = nil
        onEnd()
    }
}

/// Empty strip space drags the window, as a title bar should.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
