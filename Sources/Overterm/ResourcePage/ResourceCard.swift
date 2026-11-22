import SwiftUI

/// The card a resource page's summary is drawn on (Kubernetes' Overview):
/// the theme's card fill, a hairline border — tinted where the card is
/// about something failing — and a 10 pt radius, in dark and light alike.
package struct ResourceCardStyle: ViewModifier {
    @ObservedObject package var theme: ChromeTheme
    package var tint: Color?
    package var padding: CGFloat

    package func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ResourceCard.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(theme.card))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.75) } ?? theme.border, lineWidth: tint == nil ? 1 : 1.25))
            .shadow(color: theme.cardShadow.opacity(0.5), radius: 2, y: 1)
    }
}

package enum ResourceCard {
    package static let radius: CGFloat = 10
    /// Between cards, across and down.
    package static let spacing: CGFloat = 14
}

extension View {
    /// Drawn as a resource page's card (`ResourceCardStyle`).
    package func resourceCard(_ theme: ChromeTheme, tint: Color? = nil, padding: CGFloat = 14) -> some View {
        modifier(ResourceCardStyle(theme: theme, tint: tint, padding: padding))
    }
}

/// A card's caption: small, upper case, the theme's quietest text.
package struct ResourceCardCaption: View {
    package let text: String
    @ObservedObject package var theme: ChromeTheme

    package init(text: String, theme: ChromeTheme) {
        self.text = text
        self._theme = ObservedObject(wrappedValue: theme)
    }

    package var body: some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).tracking(0.4).foregroundStyle(theme.text3)
    }
}

/// A small rounded capsule with a tinted fill: a status said in words.
package struct ResourcePill: View {
    package let text: String
    /// The words' colour; the fill is its tint.
    package let colour: Color
    package var symbol: String?
    package var monospaced = false

    package init(text: String, colour: Color, symbol: String? = nil, monospaced: Bool = false) {
        self.text = text
        self.colour = colour
        self.symbol = symbol
        self.monospaced = monospaced
    }

    package var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: ChromeMetrics.text(9), weight: .bold)) }
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(11), weight: .medium, design: monospaced ? .monospaced : .default)).lineLimit(1)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(colour.opacity(0.14)))
        .fixedSize()
    }
}

/// A row in a card that is a button: the whole row takes the press, and
/// it lights up under the pointer.
package struct ResourceCardRow<Content: View>: View {
    @ObservedObject package var theme: ChromeTheme
    package var help: String
    package let action: () -> Void
    @ViewBuilder package var content: () -> Content
    @State private var hovered = false

    package init(theme: ChromeTheme, help: String, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self._theme = ObservedObject(wrappedValue: theme)
        self.help = help
        self.action = action
        self.content = content
    }

    package var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? theme.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
