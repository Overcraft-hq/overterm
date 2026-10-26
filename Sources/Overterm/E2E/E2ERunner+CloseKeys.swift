import AppKit

/// ⌘W, pressed — through the window as a key, not a call — closes the tab
/// it is on, in an island as out of one.
extension E2ERunner {
    func closeKeysScenario() async {
        func commandW() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
                keyCode: 13)!
        }
        guard let loose = app.store.selected else { return check("a tab", false) }
        loose.customTitle = "loose"
        var inIsland: [Tab] = []
        for name in ["a", "b"] {
            app.newTab(nil)
            guard let tab = app.store.selected else { return check("tab \(name)", false) }
            tab.customTitle = name
            inIsland.append(tab)
        }
        guard app.store.addToNewGroup(inIsland, name: "work") != nil else { return check("an island", false) }
        for (label, tab) in [("a loose tab", loose), ("a tab in an island", inIsland[1])] {
            app.store.select(tab)
            await pause(0.3)
            window.makeFirstResponder(tab.terminal)
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            // As AppKit routes a ⌘-key: the window's views first, then the
            // menu. (NSApp.sendEvent has no key window to give it to while
            // an isolated run isn't the app in front.)
            let event = commandW()
            var by = "nobody"
            if window.performKeyEquivalent(with: event) {
                by = "a view"
            } else if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                by = "the menu"
            }
            let asked = await eventually(3) { self.window.attachedSheet != nil }
            check("⌘W on \(label) asks to close it", asked, "taken by \(by), first responder \(responder), selected \(app.store.selected?.title ?? "nil")")
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                _ = await eventually(2) { self.window.attachedSheet == nil }
            }
        }
    }
}
