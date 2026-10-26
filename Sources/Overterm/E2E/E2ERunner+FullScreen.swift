import AppKit

/// Full screen keeps the tab strip on screen and uncovered: AppKit puts a
/// full-screen window's title bar and toolbar in a window of their own over
/// the top of it. OVERTERM_E2E_ACTIVATE=1 brings the run to the front, as
/// the user's app is — the toolbar's window only shows for the app in front.
extension E2ERunner {
    func fullScreenScenario() async {
        guard let strip = app.tabBarView else { return check("a strip", false) }
        // A screen with a camera housing when there is one: there the band
        // over the menu bar is the screen's, and the strip went under it.
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let area = notched.visibleFrame
            window.setFrame(NSRect(x: area.minX + 40, y: area.minY + 40, width: 1000, height: 640), display: true)
            await pause(0.5)
        }
        print("E2E INFO fullScreen: on \(window.screen?.localizedName ?? "?") (top inset \(window.screen?.safeAreaInsets.top ?? 0))")
        // In front, as the user's is: the menu bar — and the toolbar with
        // it — hide only for the app in front.
        if ProcessInfo.processInfo.environment["OVERTERM_E2E_ACTIVATE"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.toggleFullScreen(nil)
        let entered = await eventually(8) { self.window.styleMask.contains(.fullScreen) }
        check("the window goes full screen", entered)
        await pause(3)
        // What is on top at the strip's middle: our window, or something
        // over it (the full-screen toolbar's own window).
        let middle = strip.window.map { $0.convertToScreen(strip.convert(strip.bounds, to: nil)) } ?? .zero
        let probe = NSPoint(x: middle.midX, y: middle.midY)
        let onTop = NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0)
        let others = NSApp.windows.filter { $0.isVisible && $0 !== window }.map {
            "\(Swift.type(of: $0)) \($0.frame) level \($0.level.rawValue) #\($0.windowNumber)"
        }
        print("E2E INFO fullScreen: strip \(middle), on top at its middle #\(onTop) (ours #\(window.windowNumber)), active \(NSApp.isActive); others: \(others)")
        check("nothing covers the strip", onTop == window.windowNumber || !NSApp.isActive, "#\(onTop) over it; \(others)")
        let onScreen = strip.window.map { $0.convertToScreen(strip.convert(strip.bounds, to: nil)) } ?? .zero
        let screen = window.screen?.frame ?? .zero
        let top = screen.maxY - (window.screen?.safeAreaInsets.top ?? 0)
        let report = "strip \(onScreen) screen \(screen) usable top \(top) window \(window.frame)"
        FileHandle.standardError.write(Data("fullscreen: \(report)\n".utf8))
        check("the strip is on screen, under the menu bar's band", onScreen.height > 40 && onScreen.maxY <= top + 1 && onScreen.minY >= screen.minY, report)
        check("and the tabs in it", app.store.tabFrames.values.contains { $0.width > 0 })
        check("full screen has no toolbar to cover the strip", window.toolbar == nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty { app.captureWindow(to: png) }
        window.toggleFullScreen(nil)
        check("and comes back", await eventually(8) { !self.window.styleMask.contains(.fullScreen) })
        check("with its toolbar again", await eventually(3) { self.window.toolbar != nil })
        await pause(1)
    }
}
