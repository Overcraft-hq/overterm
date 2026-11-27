import AppKit
import SwiftUI

extension TerminalWindowController {
    /// Stops each of the tab's panes' sets, read at the press
    /// (`TabSuspension.targets`). A pane not paired yet is paired first,
    /// from a list of the app's children read off the main thread
    /// (`pairWaiting`); the lookup runs off it too; a Resume in between
    /// wins.
    /// Suspend Tab: refused where a terraform write runs in it, in
    /// Activity's words (TERM-G6) — stopped, it holds its state's lock.
    package func suspendTab(_ tab: Tab) {
        if !terraformWrites(tabs: [tab], path: .tabs).isEmpty {
            return presentSuspendRefusal(tab)
        }
        suspendPanes(tab.terminals, of: tab)
    }

    private func presentSuspendRefusal(_ tab: Tab) {
        guard let window, window.attachedSheet == nil else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "“\(tab.title)” isn't suspended"
        alert.informativeText = ActivitySignalCheck.terraformSuspend
        alert.beginSheetModal(for: window)
    }

    /// Stops `panes` of `tab`, each with its whole set — the shell too, or
    /// it takes the terminal back (Activity's Suspend of a pane's job,
    /// docs/design/activity/analysis.md, 6.10). Resume Tab, or the cover's
    /// Resume, continues them.
    package func suspendPanes(_ chosen: [TerminalView], of tab: Tab) {
        let panes = chosen.filter { !$0.isSuspended }
        guard !panes.isEmpty else { return }
        // A `.app` inside one of these stays the pane's: a dev build.
        let checkouts = Array(Set(store.tabs.compactMap { $0.checkoutSource?.root.path }))
        Task { @MainActor in
            await SurfaceProcesses.shared.pairWaiting()
            let roots = panes.map { (SurfaceProcesses.shared.pairedLoginPID(of: $0), $0.processTag) }
            // Read again only on the main actor, below.
            nonisolated(unsafe) let panes = panes
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let sets = roots.map { TabSuspension.targets(login: $0.0, tag: $0.1, checkouts: checkouts) }
                Task { @MainActor in
                    tab.objectWillChange.send()
                    self.store.objectWillChange.send()
                    for (pane, targets) in zip(panes, sets) { pane.suspend(targets) }
                }
            }
        }
    }

    package func resumeTab(_ tab: Tab) {
        tab.objectWillChange.send()
        store.objectWillChange.send()
        tab.terminals.forEach { $0.resume() }
        if store.selected === tab { tab.terminal.window?.makeFirstResponder(tab.terminal) }
    }

    /// The cover's Resume: the tab of the pane it covers.
    @objc package func resumeTabOfPane(_ sender: NSView) {
        var view: NSView? = sender
        while let current = view, !(current is TerminalView) { view = current.superview }
        guard let tab = tab(containing: view as? TerminalView) else { return }
        resumeTab(tab)
    }
}
