import AppKit

/// View ▸ Presentation Mode (⌃⌘P): the terminal alone and large, for a
/// screen share or a demo — and back as it was with the same keys.
///
/// Entering it notes what was open, shuts the columns beside the terminal
/// through their own toggles (so the sidebar's remembered visibility, the
/// right-hand slot and Overgit's reading stay right), hides the pane
/// headers and makes every terminal's font larger by `fontStep`. Leaving it
/// opens what it shut, and only that.
extension TerminalWindowController {
    /// What presenting shut, to open again on the way out.
    struct Presentation {
        var sidebar = false
        var editor = false
        var changes = false
        var browser = false
        var inbox = false
    }

    /// Points added to every terminal's font while presenting.
    static let fontStep = 6

    var isPresenting: Bool { presentation != nil }

    @objc func togglePresentation(_ sender: Any?) {
        if presentation == nil { startPresenting() } else { stopPresenting() }
    }

    private func startPresenting() {
        var shut = Presentation()
        setEditorZoomed(false)
        if sidebarItem?.isCollapsed == false {
            shut.sidebar = true
            toggleFileTree(nil)
        }
        if let editorItem, !editorItem.isCollapsed {
            shut.editor = true
            editorItem.isCollapsed = true
        }
        if diffItem?.isCollapsed == false {
            shut.changes = true
            toggleDiff(nil)
        }
        if browserItem?.isCollapsed == false {
            shut.browser = true
            toggleBrowser(nil)
        }
        if inboxItem?.isCollapsed == false {
            shut.inbox = true
            toggleInbox(nil)
        }
        presentation = shut
        SplitHostView.presenting = true
        applyMetrics()
        resizeTerminalFonts(by: Self.fontStep)
        focusSelectedTerminal()
    }

    private func stopPresenting() {
        guard let shut = presentation else { return }
        presentation = nil
        SplitHostView.presenting = false
        applyMetrics()
        resizeTerminalFonts(by: -Self.fontStep)
        if shut.sidebar, sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        if shut.editor { editorItem?.isCollapsed = false }
        if shut.changes, diffItem?.isCollapsed == true { toggleDiff(nil) }
        if shut.browser, browserItem?.isCollapsed == true { toggleBrowser(nil) }
        if shut.inbox, inboxItem?.isCollapsed == true { toggleInbox(nil) }
        focusSelectedTerminal()
    }

    /// Every pane of every tab, larger or smaller by `points`.
    private func resizeTerminalFonts(by points: Int) {
        let action = points > 0 ? "increase_font_size:\(points)" : "decrease_font_size:\(-points)"
        for tab in store.tabs {
            for pane in tab.terminals { pane.perform(binding: action) }
        }
    }
}
