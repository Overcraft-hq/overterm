import AppKit
import SwiftUI

/// Colours for everything around the terminal (tab strip, sidebar), derived
/// from the terminal theme so the chrome reads as part of it: the selected
/// tab *is* the terminal's background, the chrome sits a step away from it.
struct ChromeTheme {
    let strip: Color
    let selected: Color
    let hover: Color
    let text: Color
    let dimText: Color

    @MainActor
    init(background: NSColor, foreground: NSColor) {
        let bg = background.usingColorSpace(.sRGB) ?? background
        let isDark = bg.brightnessComponent < 0.5
        let stripColor = isDark ? bg.blended(withFraction: 0.35, of: .black) : bg.blended(withFraction: 0.08, of: .black)
        strip = Color(nsColor: stripColor ?? bg)
        selected = Color(nsColor: bg)
        hover = Color(nsColor: bg.withAlphaComponent(0.5))
        text = Color(nsColor: foreground)
        dimText = Color(nsColor: foreground.withAlphaComponent(0.6))
    }
}
