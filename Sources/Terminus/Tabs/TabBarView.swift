import AppKit
import SwiftUI

/// Chrome-style tab strip, living in the window's title bar.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    let theme: TabBarTheme
    /// Room for the traffic lights on the left.
    let leadingInset: CGFloat
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            ForEach(store.tabs) { tab in
                TabItemView(
                    tab: tab,
                    isSelected: tab.id == store.selectedID,
                    theme: theme,
                    onSelect: { onSelect(tab) },
                    onClose: { onClose(tab) }
                )
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("New Tab (⌘T)")
            .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(WindowDragArea())
    }
}

/// Colours derived from the terminal theme so the strip reads as part of it:
/// the selected tab *is* the terminal's background, the strip sits a step
/// away from it.
struct TabBarTheme {
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

private struct TabItemView: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let theme: TabBarTheme
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? theme.text : theme.dimText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .opacity(isSelected || hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 60, idealWidth: 200, maxWidth: 220, minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.title)
        .padding(.horizontal, 2)
    }
}

/// Empty strip space drags the window, as a title bar should.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
