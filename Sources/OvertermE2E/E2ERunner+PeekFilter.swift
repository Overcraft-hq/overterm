#if E2E
import AppKit

/// Tab Peek shows what the strip offers (PEEK-U2) — no stashed island's
/// tabs, the focused island's alone — and is typed into (PEEK-U1): what
/// it doesn't find dimmed in place, 1–9 the nth found, ⌫ and Esc, and a
/// waiting card answered as the Inbox answers.
extension E2ERunner {
    package func peekFilterScenario() async {
        await waitForPrompt()
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let first = app.store.selected else { return check("a tab", false) }
        first.customTitle = "server"
        var tabs = [first]
        for (name, agent) in [("tests", nil), ("vite", nil), ("billing page", Agent.claude)] as [(String, Agent?)] {
            app.newTab(in: home, agent: agent, startAgent: false)
            guard let tab = app.store.selected, !tabs.contains(where: { $0 === tab }) else { return check("tab \(name)", false) }
            tab.customTitle = name
            tabs.append(tab)
        }
        guard let api = app.store.addToNewGroup(Array(tabs[0...1]), name: "shop-api"),
            let web = app.store.addToNewGroup(Array(tabs[2...3]), name: "web")
        else { return check("two islands", false) }
        let billing = tabs[3]
        func cardIDs() -> Set<Tab.ID> { Set(app.peek.model.cards.map(\.id)) }

        app.store.select(tabs[0])
        app.toggleTabPeek(nil)
        check("every tab of the strip gets a card", cardIDs() == Set(tabs.map(\.id)), "\(app.peek.model.cards.count)")
        app.peek.close()

        // PEEK-U2: a stashed island's tabs aren't in the strip, nor in the peek.
        app.store.stash(web)
        app.toggleTabPeek(nil)
        check("a stashed island's tabs get no card", cardIDs() == Set(tabs[0...1].map(\.id)), "\(app.peek.model.cards.count)")
        check("nor are their terminals shown", tabs[2...3].allSatisfy { app.host(of: $0)?.isHidden != false })
        app.peek.close()
        app.restoreGroup(web)
        app.store.setFocused(api)
        app.toggleTabPeek(nil)
        check("while focusing, only the focused island's tabs", cardIDs() == Set(tabs[0...1].map(\.id)), "\(app.peek.model.cards.count)")
        app.peek.close()
        app.store.setFocused(nil)

        // PEEK-U1: typed into.
        app.store.select(tabs[0])
        app.toggleTabPeek(nil)
        check("open on all four", app.peek.model.cards.count == 4, "\(app.peek.model.cards.count)")
        for character in "bill" { key(0, String(character)) }
        check("what is typed is the filter", await eventually(2) { self.app.peek.model.query == "bill" }, app.peek.model.query)
        check("the cards it doesn't find stay in place", app.peek.model.cards.count == 4)
        check("only the one it finds is reached", app.peek.model.shownCards.map(\.id) == [billing.id], "\(app.peek.model.shownCards.count)")
        check("and it is highlighted", app.peek.model.highlighted == billing.id)
        key(51, "\u{7f}")
        check("⌫ takes a character off", app.peek.model.query == "bil", app.peek.model.query)
        key(53, "\u{1b}")
        check("Esc clears the filter first", await eventually(2) { self.app.peek.model.query.isEmpty && self.app.peek.isOpen })
        for character in "claude" { key(0, String(character)) }
        check("it finds by the agent too", app.peek.model.shownCards.map(\.id) == [billing.id], "\(app.peek.model.shownCards.count)")
        key(53, "\u{1b}")
        for character in "vite" { key(0, String(character)) }
        key(18, "1")
        check("1 picks the first card found", await eventually(2) { !self.app.peek.isOpen && self.app.store.selected === tabs[2] }, app.store.selected?.title ?? "none")

        // A waiting card offers its question's answers, typed as the Inbox's are.
        let question = """
            Do you want to make this edit?
            ❯ 1. Yes
              2. No, and tell Claude what to do differently
            """
        try? question.write(to: out("peek-prompt.txt"), atomically: true, encoding: .utf8)
        billing.terminal.insertText("clear; cat \(out("peek-prompt.txt").path)")
        billing.terminal.pressReturn()
        check("the agent asks", await eventually(10) { (billing.terminal.visibleText ?? "").contains("2. No, and tell") })
        billing.activity.handle(.notification(title: "Claude", body: "needs your permission"), visible: false)
        app.store.select(tabs[0])
        app.toggleTabPeek(nil)
        guard let prompt = app.peek.model.entries[billing.id]?.prompt else {
            return check("the waiting card has its question's answers", false, "\(billing.activity.mark)")
        }
        check("the waiting card has its question's answers", prompt.choices.map(\.key) == ["1", "2"], "\(prompt.choices.map(\.key))")
        check("a card that asks nothing has none", app.peek.model.entries[tabs[0].id]?.prompt == nil)
        app.peek.answer(prompt.choices[0], on: billing.id)
        check(
            "answering types the choice into the agent",
            await eventually(8) {
                let text = billing.terminal.visibleText ?? ""
                return text.contains("command not found: 1") || text.contains("no such entry in dir stack")
            }, String((billing.terminal.visibleText ?? "").suffix(60)).debugDescription)
        check("the card offers it no more", app.peek.model.entries[billing.id]?.prompt == nil)
        check("and the peek stays open for the rest", app.peek.isOpen)
        key(53, "\u{1b}")
        check("Esc with nothing typed closes it", await eventually(2) { !self.app.peek.isOpen })
    }
}
#endif
