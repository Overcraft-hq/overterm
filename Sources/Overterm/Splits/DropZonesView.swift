import AppKit
import SwiftUI

/// What a tab dragged over the panes would do, drawn over them.
///
/// Dropping a tab onto a pane is the only way to make a split out of
/// something that is already running — ⌘D makes an empty one. The zones
/// are shown rather than guessed at because five targets in one rectangle
/// is one too many to feel out.
struct DropZonesView: View {
    /// The pane being dropped onto, in this view's coordinates.
    let pane: CGRect
    let active: DropZone?
    /// What is being dragged, shown following the pointer.
    let title: String
    let symbol: String
    let pointer: CGPoint
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(DropZone.allCases, id: \.self) { zone in
                let frame = zone.frame(in: pane).insetBy(dx: 4, dy: 4)
                let on = zone == active
                RoundedRectangle(cornerRadius: 8)
                    .fill(on ? TabStatusStyle.working.opacity(0.22) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                on ? TabStatusStyle.working : theme.text.opacity(0.18),
                                style: StrokeStyle(lineWidth: on ? 2 : 1.5, dash: on ? [] : [5, 4]))
                    )
                    .overlay(
                        Text(zone.name)
                            .font(.system(size: on ? 13 : 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : theme.text2)
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            // The tab, under the pointer.
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.text2)
                Text(title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.menu)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.menuEdge, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            )
            .fixedSize()
            .offset(x: pointer.x + 12, y: pointer.y + 12)

            VStack {
                Spacer()
                HStack(spacing: 16) {
                    hint("⌥", "keep the original tab")
                    hint("esc", "cancel")
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.menu)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.menuEdge, lineWidth: 0.5))
                )
                .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key).font(.system(size: 11)).foregroundStyle(theme.text)
            Text(what).font(.system(size: 11)).foregroundStyle(theme.text3)
        }
    }
}
