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

    /// The settings that are these.
    static let keys: Set<String> = ["appearance.density", "appearance.interfaceScale", "appearance.cardGap", "appearance.cardRadius"]

    /// From the settings; whether anything changed.
    @MainActor @discardableResult
    static func apply(_ settings: Settings = .shared) -> Bool {
        let before = (density, textScale, cardGap, cardRadius)
        density = Density(rawValue: settings.string("appearance.density")) ?? .regular
        textScale = CGFloat(min(max(settings.number("appearance.interfaceScale") ?? 100, 80), 140)) / 100
        cardGap = CGFloat(min(max(settings.number("appearance.cardGap") ?? 10, 0), 24))
        cardRadius = CGFloat(min(max(settings.number("appearance.cardRadius") ?? 10, 0), 20))
        return before != (density, textScale, cardGap, cardRadius)
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
