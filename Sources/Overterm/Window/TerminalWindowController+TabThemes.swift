import AppKit
import Combine

/// A tab's own terminal theme: its group's (the group's menu ▸ Terminal
/// Theme), else the first folder rule that takes its folder (Settings ▸
/// Appearance ▸ Themes by folder), else none — the app's. Every pane of the
/// tab takes it (`TerminalView.themeName`), and the window dresses in it
/// while the tab is in front.
extension TerminalWindowController {
    package func themeName(for tab: Tab) -> String? {
        if let group = store.group(of: tab), let theme = group.theme { return theme }
        let lines = Settings.shared.value("appearance.folderThemes")?.list ?? []
        guard !lines.isEmpty else { return nil }
        let folder = tab.attachedCheckout?.path ?? tab.agentDirectory ?? tab.workingDirectory
        return folder.flatMap { FolderThemes.theme(for: $0, rules: FolderThemes.rules(lines)) }
    }

    /// Every pane its tab's theme; the window the selected tab's. Cheap
    /// when nothing changed: a pane is told only when its theme differs.
    package func applyTabThemes() {
        var selectedChanged = false
        for tab in store.tabs {
            let name = themeName(for: tab)
            for pane in tab.terminals where pane.themeName != name {
                pane.themeName = name
                if tab === store.selected { selectedChanged = true }
            }
        }
        if selectedChanged || lastWindowTheme != store.selected.flatMap(themeName(for:)) {
            lastWindowTheme = store.selected.flatMap(themeName(for:))
            refreshChrome()
        }
    }

    /// The group's menu ▸ Terminal Theme: nil for the window's own.
    package func setTheme(_ name: String?, of group: TabGroup) {
        group.theme = name
        applyTabThemes()
    }

    /// When the tabs, the selection, a group's theme or the rules change —
    /// and a tab's folder: its shell's, its agent's or the one attached
    /// (a folder rule follows where it works), or its panes (a split's new
    /// pane takes its tab's theme). The poll that walked the selected tab
    /// every 2 s did both of the last, only for that tab.
    package func wireTabThemes() {
        store.$tabs
            .combineLatest(store.$selectedID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTabThemes() }
            .store(in: &cancellables)
        store.$tabs
            .map { tabs in
                Publishers.MergeMany(
                    tabs.map { tab in
                        tab.$workingDirectory.map { _ in () }.merge(
                            with: tab.$agentDirectory.map { _ in () }, tab.$attachedCheckout.map { _ in () }, tab.$splits.map { _ in () })
                    }
                )
                // Each says its value as it is subscribed to: the tabs'
                // change itself is the sink above's.
                .dropFirst(tabs.count * 4)
            }
            .switchToLatest()
            // @Published says before it changes: read after.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyTabThemes() }
            .store(in: &cancellables)
        store.$groups
            .map { groups in Publishers.MergeMany(groups.map { $0.$theme.map { _ in () } }).prepend(()) }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyTabThemes() }
            .store(in: &cancellables)
    }
}
