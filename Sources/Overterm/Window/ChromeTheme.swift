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
/// One object per window, handed to every SwiftUI root and kept: a theme
/// picked in Settings changes the colours in place and the chrome follows
/// without a relaunch (`TerminalWindowController.applyTerminalColors`).
/// The views observe it; the AppKit pieces (the window's own background,
/// the cards' fills, the dividers) are repainted by hand, since a layer
/// colour is nobody's binding.
@MainActor
final class ChromeTheme: ObservableObject {
    /// Whether the terminal theme is dark — AppKit chrome (popovers, their
    /// buttons) takes the matching appearance.
    private(set) var isDark: Bool = false

    // MARK: Grounds

    /// The window itself: what shows in the gaps between the cards.
    private(set) var win: Color = Color.clear
    private(set) var winNS: NSColor = NSColor.clear
    /// The hairline just inside the window's rounded edge.
    private(set) var winEdge: Color = Color.clear
    /// A panel card — the sidebar, the changes pane, a popover's body.
    private(set) var card: Color = Color.clear
    private(set) var cardNS: NSColor = NSColor.clear
    /// The terminal's own background, and so a terminal card's fill.
    private(set) var term: Color = Color.clear
    private(set) var termNS: NSColor = NSColor.clear
    /// The hairline around a card, and between a card's header and body.
    private(set) var border: Color = Color.clear
    private(set) var borderNS: NSColor = NSColor.clear
    /// What a card drops onto the window. Clear in a dark theme, where
    /// the hairline carries the separation on its own.
    private(set) var cardShadow: Color = Color.clear

    // MARK: Text

    /// Body text.
    private(set) var text: Color = Color.clear
    /// The text colour for AppKit (and SyntaxPalette, which fades it for comments).
    private(set) var textNS: NSColor = NSColor.clear
    /// Secondary text: a label beside the thing it names.
    private(set) var text2: Color = Color.clear
    /// Tertiary text: metadata you read only when you look for it.
    private(set) var text3: Color = Color.clear

    // MARK: Fills

    /// The tile behind a small glyph (a tab's kind icon).
    private(set) var iconBg: Color = Color.clear
    /// A selected row in a list.
    private(set) var rowSel: Color = Color.clear
    /// A hovered row in a list.
    private(set) var rowHover: Color = Color.clear
    /// The selected tab, which sits proud of the strip.
    private(set) var tabSel: Color = Color.clear
    /// Its hairline and its drop shadow.
    private(set) var tabSelEdge: Color = Color.clear
    private(set) var tabSelShadow: Color = Color.clear
    /// A menu's body and its edge — translucent, over anything.
    private(set) var menu: Color = Color.clear
    private(set) var menuEdge: Color = Color.clear
    /// The chip stack on a collapsed group, and an idle segment in its
    /// progress strip.
    private(set) var stackBg: Color = Color.clear
    private(set) var segIdle: Color = Color.clear

    // MARK: Status

    /// Behind "N need you".
    private(set) var attnBg: Color = Color.clear
    /// Status text, legible on `win` in both themes — the status *fills*
    /// stay the same hue in both (`TabStatusStyle`), only text shifts.
    private(set) var orangeText: Color = Color.clear
    private(set) var greenText: Color = Color.clear
    private(set) var accentText: Color = Color.clear

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

    init(background: NSColor, foreground: NSColor) {
        apply(background: background, foreground: foreground)
    }

    /// The two colours everything here is derived from, kept so the same
    /// pair can be recognised and ignored.
    private var source: (background: NSColor, foreground: NSColor)?

    /// Recomputes every colour from a terminal theme's two. One signal for
    /// the lot: they only ever change together.
    ///
    /// The same pair changes nothing and says nothing — the config is
    /// reloaded for reasons that have nothing to do with colour (a
    /// keybinding, the font), and a view redrawn for no reason can take
    /// the keyboard away from the terminal.
    func apply(background: NSColor, foreground: NSColor) {
        if let source, source.background == background, source.foreground == foreground { return }
        source = (background, foreground)
        objectWillChange.send()
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
