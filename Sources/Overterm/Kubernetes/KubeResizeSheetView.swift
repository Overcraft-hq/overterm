import SwiftUI

/// Resize in Place…: each container's cpu and memory requests and limits,
/// as the pod says them now — the context and namespace said. Resize goes
/// on to the write's own confirmation (`KubernetesPageModel.write`);
/// nothing changes here.
struct KubeResizeSheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let draft = page.resizeDraft {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeResizeSheet() }
                card(draft)
            }
        }
    }

    private func card(_ draft: KubeResizeDraft) -> some View {
        let production = page.model.contexts.context(named: draft.ref.context)?.isProduction == true
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Resize \(KubeWriteOutcome.spoken(draft.ref)) in place").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: (production ? "PRODUCTION · " : "") + "\(draft.ref.context) · \(draft.ref.namespace.map { "namespace \($0)" } ?? "cluster-wide")")
                .font(.system(size: 11.5)).foregroundStyle(production ? KubernetesPageView.production : theme.text2)
            if draft.current == nil, draft.problem == nil {
                Text("Reading its containers…").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            if !draft.typed.isEmpty {
                HStack(spacing: 6) {
                    Text("").frame(width: 110, alignment: .leading)
                    ForEach(KubeResize.Field.allCases, id: \.self) { field in
                        Text(verbatim: field.spoken).font(.system(size: 10.5)).foregroundStyle(theme.text3).frame(width: 74, alignment: .leading)
                    }
                }
                ForEach(Array(draft.typed.enumerated()), id: \.offset) { index, container in
                    HStack(spacing: 6) {
                        Text(verbatim: container.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                            .lineLimit(1).truncationMode(.middle).frame(width: 110, alignment: .leading)
                        ForEach(KubeResize.Field.allCases, id: \.self) { field in
                            value(index, field, first: index == 0 && field == .cpuRequest)
                        }
                    }
                }
            }
            Text("Only cpu and memory change in place: never removed, nor so that the pod's QoS class changes. Asked again before it is sent.").font(.system(size: 11))
                .foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            if let problem = draft.problem {
                Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.resize.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { page.closeResizeSheet() }.keyboardShortcut(.cancelAction)
                Button("Resize…") { page.confirmResize() }.keyboardShortcut(.defaultAction).disabled(draft.current == nil)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(production ? KubernetesPageView.production : theme.menuEdge))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("kubernetes.resizeSheet")
    }

    /// One value's field. The first has the keyboard as the values come:
    /// the page's keys stand aside while the sheet shows (`press`).
    private func value(_ index: Int, _ field: KubeResize.Field, first: Bool) -> some View {
        PaletteField(
            text: Binding(
                get: { page.resizeDraft?.typed[safe: index]?[field] ?? "" },
                set: { text in
                    guard page.resizeDraft?.typed.indices.contains(index) == true else { return }
                    page.resizeDraft?.typed[index][field] = text
                    page.resizeDraft?.problem = nil
                }),
            onMove: { _ in },
            onSubmit: { _ in page.confirmResize() },
            onCancel: { page.closeResizeSheet() },
            placeholder: field.placeholder,
            textColor: NSColor(theme.text), focusesOnAppear: first, fontSize: 12
        )
        .padding(.horizontal, 5)
        .frame(width: 74, height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.strip))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border))
        .accessibilityIdentifier("kubernetes.resize.\(index).\(field.rawValue)")
    }
}
