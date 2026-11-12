import AppKit

/// D-7 (docs/design/terraform/analysis.md 5.8): settings.json written
/// outside the page — as an agent could — changes a security setting only
/// after the window's banner is answered; the rest of the edit applies at
/// once. Revert writes the value before back; Keep takes the new one; the
/// page's own edit applies without asking.
extension E2ERunner {
    func heldSettingsChecks() async {
        let settings = Settings.shared
        func fileText() -> String { (try? String(contentsOf: settings.url, encoding: .utf8)) ?? "" }
        guard let banner = app.settingsHeldBanner else { return check("the window has the settings banner", false) }
        // The banner's own buttons are pressed through the accessibility
        // tree, as VoiceOver would — this process's own, no synthetic input.
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        check("no banner while nothing is held", banner.isHidden && settings.held.isEmpty)

        // An agent's edit: a context named for agents' writes, made local, and an ordinary setting.
        let outside = """
            {
              // mine
              "appearance.unfocusedPaneDim": 0.5,
              "kubernetes.agentWrites": ["acme-prod"],
              "kubernetes.contexts": { "acme-prod": { "class": "local", "writable": true } }
            }

            """
        try? outside.write(to: settings.url, atomically: true, encoding: .utf8)
        check("an outside edit of a security setting is held", await eventually(4) { settings.held.count == 2 }, "\(settings.held.keys.sorted())")
        check("the banner shows", await eventually(2) { !banner.isHidden && banner.fittingSize.height > 20 }, "\(banner.fittingSize)")
        let lines = SettingsHeldBanner.lines(settings.held)
        check(
            "it says what changed",
            lines == [
                "kubernetes.agentWrites: adds \"acme-prod\"",
                "kubernetes.contexts: \"acme-prod\" added (class: \"local\", writable: true)",
            ], "\(lines)")
        check(
            "the value before stays in effect",
            settings.kubernetesAgentWrites.isEmpty && settings.kubernetesContexts["acme-prod"] == nil
                && KubernetesModel.shared.agentWrites.isEmpty)
        check("the rest of the edit applies at once", settings.unfocusedPaneDim == 0.5)
        let strip = window.contentLayoutRect.maxY
        let frame = banner.convert(banner.bounds, to: nil)
        check("under the title bar, not over the strip", frame.maxY <= strip + 0.5 && frame.minY > 0, "\(frame) / \(strip)")

        check("the whole change fits: Keep is in the banner", await eventually(2) { Self.accessibilityPress("settings.held.keep", in: banner, press: false) })
        check("its Revert pressed", Self.accessibilityPress("settings.held.revert", in: banner))
        check("Revert hides the banner", await eventually(2) { banner.isHidden } && settings.held.isEmpty)
        check(
            "and writes the value before back, the rest of the file kept",
            !fileText().contains("kubernetes.agentWrites") && !fileText().contains("acme-prod") && fileText().contains("// mine")
                && fileText().contains("\"appearance.unfocusedPaneDim\": 0.5"), fileText())
        await pause(0.5)
        check("the watcher doesn't hold Revert's own write", settings.held.isEmpty && banner.isHidden)

        // Again, kept this time.
        try? outside.write(to: settings.url, atomically: true, encoding: .utf8)
        check("held again", await eventually(4) { settings.held.count == 2 && !banner.isHidden })
        check("its Keep pressed", await eventually(2) { Self.accessibilityPress("settings.held.keep", in: banner) })
        check("Keep hides the banner", await eventually(2) { banner.isHidden })
        check(
            "and the new values take effect",
            settings.kubernetesAgentWrites == ["acme-prod"] && settings.kubernetesContexts["acme-prod"]?.contextClass == .local
                && KubernetesModel.shared.agentWrites == ["acme-prod"])

        // The page's own edit: at once, no banner.
        settings.set("kubernetes.agentWrites", nil)
        settings.set("kubernetes.contexts", nil)
        await pause(0.5)
        check("the page's edits apply without asking", settings.held.isEmpty && banner.isHidden && settings.kubernetesAgentWrites.isEmpty)
        // More than the banner holds — names put ahead of a production one:
        // no Keep there, only a review of every line.
        let decoys = (0..<40).map { "\"a\(String(format: "%02d", $0))\"" }.joined(separator: ", ")
        try? "{\n  \"kubernetes.agentWrites\": [\(decoys), \"acme-prod\"]\n}\n".write(to: settings.url, atomically: true, encoding: .utf8)
        check("a long change is held", await eventually(4) { settings.held.count == 1 && !banner.isHidden })
        check("its last name is in the lines", SettingsHeldBanner.lines(settings.held).last == "kubernetes.agentWrites: adds \"acme-prod\"")
        check(
            "the banner offers a review, not Keep",
            await eventually(2) { Self.accessibilityPress("settings.held.review", in: banner, press: false) }
                && !Self.accessibilityPress("settings.held.keep", in: banner, press: false))
        check("its Revert pressed", Self.accessibilityPress("settings.held.revert", in: banner))
        check("reverted", await eventually(2) { banner.isHidden && settings.held.isEmpty } && settings.kubernetesAgentWrites.isEmpty)

        try? "{\n  // mine\n  \"appearance.unfocusedPaneDim\": 0.6\n}\n".write(to: settings.url, atomically: true, encoding: .utf8)
        check("back as it was", await eventually(4) { settings.unfocusedPaneDim == 0.6 } && settings.held.isEmpty)
    }

    /// Finds the element `identifier` names under `root` in the
    /// accessibility tree and, with `press`, presses it (`accessibilityPerformPress`).
    static func accessibilityPress(_ identifier: String, in root: NSView, press: Bool = true) -> Bool {
        func get(_ object: NSObject, _ key: String) -> Any? { object.responds(to: Selector(key)) ? object.value(forKey: key) : nil }
        var walked: Set<ObjectIdentifier> = []
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 80, walked.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return nil }
            if get(object, "accessibilityIdentifier") as? String == identifier { return object }
            var children = (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
            if let view = object as? NSView { children += view.subviews }
            for child in children { if let found = find(child, depth: depth + 1) { return found } }
            return nil
        }
        guard let element = find(root, depth: 0) else { return false }
        guard press else { return true }
        // It answers a BOOL: called through Objective-C's own declaration, not `perform`.
        return (element as AnyObject).accessibilityPerformPress?() ?? false
    }
}
