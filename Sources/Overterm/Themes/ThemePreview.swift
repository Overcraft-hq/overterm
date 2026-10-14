import AppKit
import SwiftUI

extension ThemeColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }
}

extension TerminalTheme {
    /// The chrome this theme would dress the window in — the same
    /// derivation the real window uses, so the preview is the thing.
    @MainActor var chrome: ChromeTheme {
        ChromeTheme(background: background.nsColor, foreground: foreground.nsColor)
    }
}

/// A theme as a little window: the strip with its tabs, a terminal card
/// with a line of output in the theme's own colours, and the sixteen ANSI
/// colours under it.
///
/// Drawn from the theme file, not from a screenshot, so all 473 of them
/// cost nothing to carry and a theme dropped into
/// `~/.config/ghostty/themes` looks like the rest at once.
struct ThemePreview: View {
    let theme: TerminalTheme
    /// Scales the whole drawing; 1 is the gallery's card.
    var scale: CGFloat = 1

    var body: some View {
        let chrome = theme.chrome
        VStack(spacing: 0) {
            strip(chrome)
            terminal
            palette
        }
        .background(chrome.win)
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .strokeBorder(chrome.winEdge, lineWidth: 1)
        )
    }

    /// Three tabs, the first one selected — the chrome's own colours, which
    /// is what the window's title bar will look like.
    private func strip(_ chrome: ChromeTheme) -> some View {
        HStack(spacing: 3 * scale) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                    .fill(index == 0 ? chrome.tabSel : chrome.iconBg)
                    .frame(height: 10 * scale)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(index == 2 ? theme.ansi(3).color : theme.ansi(index == 0 ? 2 : 4).color)
                            .frame(width: 4 * scale, height: 4 * scale)
                            .padding(.leading, 3 * scale)
                    }
            }
        }
        .padding(.horizontal, 6 * scale)
        .padding(.vertical, 5 * scale)
    }

    /// A prompt and a command, in the colours a shell actually prints in.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            line([(theme.ansi(4), 22), (theme.ansi(2), 14), (theme.foreground, 8)])
            line([(theme.ansi(5), 5), (theme.foreground, 30)])
            line([(theme.ansi(2), 9), (theme.foreground, 18), (theme.ansi(3), 11)])
            HStack(spacing: 3 * scale) {
                bar(theme.ansi(1), width: 13)
                bar(theme.ansi(6), width: 20)
                Rectangle()
                    .fill((theme.cursor ?? theme.foreground).color)
                    .frame(width: 4 * scale, height: 7 * scale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7 * scale)
        .background(theme.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 5 * scale, style: .continuous))
        .padding(.horizontal, 6 * scale)
    }

    /// Words, as bars: a preview that said `$ make test` in 7 pt type would
    /// be a smudge, and this reads as a terminal at any size.
    private func line(_ words: [(ThemeColor, CGFloat)]) -> some View {
        HStack(spacing: 3 * scale) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                bar(word.0, width: word.1)
            }
        }
    }

    private func bar(_ colour: ThemeColor, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5 * scale, style: .continuous)
            .fill(colour.color.opacity(0.9))
            .frame(width: width * scale, height: 3.5 * scale)
    }

    /// The eight bright ANSI colours: what tells two themes of the same
    /// background apart.
    private var palette: some View {
        HStack(spacing: 2 * scale) {
            ForEach(9..<15, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5 * scale, style: .continuous)
                    .fill(theme.ansi(index).color)
                    .frame(height: 5 * scale)
            }
        }
        .padding(.horizontal, 6 * scale)
        .padding(.top, 6 * scale)
        .padding(.bottom, 7 * scale)
    }
}
