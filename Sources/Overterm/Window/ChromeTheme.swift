import AppKit
import SwiftUI

/// Colours for everything around the terminal — the window ground, the
/// cards floating on it, the tab strip, the sidebar — derived from the
/// terminal theme so the chrome reads as part of it.
///
/// Three grounds, a step apart, and the order matters: `win` is the
/// window itself and shows only *between* the cards; `card` is a panel
/// (sidebar, changes, the palette); `term` is the terminal's own
/// background. Everything else is text, a hairline, or a tint over one
/// of the three.
///
/// A value type, built once per window and passed into each SwiftUI root
/// — there is no live rebuild, so a terminal theme change needs a
/// relaunch.
struct ChromeTheme {
    /// Whether the terminal theme is dark — AppKit chrome (popovers, their
    /// buttons) takes the matching appearance.
    let isDark: Bool

    // MARK: Grounds

    /// The window itself: what shows in the gaps between the cards.
    let win: Color
    let winNS: NSColor
    /// The hairline just inside the window's rounded edge.
    let winEdge: Color
    /// A panel card — the sidebar, the changes pane, a popover's body.
    let card: Color
    let cardNS: NSColor
    /// The terminal's own background, and so a terminal card's fill.
    let term: Color
    let termNS: NSColor
    /// The hairline around a card, and between a card's header and body.
    let border: Color
    let borderNS: NSColor
    /// What a card drops onto the window. Clear in a dark theme, where
    /// the hairline carries the separation on its own.
    let cardShadow: Color

    // MARK: Text

    /// Body text.
    let text: Color
    /// The text colour for AppKit (and SyntaxPalette, which fades it for comments).
    let textNS: NSColor
    /// Secondary text: a label beside the thing it names.
    let text2: Color
    /// Tertiary text: metadata you read only when you look for it.
    let text3: Color

    // MARK: Fills

    /// The tile behind a small glyph (a tab's kind icon).
    let iconBg: Color
    /// A selected row in a list.
    let rowSel: Color
    /// A hovered row in a list.
    let rowHover: Color
    /// The selected tab, which sits proud of the strip.
    let tabSel: Color
    /// Its hairline and its drop shadow.
    let tabSelEdge: Color
    let tabSelShadow: Color
    /// A menu's body and its edge — translucent, over anything.
    let menu: Color
    let menuEdge: Color
    /// The chip stack on a collapsed group, and an idle segment in its
    /// progress strip.
    let stackBg: Color
    let segIdle: Color

    // MARK: Status

    /// Behind "N need you".
    let attnBg: Color
    /// Status text, legible on `win` in both themes — the status *fills*
    /// stay the same hue in both (`TabStatusStyle`), only text shifts.
    let orangeText: Color
    let greenText: Color
    let accentText: Color

    // MARK: Compatibility
    //
    // The names the chrome used before it had a vocabulary. Each is one of
    // the tokens above; call sites move over as their views are redrawn.

    /// The tab strip's ground. The strip sits on the window.
    var strip: Color { win }
    var stripNS: NSColor { winNS }
    var selected: Color { tabSel }
    var hover: Color { rowHover }
    var dimText: Color { text2 }

    @MainActor
    init(background: NSColor, foreground: NSColor) {
        let bg = background.usingColorSpace(.sRGB) ?? background
        let fg = foreground.usingColorSpace(.sRGB) ?? foreground
        let isDark = bg.brightnessComponent < 0.5
        self.isDark = isDark

        func mix(_ base: NSColor, _ fraction: CGFloat, _ other: NSColor) -> NSColor {
            base.blended(withFraction: fraction, of: other) ?? base
        }
        /// An overlay that reads the same over any ground: white in a dark
        /// theme, black in a light one.
        func veil(_ alpha: CGFloat) -> Color {
            Color(nsColor: (isDark ? NSColor.white : .black).withAlphaComponent(alpha))
        }

        // Grounds. In a dark theme the window is a step *down* from the
        // terminal and the cards a step up; in a light one everything is a
        // step down from white, or the cards would be invisible.
        let winColor = mix(bg, isDark ? 0.35 : 0.08, .black)
        winNS = winColor
        win = Color(nsColor: winColor)
        winEdge = veil(0.10)
        let cardColor = isDark ? mix(bg, 0.02, .white) : mix(bg, 0.03, .black)
        cardNS = cardColor
        card = Color(nsColor: cardColor)
        termNS = bg
        term = Color(nsColor: bg)
        let borderColor = (isDark ? NSColor.white : .black).withAlphaComponent(0.08)
        borderNS = borderColor
        border = Color(nsColor: borderColor)
        cardShadow = isDark ? .clear : Color(nsColor: NSColor.black.withAlphaComponent(0.10))

        // Text. One hue, three weights of presence.
        textNS = fg
        text = Color(nsColor: fg)
        text2 = Color(nsColor: fg.withAlphaComponent(0.62))
        text3 = Color(nsColor: fg.withAlphaComponent(0.54))

        // Fills.
        iconBg = veil(isDark ? 0.08 : 0.06)
        rowSel = veil(isDark ? 0.08 : 0.06)
        rowHover = veil(isDark ? 0.05 : 0.04)
        // The selected tab is the terminal in a light theme (it is the
        // brightest thing there) and a lift off the window in a dark one.
        tabSel = Color(nsColor: isDark ? mix(bg, 0.10, .white) : bg)
        tabSelEdge = veil(isDark ? 0.12 : 0.10)
        tabSelShadow = Color(nsColor: NSColor.black.withAlphaComponent(isDark ? 0.40 : 0.12))
        menu = Color(nsColor: mix(isDark ? mix(bg, 0.18, .white) : mix(bg, 0.02, .black), 0.02, .white).withAlphaComponent(0.98))
        menuEdge = veil(isDark ? 0.18 : 0.15)
        stackBg = Color(nsColor: isDark ? mix(bg, 0.10, .white) : bg)
        segIdle = veil(isDark ? 0.28 : 0.22)

        // Status. The fills are `TabStatusStyle`'s; these are the texts and
        // tints that have to stay legible on `win`.
        attnBg = Color(nsColor: TabStatusStyle.waitingNS.withAlphaComponent(isDark ? 0.16 : 0.18))
        orangeText = isDark ? Color(red: 1.00, green: 0.70, blue: 0.25) : Color(red: 0.60, green: 0.29, blue: 0.00)
        greenText = isDark ? Color(red: 0.36, green: 0.84, blue: 0.48) : Color(red: 0.10, green: 0.50, blue: 0.22)
        accentText = isDark ? Color(red: 0.39, green: 0.82, blue: 1.00) : Color(red: 0.04, green: 0.38, blue: 0.79)
    }
}
