import Foundation

/// What the page's list draws (docs/design/activity/analysis.md, 7.7):
/// published apart from the page, so a change the list doesn't draw — the
/// detail, a verb's subject, "order held", what a Free said — never
/// updates the table and every cell on screen with it. The page sets it
/// (`ActivityPageModel.syncList`), only what changed.
@MainActor
package final class ActivityListState: ObservableObject {
    @Published package fileprivate(set) var section: ActivityPageModel.Section = .processes
    /// The section's rows, their order's token and places.
    @Published package fileprivate(set) var rows = ActivityListRows()
    @Published package fileprivate(set) var columns: [ResourceColumn] = []
    @Published package fileprivate(set) var sort: ResourceSort?
    @Published package fileprivate(set) var selection: Set<String> = []
    @Published package fileprivate(set) var following = false
    @Published package fileprivate(set) var hasRead = false
    /// What an empty section says (6.4).
    @Published package fileprivate(set) var emptySentence = ""
}

extension ActivityPageModel {
    /// The list's state brought up to the page's: each part assigned only
    /// when it changed, the rows when the content or the section did.
    package func syncList(rows rowsChanged: Bool = false) {
        let list = self.list
        let section = self.section
        if rowsChanged || list.section != section { list.rows = content.listRows(section) }
        if list.section != section { list.section = section }
        let columns = columns(section)
        if list.columns != columns { list.columns = columns }
        let sort = section == .listening ? portSort : processSort
        if list.sort != sort { list.sort = sort }
        if list.selection != selection { list.selection = selection }
        if list.following != following { list.following = following }
        if list.hasRead != hasRead { list.hasRead = hasRead }
        // Other users' listeners are rows only for everyone's, on the Mac.
        let othersShown = (everyone ?? Settings.shared.activityEveryone) && scope(.listening) == .mac
        let empty = ActivityPageView.emptySentence(
            section, scopedToRun: content.summary.scopedToRun, filter: filter(section), others: content.summary.others, othersShown: othersShown)
        if list.emptySentence != empty { list.emptySentence = empty }
    }
}
