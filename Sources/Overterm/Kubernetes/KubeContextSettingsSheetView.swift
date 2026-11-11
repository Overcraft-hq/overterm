import SwiftUI

/// A context's settings over the Kubernetes page (`KubeContextSettingsDraft`):
/// its class, read-only or writable, usage's source and the Prometheus
/// Service, the node shell and its image, the default namespace, whether
/// agents may change it, Apply on production. Production's switch for the
/// session is said, never set here. Esc or Cancel closes it; Save writes
/// settings.json, or says why not.
struct KubeContextSettingsSheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    static let identifier = "kubernetes.contextSettings"

    var body: some View {
        if let draft = page.contextSettingsDraft {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeContextSettings() }
                card(draft)
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<KubeContextSettingsDraft, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(
            get: { page.contextSettingsDraft?[keyPath: path] ?? fallback },
            set: {
                page.contextSettingsDraft?[keyPath: path] = $0
                page.contextSettingsDraft?.problem = nil
            })
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).frame(width: 150, alignment: .trailing)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 160)
    }

    private func field(_ placeholder: String, _ path: WritableKeyPath<KubeContextSettingsDraft, String>, id: String) -> some View {
        TextField(placeholder, text: binding(path, ""))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
            .accessibilityIdentifier("kubernetes.contextSettings.\(id)")
    }

    private func card(_ draft: KubeContextSettingsDraft) -> some View {
        let production = draft.isProduction
        return VStack(alignment: .leading, spacing: 10) {
            Text("Context Settings").font(.system(size: ChromeMetrics.text(14), weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: (production ? KubeWriteConfirmation.productionMark : "") + draft.context)
                .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(production ? KubernetesPageView.production : theme.text2)
                .textSelection(.enabled)
            row("Class") {
                Picker("", selection: binding(\.contextClass, nil)) {
                    Text(verbatim: "By its name (\(draft.classByName.title.lowercased()))").tag(KubeContextClass?.none)
                    ForEach(KubeContextClass.allCases, id: \.self) { Text($0.title).tag(KubeContextClass?.some($0)) }
                }
                .labelsHidden().frame(width: 260)
                .accessibilityIdentifier("kubernetes.contextSettings.class")
            }
            if production {
                note(draft.writableSaid)
            } else {
                row("Writes") {
                    Picker("", selection: binding(\.writable, nil)) {
                        Text(verbatim: "Its class's default (\(draft.resolvedClass == .local ? "writable" : "read-only"))").tag(Bool?.none)
                        Text("Writable").tag(Bool?.some(true))
                        Text("Read-only").tag(Bool?.some(false))
                    }
                    .labelsHidden().frame(width: 260)
                    .accessibilityIdentifier("kubernetes.contextSettings.writable")
                }
                note(draft.writableSaid)
            }
            row("Usage from") {
                Picker("", selection: binding(\.metrics, nil)) {
                    Text("metrics-server when served").tag(KubeMetricsSource?.none)
                    ForEach(KubeMetricsSource.allCases, id: \.self) { Text($0.title).tag(KubeMetricsSource?.some($0)) }
                }
                .labelsHidden().frame(width: 320)
                .accessibilityIdentifier("kubernetes.contextSettings.metrics")
            }
            row("Prometheus Service") { field("found as Lens finds it — or monitoring/prometheus-server:80", \.prometheus, id: "prometheus") }
            row("Node shell") {
                Toggle("Offered on nodes when writable, the node's name typed", isOn: binding(\.nodeShell, false))
                    .toggleStyle(.checkbox).font(.system(size: ChromeMetrics.text(12)))
                    .accessibilityIdentifier("kubernetes.contextSettings.nodeShell")
            }
            row("Node shell's image") { field("its debug image — or acme/node-tools:1", \.nodeShellImage, id: "nodeShellImage") }
            row("Default namespace") { field("the kubeconfig's", \.defaultNamespace, id: "defaultNamespace") }
            row("Agents") {
                Toggle("May change it (kubernetes.agentWrites) — each call asked", isOn: binding(\.agentWrites, false))
                    .toggleStyle(.checkbox).font(.system(size: ChromeMetrics.text(12)))
                    .accessibilityIdentifier("kubernetes.contextSettings.agentWrites")
            }
            if production {
                row("Apply") {
                    Toggle("From the editor while writes are on, the name typed", isOn: binding(\.applyOnProduction, false))
                        .toggleStyle(.checkbox).font(.system(size: ChromeMetrics.text(12)))
                        .accessibilityIdentifier("kubernetes.contextSettings.applyOnProduction")
                }
            }
            let lessStrict = draft.confirmingLessStrict && draft.lessStrict(entry: nil)
            if lessStrict {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: draft.lessStrictSaid).font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).foregroundStyle(KubernetesPageView.production)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kubernetes.contextSettings.lessStrict")
                    TextField(draft.context, text: binding(\.typedName, ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                        .accessibilityIdentifier("kubernetes.contextSettings.typedName")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(KubernetesPageView.production))
            }
            if let problem = draft.problem ?? draft.validation {
                Text(verbatim: problem).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.contextSettings.problem")
            }
            HStack {
                Button("More in Settings…") { page.openKubernetesSettings() }.buttonStyle(.link).font(.system(size: ChromeMetrics.text(11.5)))
                Spacer()
                Button("Cancel") { page.closeContextSettings() }.keyboardShortcut(.cancelAction)
                Button(lessStrict ? "Make It \(draft.resolvedClass.title)" : "Save") { page.saveContextSettings() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.validation != nil)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(production ? KubernetesPageView.production : theme.menuEdge))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier(Self.identifier)
    }
}
