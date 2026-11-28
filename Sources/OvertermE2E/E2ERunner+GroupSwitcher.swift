#if E2E
import AppKit

/// ⌃⌘G typed into (GRP-U1): typing filters the islands, → walks the
/// highlighted one's tabs, ↩ picks one, Esc clears the filter, then closes.
/// The keys are handed to the switcher's own handler, as its view hands
/// them on — no event is posted to the system.
extension E2ERunner {
    package func groupSwitcherScenario() async {
        await waitForPrompt()
        func key(_ code: UInt16, _ characters: String = "", option: Bool = false) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: option ? [.option] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: code)!
        }
        func type(_ text: String) { for character in text { _ = app.handleSwitcher(key: key(0, String(character))) } }
        guard let first = app.store.selected else { return check("a tab", false) }
        first.customTitle = "server"
        var tabs = [first]
        for name in ["tests", "vite", "billing page"] {
            app.newTab(nil)
            guard let tab = app.store.selected else { return check("tab \(name)", false) }
            tab.customTitle = name
            tabs.append(tab)
        }
        guard app.store.addToNewGroup(Array(tabs[0...1]), name: "shop-api") != nil,
            let web = app.store.addToNewGroup(Array(tabs[2...3]), name: "web")
        else { return check("two islands", false) }
        app.store.select(tabs[0])

        app.showGroupSwitcher(nil)
        check("⌃⌘G opens the switcher", app.switcherView?.isHidden == false)
        check("every island listed", app.switcherGroups.map(\.name) == ["shop-api", "web"], "\(app.switcherGroups.map(\.name))")
        type("bill")
        check("typing filters the islands, by a tab's title too", app.switcherGroups.map(\.name) == ["web"], "\(app.switcherGroups.map(\.name))")
        check("what was typed is shown", app.store.switcherQuery == "bill")
        check("the one left is highlighted", app.store.switcherHighlight == web.id)
        check("its tab column has the tab that matched", app.switcherTabs(of: web).map(\.title) == ["billing page"], "\(app.switcherTabs(of: web).map(\.title))")
        _ = app.handleSwitcher(key: key(51))
        _ = app.handleSwitcher(key: key(51))
        check("⌫ takes characters off", app.store.switcherQuery == "bi")
        app.escapeGroupSwitcher()
        check("Esc clears the filter first", app.store.switcherQuery.isEmpty && app.switcherView?.isHidden == false)
        type("web")
        _ = app.handleSwitcher(key: key(124))
        check("→ goes into the island's tabs", app.store.switcherTab == tabs[2].id, "\(String(describing: app.store.switcherTab))")
        _ = app.handleSwitcher(key: key(125))
        check("↓ walks them", app.store.switcherTab == tabs[3].id)
        _ = app.handleSwitcher(key: key(123))
        check("← goes back to the islands", app.store.switcherTab == nil)
        _ = app.handleSwitcher(key: key(124))
        _ = app.handleSwitcher(key: key(125))
        _ = app.handleSwitcher(key: key(36, "\r"))
        check("↩ on a tab picks that tab", app.store.selected === tabs[3] && app.switcherView?.isHidden == true, app.store.selected?.title ?? "none")

        app.showGroupSwitcher(nil)
        check("a new switcher starts unfiltered", app.store.switcherQuery.isEmpty && app.store.switcherTab == nil)
        app.escapeGroupSwitcher()
        check("Esc with nothing typed closes it", app.switcherView?.isHidden == true)
    }
}
#endif
