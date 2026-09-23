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
    var setPinned: (Tab, Bool) -> Void
}

/// Chrome-style tab strip, living in the window's title bar.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
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

private struct TabItemView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
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
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.dimText)
                    .help("Pinned — unpin to close")
            } else {
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
        }
        .padding(.horizontal, 10)
        // Pinned tabs are compact and never shrink away; the rest share the
        // remaining width.
        .frame(
            minWidth: tab.isPinned ? 56 : 60, idealWidth: tab.isPinned ? 120 : 200, maxWidth: tab.isPinned ? 130 : 220,
            minHeight: 28, maxHeight: 28
        )
        .layoutPriority(tab.isPinned ? 1 : 0)
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
        .onDrag {
            store.draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, store: store))
        .contextMenu {
            Button("Rename Tab…") {
                actions.select(tab)
                store.renamingID = tab.id
            }
            if tab.customTitle != nil {
                Button("Reset Name") { tab.customTitle = nil }
            }
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { actions.setPinned(tab, !tab.isPinned) }
            Menu("Color") {
                ForEach(TabColor.allCases) { color in
                    Toggle(color.name, isOn: Binding(get: { tab.color == color }, set: { tab.color = $0 ? color : nil }))
                }
                Divider()
                Button("None") { tab.color = nil }.disabled(tab.color == nil)
            }
            Divider()
            Button("Close Tab") { actions.close(tab) }.disabled(tab.isPinned)
        }
        .help(tab.title)
        .padding(.horizontal, 2)
    }
}

/// Reorders live: as a dragged tab passes over another in its group, they
/// swap places, like Chrome.
private struct TabDropDelegate: DropDelegate {
    let target: Tab
    let store: TabStore

    func dropEntered(info: DropInfo) {
        guard let id = store.draggingID, let dragged = store.tabs.first(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.12)) { store.move(dragged, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        return true
    }
}

/// In-place name editor. Return commits, Escape cancels, an empty name goes
/// back to following the shell title.
private struct TabRenameField: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
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
