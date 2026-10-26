import AppKit

/// Full screen keeps the tab strip on screen: it is the title bar, and a
/// full-screen window's title bar is hidden — with it went every tab.
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
        window.toggleFullScreen(nil)
        let entered = await eventually(8) { self.window.styleMask.contains(.fullScreen) }
        check("the window goes full screen", entered)
        await pause(1.5)
        let onScreen = strip.window.map { $0.convertToScreen(strip.convert(strip.bounds, to: nil)) } ?? .zero
        let screen = window.screen?.frame ?? .zero
        let top = screen.maxY - (window.screen?.safeAreaInsets.top ?? 0)
        let report = "strip \(onScreen) screen \(screen) usable top \(top) window \(window.frame)"
        FileHandle.standardError.write(Data("fullscreen: \(report)\n".utf8))
        check("the strip is on screen, under the menu bar's band", onScreen.height > 40 && onScreen.maxY <= top + 1 && onScreen.minY >= screen.minY, report)
        check("and the tabs in it", app.store.tabFrames.values.contains { $0.width > 0 })
        // The menu bar hides only for the app in front, which an isolated
        // run never is: what the window asks AppKit for is checked instead.
        let asked = app.window(window, willUseFullScreenPresentationOptions: [.fullScreen, .autoHideMenuBar, .autoHideToolbar])
        check("full screen never hides the toolbar the strip lives in", !asked.contains(.autoHideToolbar) && asked.contains(.autoHideMenuBar))
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty { app.captureWindow(to: png) }
        window.toggleFullScreen(nil)
        check("and comes back", await eventually(8) { !self.window.styleMask.contains(.fullScreen) })
        await pause(1)
    }
}
