import SwiftUI

/// `=`: how many replicas — the context and namespace said, the current
/// count read from the scale subresource. Scale goes on to the write's own
/// confirmation (`KubernetesPageModel.write`); nothing changes here.
struct KubeScaleSheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    /// The replicas field's placeholder — how the scenario finds the field
    /// that has the keyboard.
    static let placeholder = "count"

    var body: some View {
        if let draft = page.scaleDraft {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeScaleSheet() }
                card(draft)
            }
        }
    }

    private func card(_ draft: KubeScaleDraft) -> some View {
        let production = page.model.contexts.context(named: draft.ref.context)?.isProduction == true
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Scale \(KubeWriteOutcome.spoken(draft.ref))").font(.system(size: ChromeMetrics.text(14), weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: (production ? "PRODUCTION · " : "") + "\(draft.ref.context) · \(draft.ref.namespace.map { "namespace \($0)" } ?? "cluster-wide")")
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(production ? KubernetesPageView.production : theme.text2)
            HStack(spacing: 8) {
                Text("Replicas").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                // The keyboard is the field's as the sheet appears: the
                // page's keys stand aside while it shows (`press`), so a
                // field left without it would take nothing typed.
                PaletteField(
                    text: Binding(get: { page.scaleDraft?.replicas ?? "" }, set: { page.scaleDraft?.replicas = $0 }),
                    onMove: { _ in },
                    onSubmit: { _ in page.confirmScale() },
                    onCancel: { page.closeScaleSheet() },
                    placeholder: Self.placeholder,
                    textColor: NSColor(theme.text), focusesOnAppear: true, fontSize: 12.5
                )
                .padding(.horizontal, 6)
                .frame(width: 90, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.strip))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
                .accessibilityIdentifier("kubernetes.scale.replicas")
                Text(verbatim: draft.current.map { "now \($0)" } ?? "reading…").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
            }
            Text("Asked again before it is sent; scaling to 0 on production asks for the name.").font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            if let problem = draft.problem {
                Text(verbatim: problem).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed)
                    .accessibilityIdentifier("kubernetes.scale.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { page.closeScaleSheet() }.keyboardShortcut(.cancelAction)
                Button("Scale…") { page.confirmScale() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(production ? KubernetesPageView.production : theme.menuEdge))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("kubernetes.scaleSheet")
    }
}
