import AppKit
import SwiftUI

/// Settings ▸ Appearance: the terminal's look, written for Ghostty and taken
/// up live; the window translucent; a background image. Photographed with
/// OVERTERM_DUMP_PNG.
extension E2ERunner {
    func appearanceScenario() async {
        await waitForPrompt()
        let settings = Settings.shared
        let overrides = Settings.ghosttyOverridesFile
        func written() -> String { (try? String(contentsOf: overrides, encoding: .utf8)) ?? "" }
        func photo(_ suffix: String) async {
            guard let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty else { return }
            await pause(0.6)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-\(suffix).png")
        }
        let terminal = app.store.selected?.terminal
        terminal?.insertText("printf '\\033[1mbold\\033[0m => != -> ok\\n'", replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal?.pressReturn()

        // The text and the colours: Ghostty's options, from one place.
        settings.set("appearance.ligatures", .bool(false))
        settings.set("appearance.lineHeight", .int(20))
        settings.set("appearance.cursorColor", .string("#ff8800"))
        settings.set("appearance.boldIsBright", .bool(true))
        check(
            "the look is written for Ghostty",
            await eventually(3) {
                let text = written()
                return text.contains("font-feature = -calt") && text.contains("adjust-cell-height = 20%")
                    && text.contains("cursor-color = #ff8800") && text.contains("bold-color = bright")
            }, written())

        // Translucent: the window, not the surfaces, paints the ground.
        settings.set("appearance.backgroundOpacity", .double(0.8))
        check(
            "translucent: the window lets the desktop through",
            await eventually(3) { self.window.isOpaque == false && self.app.theme?.isTranslucent == true }, "opaque \(window.isOpaque)")
        check("the surfaces paint at the opacity, blurred", written().contains("background-opacity = 0.8") && written().contains("background-blur = true"), written())
        let ground = window.contentView?.subviews.first { $0 is WindowGroundView } as? WindowGroundView
        check("the window's own background is clear", (window.backgroundColor?.alphaComponent ?? 1) == 0, String(describing: window.backgroundColor))
        check(
            "one ground, at the opacity, behind everything",
            ground?.isHidden == false && abs((ground?.color.alphaComponent ?? 0) - 0.8) < 0.01 && window.contentView?.subviews.first === ground,
            String(describing: ground?.color))
        check("cut away under the terminal", ground?.holes().count == 1, "\(ground?.holes().count ?? -1) holes")
        check("a panel is only a veil over it", (app.sidebarCardFill?.alphaComponent ?? 1) < 0.1, "\(String(describing: app.sidebarCardFill))")
        await photo("translucent")
        settings.set("appearance.backgroundOpacity", nil)
        check(
            "opaque again", await eventually(3) { self.window.isOpaque && self.app.theme?.isTranslucent == false && ground?.isHidden == true })
        check("and nothing of it is written", await eventually(3) { !written().contains("background-opacity") }, written())

        // A background image, behind every terminal's text.
        let image = scratch.appendingPathComponent("sky.png")
        let picture = NSImage(size: NSSize(width: 64, height: 64))
        picture.lockFocus()
        NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: 45)
        picture.unlockFocus()
        if let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: image)
        }
        settings.set("appearance.backgroundImage", .string(image.path))
        check(
            "a background image is written with its opacity and fit",
            await eventually(3) {
                written().contains("background-image = \"\(image.path)\"") && written().contains("background-image-opacity = 0.25")
                    && written().contains("background-image-fit = cover")
            }, written())
        await photo("image")
        for key in [
            "appearance.backgroundImage", "appearance.ligatures", "appearance.lineHeight", "appearance.cursorColor", "appearance.boldIsBright",
        ] {
            settings.set(key, nil)
        }
        // The interface: an accent, density, text size, cards.
        settings.set("appearance.accent", .string("pink"))
        check("an accent colour", await eventually(2) { (self.app.theme?.accentNS.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.9 })
        guard let tab = app.store.selected, let host = app.host(of: tab), let pane = tab.terminals.first else {
            return check("a pane", false)
        }
        settings.set("appearance.density", .string("compact"))
        check(
            "compact: the pane header is shorter", await eventually(3) { abs((host.header(of: pane)?.frame.height ?? 0) - SplitHostView.headerHeight) < 0.5 && SplitHostView.headerHeight < 38 },
            "\(host.header(of: pane)?.frame.height ?? 0)")
        // Larger text makes the rows as tall as it needs, compact or not.
        settings.set("appearance.interfaceScale", .int(120))
        check("larger text: taller rows again", await eventually(3) { SplitHostView.headerHeight > 32.5 })
        check("the interface's text at 120%", ChromeMetrics.text(10) == 12)
        settings.set("appearance.cardGap", .int(0))
        settings.set("appearance.cardRadius", .int(0))
        check(
            "cards edge to edge, square",
            await eventually(3) {
                guard let body = self.app.split.view.superview, let content = self.window.contentView else { return false }
                return abs(content.frame.maxX - body.convert(body.bounds, to: content).maxX) < 0.5 && CardColumn.cornerRadius == 0
            })
        await photo("compact")
        settings.set("appearance.density", .string("comfortable"))
        settings.set("appearance.interfaceScale", nil)
        settings.set("appearance.cardGap", .int(16))
        settings.set("appearance.cardRadius", .int(16))
        check("comfortable: taller", await eventually(3) { abs((host.header(of: pane)?.frame.height ?? 0) - SplitHostView.headerHeight) < 0.5 && SplitHostView.headerHeight > 38 })
        await photo("comfortable")
        for key in ["appearance.accent", "appearance.density", "appearance.cardGap", "appearance.cardRadius"] { settings.set(key, nil) }

        // A lone pane without its header; split, every pane has one again.
        settings.set("appearance.paneHeaders", .string("whenSplit"))
        check(
            "one pane: no header, the terminal takes its room",
            await eventually(3) { host.header(of: pane)?.isHidden == true && abs(pane.frame.minY) < 0.5 }, "\(pane.frame)")
        app.splitRight(nil)
        check(
            "split: both panes have their header",
            await eventually(3) { tab.terminals.count == 2 && tab.terminals.allSatisfy { host.header(of: $0)?.isHidden == false } })
        // A shell's own exit closes its pane without asking.
        if let second = tab.terminals.last, second !== pane {
            _ = await eventually(5) { second.surface != nil }
            await pause(0.5)
            second.insertText("exit", replacementRange: NSRange(location: NSNotFound, length: 0))
            second.pressReturn()
        }
        check("one again: gone again", await eventually(8) { tab.terminals.count == 1 && host.header(of: pane)?.isHidden == true })
        settings.set("appearance.paneHeaders", nil)
        check("always: back", await eventually(3) { host.header(of: pane)?.isHidden == false })

        // The strip: narrow tabs, a close button on each, no icons.
        app.newTab(nil)
        await waitForPrompt()
        settings.set("appearance.tabWidth", .string("narrow"))
        settings.set("appearance.tabClose", .string("always"))
        settings.set("appearance.tabIcons", .bool(false))
        check(
            "narrow tabs", await eventually(3) { self.app.store.tabs.allSatisfy { (self.app.store.tabFrames[$0.id]?.width ?? 999) <= 154 } },
            app.store.tabs.map { "\(self.app.store.tabFrames[$0.id]?.width ?? -1)" }.joined(separator: ", "))
        check("every tab's ×, no icons", ChromeMetrics.tabCloseAlways && !ChromeMetrics.tabIcons)
        await pause(1.0)
        await photo("tabs")
        for key in ["appearance.tabWidth", "appearance.tabClose", "appearance.tabIcons"] { settings.set(key, nil) }
        check("regular tabs again", await eventually(3) { ChromeMetrics.tabWidth == .regular && ChromeMetrics.tabIcons })
        check("back to the default sizes", await eventually(3) { SplitHostView.headerHeight == 38 && CardColumn.gap == 10 && ChromeMetrics.text(11) == 11 })
        // Another app's theme, imported: a file of Ghostty's in the user's folder.
        let itermFile = scratch.appendingPathComponent("Sunset.itermcolors")
        func entry(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
            ["Red Component": red, "Green Component": green, "Blue Component": blue, "Color Space": "sRGB"]
        }
        var plist: [String: Any] = ["Background Color": entry(0.16, 0.08, 0.14), "Foreground Color": entry(0.98, 0.9, 0.85)]
        for index in 0...15 { plist["Ansi \(index) Color"] = entry(Double(index % 8) / 7, 0.4, 0.6) }
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: itermFile)
        let catalog = ThemeCatalog.shared
        let (saved, problem) = catalog.importFiles([itermFile])
        check("an iTerm2 theme imports", saved == ["Sunset"] && problem == nil, "\(saved) \(problem ?? "")")
        check(
            "into the user's themes, where Ghostty reads them",
            ThemeCatalog.writableDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sunset").path) } == true)
        check(
            "and the gallery lists it as yours",
            await eventually(5) { catalog.isLoaded && catalog.entries.contains { $0.theme.name == "Sunset" && $0.source == .user } })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty,
            let sunset = catalog.entries.first(where: { $0.theme.name == "Sunset" }), let theme = app.theme
        {
            let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            editor.isReleasedWhenClosed = false
            editor.contentView = NSHostingView(rootView: ThemeEditorView(target: .init(entry: sunset, duplicate: true), theme: theme) { _ in })
            editor.setContentSize(editor.contentView!.fittingSize)
            editor.orderFront(nil)
            await pause(0.6)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-editor.png", window: editor)
            editor.close()
        }
        // The editor in the terminal theme's colours.
        let code = scratch.appendingPathComponent("look.swift")
        try? "func greet() -> String { \"hi\" }\n".write(to: code, atomically: true, encoding: .utf8)
        app.openInEditor(code)
        if let editor = app.editor {
            _ = await eventually(5) { editor.active?.url?.lastPathComponent == "look.swift" }
            func keyword() -> NSColor? {
                (editor.textView.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            }
            let magenta = GhosttyRuntime.shared.paletteColor(5)?.usingColorSpace(.sRGB)
            settings.set("editor.theme", .string("terminal"))
            check("the editor's keywords in the terminal's magenta", await eventually(5) { keyword() == magenta }, "\(String(describing: keyword())) vs \(String(describing: magenta))")
            settings.set("editor.theme", nil)
            check("and One Dark's again", await eventually(5) { keyword() != nil && keyword() != magenta })
        } else {
            check("an editor", false)
        }
        // Presentation mode: the terminal alone and larger, and back.
        if let present = menuItem("View", "Presentation Mode"), let selected = app.store.selected, let host = app.host(of: selected) {
            let pane = selected.terminal
            let before = pane.inheritedSettings().fontSize ?? 0
            let sidebarOpen = app.sidebarItem?.isCollapsed == false
            let editorOpen = app.editorItem?.isCollapsed == false
            check("presenting starts with something beside the terminal", sidebarOpen || editorOpen)
            _ = perform(present)
            check(
                "presenting: the columns shut, no header, a larger font",
                await eventually(4) {
                    self.app.sidebarItem?.isCollapsed == true && self.app.editorItem?.isCollapsed == true
                        && host.header(of: pane)?.isHidden == true && (pane.inheritedSettings().fontSize ?? 0) >= before + 5
                }, "font \(pane.inheritedSettings().fontSize ?? 0) from \(before)")
            NSApp.mainMenu?.update()
            check("the menu says so", app.isPresenting && app.validateMenuItem(present) && present.state == .on)
            _ = perform(present)
            check(
                "and back as it was",
                await eventually(4) {
                    (self.app.sidebarItem?.isCollapsed == false) == sidebarOpen && (self.app.editorItem?.isCollapsed == false) == editorOpen
                        && host.header(of: pane)?.isHidden == false && abs((pane.inheritedSettings().fontSize ?? 0) - before) < 0.5
                }, "font \(pane.inheritedSettings().fontSize ?? 0) from \(before)")
        } else {
            check("View ▸ Presentation Mode", false)
        }
        check("all back to the user's Ghostty config", await eventually(3) { !written().contains("background-image") && !written().contains("font-feature") })
    }
}
