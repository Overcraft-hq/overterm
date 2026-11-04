import AppKit

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
        check("back to the default sizes", await eventually(3) { SplitHostView.headerHeight == 38 && CardColumn.gap == 10 && ChromeMetrics.text(11) == 11 })
        check("all back to the user's Ghostty config", await eventually(3) { !written().contains("background-image") && !written().contains("font-feature") })
    }
}
