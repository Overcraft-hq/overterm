import AppKit

/// The chrome's sizes, from Settings ▸ Appearance ▸ Interface: how dense
/// (the strip, the pane headers, the rows), how large its text, and how
/// its cards sit on the window.
///
/// Read from anywhere, as `CardColumn.gap` and the rest were: plain values,
/// set on the main thread when a setting changes (`apply`), after which the
/// windows lay themselves out again (`TerminalWindowController.applyMetrics`).
/// A view's literal stays where it was — `.system(size: ChromeMetrics.text(11))`
/// reads as 11 at 100%.
enum ChromeMetrics {
    enum Density: String, CaseIterable, Sendable {
        case compact, regular, comfortable

        var label: String { rawValue.capitalized }

        /// How a row's height moves with it.
        var rowFactor: CGFloat {
            switch self {
            case .compact: 0.86
            case .regular: 1
            case .comfortable: 1.14
            }
        }
    }

    nonisolated(unsafe) private(set) static var density: Density = .regular
    /// The interface's text size, 1 at 100%.
    nonisolated(unsafe) private(set) static var textScale: CGFloat = 1
    nonisolated(unsafe) private(set) static var cardGap: CGFloat = 10
    nonisolated(unsafe) private(set) static var cardRadius: CGFloat = 10

    enum TabWidth: String, CaseIterable, Sendable {
        case narrow, regular, wide

        var label: String { rawValue.capitalized }
        /// A tab's least, preferred and most width in the strip.
        var range: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
            switch self {
            case .narrow: (56, 140, 150)
            case .regular: (72, 200, 220)
            case .wide: (90, 260, 300)
            }
        }
    }

    nonisolated(unsafe) private(set) static var tabWidth: TabWidth = .regular
    /// The × on every tab, not only the selected one and the one under the pointer.
    nonisolated(unsafe) private(set) static var tabCloseAlways = false
    /// What a tab is, as an icon before its name; off, only a badge when it has news.
    nonisolated(unsafe) private(set) static var tabIcons = true

    /// The settings that are these.
    static let keys: Set<String> = [
        "appearance.density", "appearance.interfaceScale", "appearance.cardGap", "appearance.cardRadius", "appearance.paneHeaders",
        "appearance.tabWidth", "appearance.tabClose", "appearance.tabIcons",
    ]

    /// From the settings; whether anything changed.
    @MainActor @discardableResult
    static func apply(_ settings: Settings = .shared) -> Bool {
        let sizes = (density, textScale, cardGap, cardRadius)
        let tabs = (tabWidth, tabCloseAlways, tabIcons)
        tabWidth = TabWidth(rawValue: settings.string("appearance.tabWidth")) ?? .regular
        tabCloseAlways = settings.string("appearance.tabClose") == "always"
        tabIcons = settings.value("appearance.tabIcons")?.bool ?? true
        density = Density(rawValue: settings.string("appearance.density")) ?? .regular
        textScale = CGFloat(min(max(settings.number("appearance.interfaceScale") ?? 100, 80), 140)) / 100
        cardGap = CGFloat(min(max(settings.number("appearance.cardGap") ?? 10, 0), 24))
        cardRadius = CGFloat(min(max(settings.number("appearance.cardRadius") ?? 10, 0), 20))
        return sizes != (density, textScale, cardGap, cardRadius) || tabs != (tabWidth, tabCloseAlways, tabIcons)
    }

    /// A text size at the interface's scale, rounded to a half point.
    static func text(_ size: CGFloat) -> CGFloat { (size * textScale * 2).rounded() / 2 }

    /// A row's height: denser or roomier, and as tall as its text needs.
    static func row(_ height: CGFloat) -> CGFloat { (height * density.rowFactor * max(1, textScale)).rounded() }

    /// A tab, and the islands beside it, in the strip — which lives in the
    /// 52 pt title bar, so no taller than fits there.
    static var tabHeight: CGFloat { min(row(36), 46) }
    /// Every terminal pane's header.
    static var paneHeaderHeight: CGFloat { row(38) }
}
