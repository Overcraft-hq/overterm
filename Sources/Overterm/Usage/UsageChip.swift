import SwiftUI

/// The strip's gauge: how much of the tightest quota is gone, at the right
/// end of the title bar. A click opens the usage pane, where the changes
/// open.
///
/// It shows nothing at all until a provider has written down a limit —
/// the strip is where the tabs live and an empty chip would just take
/// their width.
struct UsageChip: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var theme: ChromeTheme
    /// Settings ▸ General can put the gauge away.
    @ObservedObject var settings: Settings = .shared
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if settings.usageChip, let (snapshot, meter) = model.tightest() {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colour(meter))
                    Text(verbatim: meter.reading())
                        .foregroundStyle(theme.text)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(snapshot.provider.name) · \(meter.name) \(meter.reading()), \(meter.resets()) — Usage (⌥⌘U)")
        }
    }

    private func colour(_ meter: UsageMeter) -> Color {
        switch meter.level() {
        case .easy: theme.dimText
        case .close: theme.orangeText
        case .spent: TabStatusStyle.failed
        }
    }
}
