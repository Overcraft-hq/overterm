import Foundation

/// What a tab's strip says about its panes' contexts, pure. A pane moved
/// from another tab keeps its own pin, so a tab's panes may differ: then
/// it says `mixed` (red if any of them is production) rather than one
/// pane's context — an unpinned pane among pinned ones reaches the
/// current context.
package struct KubeTabBadge: Equatable {
    package var text: String
    package var help: String
    /// In the page's red: production, a lost pin, or a mix holding either.
    package var alert: Bool

    package init(text: String, help: String, alert: Bool) {
        self.text = text
        self.help = help
        self.alert = alert
    }
}
