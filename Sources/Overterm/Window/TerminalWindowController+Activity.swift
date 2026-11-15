import AppKit
import Combine

/// The census's view of the app (docs/design/activity/analysis.md, 7.1):
/// which pane is which, as one value the sampler's queue reads whole.
extension TerminalWindowController {
    /// Every window's panes, in each strip's order: the pane's tag, its
    /// tab and window, the `login` it was paired with, the agent its tab
    /// was opened for. A surface still waiting for its `login` is paired
    /// first, from the latest census's children of the app: microseconds,
    /// no scan — as far as what holds now lets it, the list being of any
    /// age (`SurfaceProcesses.pair`). What the later stages add — a pane's
    /// title, its checkout and branch, the forwards, the tunnels — comes
    /// with the stage that reads it, and with what rebuilds it when it
    /// changes.
    static func activityContext(windows: [NSWindow] = NSApp.windows) -> ActivityContext {
        let surfaces = SurfaceProcesses.shared
        if surfaces.hasWaiting, let snapshot = ActivityMonitor.shared.sampler.latest { surfaces.pair(snapshot) }
        var context = ActivityContext()
        for controller in windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            let window = controller.window?.windowNumber
            for tab in controller.store.tabs {
                for pane in tab.terminals {
                    context.panes.append(
                        ActivityContext.Pane(tag: pane.processTag, tab: tab.id, window: window, login: surfaces.login(of: pane), agent: tab.agent))
                }
            }
        }
        return context
    }

    /// The census's context follows this window's tabs and their panes: a
    /// tab opened, closed or moved in, a pane split off or moved between
    /// tabs. Surfaces and pairings say so themselves (`SurfaceProcesses`).
    func watchActivityContext() {
        store.$tabs
            .map { tabs in Publishers.MergeMany(tabs.map { $0.$splits.map { _ in () } }).prepend(()) }
            .switchToLatest()
            .sink { _ in ActivityMonitor.shared.contextChanged() }
            .store(in: &cancellables)
    }

    /// The app's census, wired once at launch: its context from every
    /// window, and each snapshot that lands pairs the surfaces still
    /// waiting for their `login` — the census lists the app's children and
    /// the logins no pane has on its queue, the main actor pairs them
    /// (7.7) — and a pairing made brings the next tick early, so a new
    /// pane's processes are read a quarter of a second later.
    static func wireActivityCensus() -> AnyCancellable {
        let monitor = ActivityMonitor.shared
        monitor.contextSource = { activityContext() }
        // @Published emits before it changes: the emitted value.
        return monitor.$snapshot.compactMap { $0 }
            .sink { snapshot in
                let surfaces = SurfaceProcesses.shared
                guard surfaces.hasWaiting, surfaces.pair(snapshot) else { return }
                ActivityMonitor.shared.surfacesPaired()
            }
    }
}
