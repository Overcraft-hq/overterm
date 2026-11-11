import AppKit
import SwiftUI

/// The right-hand pane's `kubectl explain` (3.15): a kind and a field path
/// typed (`deployment.spec.replicas`), the context it is asked of, and what
/// that cluster's own docs say — the field's type, whether it is required,
/// its description, and its fields, each opened with a press.
struct KubeExplainView: View {
    @ObservedObject var session: KubeExplainSession
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            field
            Divider().opacity(0.3)
            content
        }
        .background(theme.strip)
        .task { await session.refreshContexts() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: "⎈").foregroundStyle(theme.dimText)
            Text("Explain").font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text)
            Menu {
                ForEach(session.contexts, id: \.name) { context in
                    Button((context.isProduction ? "PRODUCTION · " : "") + context.name) {
                        session.contextName = context.name
                        session.explain()
                    }
                }
            } label: {
                Text(verbatim: session.contextName.map { (session.context?.isProduction == true ? "PRODUCTION · " : "") + $0 } ?? "Pick a context")
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                    .foregroundStyle(session.context?.isProduction == true ? KubernetesPageView.production : theme.dimText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The context whose API docs are read")
            Spacer(minLength: 0)
            if let line = session.kubectl {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: ChromeMetrics.text(11)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Copy as kubectl: \(line)")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Button {
                session.up()
            } label: {
                Image(systemName: "chevron.up").font(.system(size: ChromeMetrics.text(11)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .disabled(!session.query.contains("."))
            .help("Up a field")
            TextField("deployment.spec.replicas", text: $session.query)
                .textFieldStyle(.plain)
                .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                .foregroundStyle(theme.text)
                .onSubmit { session.explain() }
                .accessibilityIdentifier("kubernetes.explain.query")
            Button("Explain") { session.explain() }
                .controlSize(.small)
                .disabled(session.contextName == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch session.state {
                case .working(let text), .failed(let text):
                    Text(verbatim: text).font(.system(size: ChromeMetrics.text(11)))
                        .foregroundStyle(session.state == .failed(text) ? KubernetesPageView.production : theme.dimText)
                        .accessibilityIdentifier("kubernetes.explain.status")
                case .idle: EmptyView()
                }
                if let doc = session.result { explained(doc) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func explained(_ doc: KubeFieldDoc) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(doc.gvk.kind) · \(doc.gvk.apiVersion)" + (session.source.map { " · \($0.said)" } ?? ""))
                .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            HStack(spacing: 6) {
                Text(verbatim: doc.spokenPath).font(.system(size: ChromeMetrics.text(13), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                Text(verbatim: "<\(doc.type)>").font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(theme.dimText)
                if doc.required {
                    Text("required").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(KubernetesPageView.production)
                }
            }
            .textSelection(.enabled)
            Text(verbatim: doc.description.isEmpty ? "No description." : doc.description)
                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !doc.enumValues.isEmpty {
                Text(verbatim: "One of: " + doc.enumValues.joined(separator: ", ")).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.dimText)
            }
            if doc.opaque {
                Text("Its fields aren't described: any are taken.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            }
            if !doc.fields.isEmpty {
                Text("FIELDS").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.dimText).padding(.top, 4)
                ForEach(doc.fields) { field in
                    Button {
                        session.open(field.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: field.name).font(.system(size: ChromeMetrics.text(12), weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
                                Text(verbatim: "<\(field.type)>").font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.dimText)
                                if field.required {
                                    Text("required").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(KubernetesPageView.production)
                                }
                            }
                            if !field.summary.isEmpty {
                                Text(verbatim: field.summary).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Explain \(doc.spokenPath).\(field.name)")
                }
            }
        }
    }
}
