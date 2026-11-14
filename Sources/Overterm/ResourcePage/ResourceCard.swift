import SwiftUI

/// The card a resource page's summary is drawn on (Kubernetes' Overview):
/// the theme's card fill, a hairline border — tinted where the card is
/// about something failing — and a 10 pt radius, in dark and light alike.
struct ResourceCardStyle: ViewModifier {
    @ObservedObject var theme: ChromeTheme
    var tint: Color?
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ResourceCard.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(theme.card))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.75) } ?? theme.border, lineWidth: tint == nil ? 1 : 1.25))
            .shadow(color: theme.cardShadow.opacity(0.5), radius: 2, y: 1)
    }
}

enum ResourceCard {
    static let radius: CGFloat = 10
    /// Between cards, across and down.
    static let spacing: CGFloat = 14
}

extension View {
    /// Drawn as a resource page's card (`ResourceCardStyle`).
    func resourceCard(_ theme: ChromeTheme, tint: Color? = nil, padding: CGFloat = 14) -> some View {
        modifier(ResourceCardStyle(theme: theme, tint: tint, padding: padding))
    }
}

/// A card's caption: small, upper case, the theme's quietest text.
struct ResourceCardCaption: View {
    let text: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).tracking(0.4).foregroundStyle(theme.text3)
    }
}

/// A small rounded capsule with a tinted fill: a status said in words.
struct ResourcePill: View {
    let text: String
    /// The words' colour; the fill is its tint.
    let colour: Color
    var symbol: String?
    var monospaced = false

    var body: some View {
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
struct ResourceCardRow<Content: View>: View {
    @ObservedObject var theme: ChromeTheme
    var help: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
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
