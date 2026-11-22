import Combine
import Foundation
import GhosttyKit

/// Find-in-terminal state for one terminal. libghostty does the searching
/// (scrollback included, highlighting on screen); this holds what the search
/// bar shows and sends the needle back.
@MainActor
package final class TerminalSearch: ObservableObject {
    @Published package private(set) var isActive = false
    /// The compact find bar (next / previous) is showing. A search can run
    /// without it — behind the ⌘F overlay, highlighting as you type.
    @Published package private(set) var barVisible = false
    @Published package var needle = ""
    /// Matches in the whole scrollback; nil while unknown.
    @Published package private(set) var total: Int?
    /// The highlighted match, 0-based; nil when none is selected.
    @Published package private(set) var selected: Int?

    private weak var terminal: TerminalView?
    private var needleSubscription: AnyCancellable?

    package init(terminal: TerminalView) {
        self.terminal = terminal
    }

    /// libghostty started a search (⌘F, or a search-selection binding).
    package func begin(needle initial: String?) {
        if let initial, !initial.isEmpty { needle = initial }
        guard !isActive else { return }
        isActive = true
        // Short needles match everywhere and cost a full scan: wait a beat
        // before sending them (as Ghostty's own app does).
        needleSubscription =
            $needle
            .removeDuplicates()
            .map { needle -> AnyPublisher<String, Never> in
                needle.isEmpty || needle.count >= 3
                    ? Just(needle).eraseToAnyPublisher()
                    : Just(needle).delay(for: .milliseconds(300), scheduler: DispatchQueue.main).eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] needle in self?.terminal?.perform(binding: "search:\(needle)") }
    }

    /// Show the compact bar for stepping through matches.
    package func showBar() {
        if !isActive { begin(needle: nil) }
        barVisible = true
    }

    /// libghostty ended it (end_search), or the bar closed.
    package func end() {
        guard isActive else { return }
        isActive = false
        barVisible = false
        needleSubscription = nil
        total = nil
        selected = nil
        terminal?.perform(binding: "end_search")
    }

    package func next() { terminal?.perform(binding: "navigate_search:next") }
    package func previous() { terminal?.perform(binding: "navigate_search:previous") }

    package func update(total: Int?) { self.total = total }
    package func update(selected: Int?) { self.selected = selected }
}
