import SwiftUI

/// The strip's gauge: how much of the tightest quota is gone, at the right
/// end of the title bar. A click opens the usage pane, where the changes
/// open.
///
/// It is there as soon as an agent has written a limit down, even when
/// every window it knows about has rolled over: then it shows the gauge
/// and a dash, which is the truth — the figures are from before the
/// window started again. Nothing at all only when there is no agent on
/// this Mac, or when Settings ▸ General puts it away.
struct UsageChip: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var theme: ChromeTheme
    /// Settings ▸ General can put the gauge away.
    @ObservedObject var settings: Settings = .shared
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if settings.usageChip, model.isAvailable {
            let shown = model.chipMeter()
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(shown.map { colour($0.meter) } ?? theme.dimText)
                    Text(verbatim: shown?.meter.reading() ?? "—")
                        .foregroundStyle(shown == nil ? theme.dimText : theme.text)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(
                shown.map { "\($0.snapshot.provider.name) · \($0.meter.name) \($0.meter.reading()), \($0.meter.resets()) — Usage (⌥⌘U)" }
                    ?? "Usage (⌥⌘U) — every window the agents reported has started again since")
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
