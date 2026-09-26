import AppKit
import SwiftUI

/// Colours for everything around the terminal (tab strip, sidebar), derived
/// from the terminal theme so the chrome reads as part of it: the selected
/// tab *is* the terminal's background, the chrome sits a step away from it.
struct ChromeTheme {
    let strip: Color
    /// Whether the terminal theme is dark — AppKit chrome (popovers, their
    /// buttons) takes the matching appearance.
    let isDark: Bool
    /// The strip colour for AppKit views.
    let stripNS: NSColor
    let selected: Color
    let hover: Color
    let text: Color
    /// The text colour for AppKit (and SyntaxPalette, which fades it for comments).
    let textNS: NSColor
    let dimText: Color

    @MainActor
    init(background: NSColor, foreground: NSColor) {
        let bg = background.usingColorSpace(.sRGB) ?? background
        let isDark = bg.brightnessComponent < 0.5
        self.isDark = isDark
        let stripColor = isDark ? bg.blended(withFraction: 0.35, of: .black) : bg.blended(withFraction: 0.08, of: .black)
        stripNS = stripColor ?? bg
        strip = Color(nsColor: stripNS)
        selected = Color(nsColor: bg)
        hover = Color(nsColor: bg.withAlphaComponent(0.5))
        text = Color(nsColor: foreground)
        textNS = foreground
        dimText = Color(nsColor: foreground.withAlphaComponent(0.6))
    }
}
