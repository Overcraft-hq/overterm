#if E2E
import AppKit
import Foundation

/// What moves between tabs or acts on "the other tabs" goes by the tabs
/// the strip draws (P02): with an island stashed, next never lands in it,
/// Close Other Tabs leaves it apart unless its box is ticked, Suspend
/// Other Tabs asks once with a list, and a notification's tab comes back
/// into the strip before it is selected.
extension E2ERunner {
    func stripHiddenTabsChecks(_ group: TabGroup, loose: Tab) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hidden = app.store.tabs(in: group)
        app.store.select(loose)
        var walked: [String] = []
        for _ in 0..<3 {
            app.selectNextTab(nil)
            walked.append(app.store.selected?.title ?? "")
        }
        check("next never lands in a stashed island", walked == ["loose", "loose", "loose"], "\(walked)")

        app.newTab(in: home, agent: nil, startAgent: false)
        guard let extra = app.store.selected, extra !== loose, extra.groupID == nil else { return check("a second loose tab", false) }
        extra.customTitle = "extra"
        app.store.select(loose)
        let scope = app.closeScope(.others, of: loose)
        check(
            "Close Other Tabs takes the strip's tabs, the stashed island's apart",
            scope.drawn.map(\.title) == ["extra"] && Set(scope.hidden.map(\.title)) == Set(hidden.map(\.title)),
            "\(scope.drawn.map(\.title)) \(scope.hidden.map(\.title))")
        app.closeTabs(scope.drawn, hidden: scope.hidden)
        let asked = await eventually(15) { self.window.attachedSheet != nil }
        let box = asked ? Self.find(NSButton.self, in: window.attachedSheet?.contentView) { $0.accessibilityIdentifier() == "close.hiddenTabs" } : nil
        check("its question names the hidden island", box?.title.contains("“\(group.name)” (stashed)") == true, box?.title ?? "no box")
        check("with its box unticked", box?.state == .off)
        answerActivitySheet(.alertFirstButtonReturn)
        check(
            "closing leaves the stashed island's tabs",
            await eventually(5) { !self.app.store.tabs.contains { $0 === extra } } && hidden.allSatisfy { tab in self.app.store.tabs.contains { $0 === tab } },
            "\(app.store.tabs.map(\.title))")

        // Suspend Other Tabs: the strip's only, asked once with their names.
        app.newTab(in: home, agent: nil, startAgent: false)
        guard let other = app.store.selected, other !== loose else { return check("another loose tab", false) }
        other.customTitle = "other"
        app.confirmSuspend(app.store.drawnTabs.filter { $0 !== loose && !$0.isSuspended })
        let suspendAsked = await eventually(5) { self.window.attachedSheet != nil }
        let words = suspendAsked ? Self.find(NSTextField.self, in: window.attachedSheet?.contentView) { $0.stringValue.contains("“other”") } : nil
        check("Suspend Other Tabs asks, naming them", words != nil && words?.stringValue.contains("“\(hidden[0].title)”") == false, words?.stringValue ?? "no question")
        answerActivitySheet(.alertSecondButtonReturn)
        _ = await eventually(5) { self.window.attachedSheet == nil }
        check("and Cancel suspends nothing", !other.isSuspended && hidden.allSatisfy { !$0.isSuspended })
        app.closeTabsWithoutAsking([other])

        // A notification's tab, in the stashed island: back in the strip.
        app.reveal(tabID: hidden[0].id)
        check("a notification's tab comes off the shelf", !group.isStashed && app.store.selected === hidden[0] && app.store.isDrawn(hidden[0]))
        app.stashGroup(group)
        app.store.select(loose)
    }
}
#endif
