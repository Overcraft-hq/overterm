import SwiftUI

/// `N`: a new namespace's name — the context said, the name checked as a
/// DNS label as it is typed. Create goes on to the write's own
/// confirmation (`KubernetesPageModel.write`); nothing is made here.
struct KubeNamespaceSheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    /// The name field's placeholder — how the scenario finds the field
    /// that has the keyboard.
    static let placeholder = "namespace name"

    var body: some View {
        if let draft = page.namespaceDraft {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeNamespaceSheet() }
                card(draft)
            }
        }
    }

    private func card(_ draft: KubeNamespaceDraft) -> some View {
        let production = page.model.contexts.context(named: draft.context)?.isProduction == true
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        // Said as it is typed; the problem Create found until it is changed.
        let problem = draft.problem ?? (typed.isEmpty ? nil : KubeNamespaceName.problem(typed))
        return VStack(alignment: .leading, spacing: 10) {
            Text("New Namespace").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: (production ? KubeWriteConfirmation.productionMark : "") + draft.context + " · cluster-wide")
                .font(.system(size: 11.5)).foregroundStyle(production ? KubernetesPageView.production : theme.text2)
            HStack(spacing: 8) {
                Text("Name").font(.system(size: 12)).foregroundStyle(theme.text2)
                // The keyboard is the field's as the sheet appears: the
                // page's keys stand aside while it shows (`press`).
                PaletteField(
                    text: Binding(
                        get: { page.namespaceDraft?.name ?? "" },
                        set: {
                            page.namespaceDraft?.name = $0
                            page.namespaceDraft?.problem = nil
                        }),
                    onMove: { _ in },
                    onSubmit: { _ in page.confirmNamespace() },
                    onCancel: { page.closeNamespaceSheet() },
                    placeholder: Self.placeholder,
                    textColor: NSColor(theme.text), focusesOnAppear: true, fontSize: 12.5
                )
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.strip))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
                .accessibilityIdentifier("kubernetes.namespace.name")
            }
            Text("Lowercase letters, digits and -, at most 63. Asked again before it is made.").font(.system(size: 11))
                .foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed)
                    .accessibilityIdentifier("kubernetes.namespace.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { page.closeNamespaceSheet() }.keyboardShortcut(.cancelAction)
                Button("Create…") { page.confirmNamespace() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(production ? KubernetesPageView.production : theme.menuEdge))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("kubernetes.namespaceSheet")
    }
}
