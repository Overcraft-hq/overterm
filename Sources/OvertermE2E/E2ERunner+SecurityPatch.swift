#if E2E
import AppKit
import Foundation

/// P01's fixes as a person sees them (Overcraft-hq/issue-tracker#11): a
/// note's remote image loads nothing until Load, and then through the app.
extension E2ERunner {
    func remoteImageChecks(_ reader: NoteReaderView) async {
        var page: [String: Any] = [:]
        func read() async {
            page = [:]
            reader.webView.evaluateJavaScript(
                """
                ({ holders: document.querySelectorAll('button.remote-image').length,
                   remote: [...document.querySelectorAll('img')].filter(i => /^https?:/.test(i.getAttribute('src') || '')).length,
                   shown: [...document.querySelectorAll('img')].filter(i => (i.getAttribute('src') || '').startsWith('data:image/png')).length })
                """
            ) { value, _ in page = (value as? [String: Any] ?? [:]) }
            _ = await eventually(2) { !page.isEmpty }
        }
        await read()
        check("a note's remote image is a Load button, not a request", page["holders"] as? Int == 1 && page["remote"] as? Int == 0, "\(page)")
        // Load, as its button does: the app fetches it (here a stand-in)
        // and the page shows what it hands back.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        reader.fetchRemote = { url in url.host == "images.example.test" ? NoteRemoteImage.accept(png, mimeType: "image/png", status: 200) : nil }
        _ = try? await reader.webView.evaluateJavaScript("document.querySelector('button.remote-image').click(); 0")
        check("Load has the app fetch it", await eventually(5) { reader.remoteImagesShown == 1 }, "\(reader.remoteImagesShown)")
        await read()
        check("and shows it as data", page["shown"] as? Int == 1 && page["holders"] as? Int == 0, "\(page)")
        reader.fetchRemote = { await NoteRemoteImage.fetch($0) }
    }

    /// MCP-G6: a feature's agent switch, changed in the file outside the
    /// page, is held as Kubernetes' are. SET-U1: the JSON view's draft
    /// follows the file while untouched, and asks once edited.
    func securityPatchSettingsChecks() async {
        let settings = Settings.shared
        let before = (try? String(contentsOf: settings.url, encoding: .utf8)) ?? "{}\n"
        let off = before.replacingOccurrences(of: "\n}", with: ",\n  \"browser.agentControl\": false\n}")
        try? off.write(to: settings.url, atomically: true, encoding: .utf8)
        _ = await eventually(4) { settings.held["browser.agentControl"] != nil || settings.bool("browser.agentControl") == false }
        settings.keep(settings.held)
        let on = (try? String(contentsOf: settings.url, encoding: .utf8))?.replacingOccurrences(of: "\"browser.agentControl\": false", with: "\"browser.agentControl\": true") ?? ""
        try? on.write(to: settings.url, atomically: true, encoding: .utf8)
        check("an agent turning the browser back on from the file is held", await eventually(4) { settings.held["browser.agentControl"] != nil }, "\(settings.held.keys.sorted())")
        check("and the browser stays closed to agents meanwhile", settings.bool("browser.agentControl") == false)
        settings.revert(settings.held)
        _ = await eventually(2) { settings.held.isEmpty }

        let page = app.settingsPage
        page.show(.general)
        page.mode = .json
        page.follow(saved: settings.fileText)
        let untouched = page.draft
        settings.set("appearance.unfocusedPaneDim", .double(0.41))
        page.follow(saved: settings.fileText)
        check("an untouched draft follows the file", page.draft == settings.fileText && page.draft != untouched && !page.draftConflict)
        page.draft = (page.draft ?? "") + "\n// typed"
        settings.set("appearance.unfocusedPaneDim", .double(0.42))
        page.follow(saved: settings.fileText)
        check("an edited one asks: Save waits", page.draftConflict && page.draft?.contains("// typed") == true)
        page.reload(saved: settings.fileText)
        check("Reload takes the file", !page.draftConflict && page.draft == settings.fileText)
        page.show(.general)
        // The file as it was, for the scenario's next checks.
        try? before.write(to: settings.url, atomically: true, encoding: .utf8)
        _ = await eventually(4) { settings.fileText == before }
        if !settings.held.isEmpty { settings.keep(settings.held) }
    }
}
#endif
