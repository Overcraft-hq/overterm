import AppKit
import Combine

// MARK: The pages over the body, as declared (WorkspacePage)

extension TerminalWindowController {
    /// A page wired from its declaration: told when it shows and hides —
    /// the emitted value, since `showingOverlay` isn't set yet.
    func declarePage(_ page: WorkspacePage) {
        pages.declare(page)
        guard let changed = page.visibilityChanged else { return }
        let overlay = page.overlay
        store.$showingOverlay
            .map { $0 == overlay }
            .removeDuplicates()
            .sink { visible in changed(visible) }
            .store(in: &cancellables)
    }

    /// Settings's tab: its view is made with the window; its ✕ drops the
    /// draft being edited.
    func settingsWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.settings)
        page.closed = { [weak self] in self?.settingsPage.draft = nil }
        return page
    }

    /// A page from the menu: shown, its list given the keyboard — or, while
    /// it shows, back to the terminal.
    func togglePage(_ overlay: WorkspaceOverlay) {
        if store.showingOverlay == overlay {
            hideOverlay()
        } else {
            showOverlay(overlay)
            if pages[overlay]?.hasList == true { focusPageList(overlay) }
        }
    }

    /// The keyboard to a showing page's list — AppKit's way, since SwiftUI's
    /// focus wouldn't take it back from a filter field. The table exists
    /// only once SwiftUI has laid the list out: tried again shortly.
    func focusPageList(_ overlay: WorkspaceOverlay, attempts: Int = 10) {
        guard store.showingOverlay == overlay, pages[overlay]?.hasList == true, pages.view(overlay) != nil else { return }
        if let table = pages.list(overlay) {
            window?.makeFirstResponder(table)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusPageList(overlay, attempts: attempts - 1) }
        }
    }

    /// The page shows in this window and its list — the page's first table,
    /// the one `focusPageList` gives the keyboard, not a text field's editor
    /// — is the first responder. A table in a detail (a build's steps) is
    /// not the list: there ⌫ would remove the selected build.
    func pageListHasKeyboard(_ overlay: WorkspaceOverlay, _ event: NSEvent? = nil) -> Bool {
        guard store.showingOverlay == overlay, event?.window ?? window === window, let page = pages.view(overlay),
            let table = window?.firstResponder as? NSTableView
        else { return false }
        return table.isDescendant(of: page) && pages.list(overlay) === table
    }

    /// Letters act on a page's list while its table has the keyboard; in a
    /// filter field they are text. SwiftUI's own key handling is macOS 14.
    func installPageKeys() {
        pageKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.noteKubernetesWindowInput(event)
            guard let self, self.handlePageKey(event) else { return event }
            return nil
        }
    }

    /// A key down: the showing page's when its list has the keyboard and the
    /// key means something there, with no ⌘, ⌃ or ⌥ — those are menus'.
    func handlePageKey(_ event: NSEvent) -> Bool {
        if handlePageCommandKey(event) { return true }
        guard let overlay = store.showingOverlay, let press = pages[overlay]?.press, pageListHasKeyboard(overlay, event),
            WorkspacePage.isListKey(event.modifierFlags), let characters = event.characters
        else { return false }
        return press(characters)
    }

    /// ⌘ and a key while a page shows (its `commandPress`), unless a text
    /// field is being typed in: there ⌘[ is the field's.
    func handlePageCommandKey(_ event: NSEvent) -> Bool {
        guard let overlay = store.showingOverlay, let press = pages[overlay]?.commandPress, event.window ?? window === window,
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command, let characters = event.charactersIgnoringModifiers
        else { return false }
        if let editor = window?.firstResponder as? NSTextView, editor.isEditable { return false }
        return press(characters)
    }

    /// A switcher: the palette on one group, or closed when it already is.
    func togglePalette(scope: PaletteItem.Group) {
        if paletteView?.isHidden == false, palette.scope == scope { return hidePalette() }
        if paletteView?.isHidden != false { showPalette(nil) }
        palette.scope = scope
    }
}
