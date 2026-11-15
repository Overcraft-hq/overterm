import AppKit
import SwiftUI

/// The Activity page (⌥⌘A; docs/design/activity/analysis.md, 6.2, 6.4, 7.9),
/// as the window wires it: a page over the body like Docker's, read only
/// while it is the page on screen in a window that shows.
extension TerminalWindowController {
    func activityWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.activity)
        // Made the first time it opens.
        page.makeView = { [weak self] in
            guard let self, let theme = self.theme else { return nil }
            return NSHostingView(
                rootView: ActivityPageView(
                    page: self.activityPage, theme: theme,
                    copy: { lines in
                        guard !lines.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }))
        }
        // The emitted value: `showingOverlay` isn't set yet.
        page.visibilityChanged = { [weak self] visible in self?.activityPage.visible = visible }
        page.closed = { [weak self] in self?.activityPage.close() }
        page.hasList = true
        page.press = { [weak self] characters in self?.activityPage.press(characters) ?? false }
        page.paletteItems = { [weak self] in self?.activityPaletteItems() ?? [] }
        page.occlusionChanged = { [weak self] in self?.updateActivityWindowVisible() }
        page.windowClosing = { [weak self] in self?.activityPage.close() }
        return page
    }

    /// The page declared; the Where column's titles from every window.
    func wireActivityPage() {
        declarePage(activityWorkspacePage())
        activityPage.tabTitles = { Self.activityTabTitles() }
        activityPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusPageList(.activity) }
            .store(in: &cancellables)
    }

    /// Every window's tabs' titles, by id.
    static func activityTabTitles() -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            for tab in controller.store.tabs { titles[tab.id] = tab.title }
        }
        return titles
    }

    /// View ▸ Activity (⌥⌘A): the page, or back to the terminal from it.
    /// With Activity off, its settings.
    @objc func toggleActivityPage(_ sender: Any?) {
        guard Settings.shared.activityEnabled else { return openSettings(.activity) }
        togglePage(.activity)
    }

    /// The page, shown (a link's, the switcher's), on `section`.
    func showActivityPage(_ section: ActivityPageModel.Section? = nil) {
        guard Settings.shared.activityEnabled else { return openSettings(.activity) }
        if let section { activityPage.section = section }
        if store.showingOverlay != .activity { togglePage(.activity) }
    }

    /// The page reads only while its window is on screen at all (7.9). An
    /// isolated run stays in the background, often under the user's own
    /// windows: there the window says nothing about the run, and counts as
    /// shown, as Docker's page does.
    func updateActivityWindowVisible() {
        guard !AppEnvironment.isIsolated, let window else { return }
        let shown = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if activityPage.windowVisible != shown { activityPage.windowVisible = shown }
    }

    /// An `activity.` setting changed: off closes the page and stops its
    /// reading; the interval and everyone's are the page's want and rows.
    func activitySettingsChanged() {
        if !Settings.shared.activityEnabled { closeOverlay(.activity) }
        activityPage.settingsChanged()
    }

    /// What the palette offers of Activity: the page and its Listening.
    func activityPaletteItems() -> [PaletteItem] {
        guard Settings.shared.activityEnabled else { return [] }
        return [
            PaletteItem(id: "a.activity", group: .action, title: "Activity", subtitle: "Every process and port on this Mac  ⌥⌘A", symbol: "cpu") {
                [weak self] _, _ in self?.showActivityPage(.processes)
            },
            PaletteItem(
                id: "a.activity.listening", group: .action, title: "Activity: Listening", subtitle: "Your processes' listening ports, and who holds each",
                symbol: "dot.radiowaves.left.and.right"
            ) { [weak self] _, _ in self?.showActivityPage(.listening) },
        ]
    }
}
