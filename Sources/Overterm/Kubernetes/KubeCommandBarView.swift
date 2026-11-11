import SwiftUI

/// `:` over the Kubernetes page: k9s's command bar (`KubeCommandBar`). What
/// is typed, and what the word being typed completes to — a kind, then a
/// namespace, or a context after `@`. ↑↓ move, Tab completes, ↩ runs, Esc
/// or a click outside goes back to the list. The field is the palette's
/// (`PaletteField`).
struct KubeCommandBarView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let bar = page.command {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeCommand() }
                card(bar)
            }
        }
    }

    private func card(_ bar: KubeCommandBar) -> some View {
        let results = bar.results
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: ":").font(.system(size: ChromeMetrics.text(15), weight: .semibold, design: .monospaced)).foregroundStyle(theme.accentText)
                PaletteField(
                    text: Binding(get: { page.command?.text ?? "" }, set: { page.command?.text = $0 }),
                    onMove: { page.command?.move($0) },
                    onSubmit: { _ in page.runCommand() },
                    onCancel: { page.closeCommand() },
                    onTab: { if $0 > 0 { page.command?.complete() } },
                    placeholder: "deploy · po shop · svc @fake-dev · widgets /blue · ctx · ns",
                    textColor: NSColor(theme.text), focusesOnAppear: true, fontSize: 14
                )
                .accessibilityIdentifier("kubernetes.command.field")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            if let problem = bar.problem {
                Divider().opacity(0.4)
                Text(verbatim: problem).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed).padding(.horizontal, 14).padding(.vertical, 6)
                    .accessibilityIdentifier("kubernetes.command.problem")
            }
            if !results.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, completion in
                        row(completion, highlighted: offset == bar.index)
                            .onTapGesture {
                                page.command?.index = offset
                                page.command?.complete()
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .accessibilityIdentifier("kubernetes.command")
    }

    private func row(_ completion: KubeCommandBar.Completion, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: completion.text).font(.system(size: ChromeMetrics.text(12.5), design: .monospaced)).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: completion.detail).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? theme.selected : .clear))
        .contentShape(Rectangle())
    }
}
