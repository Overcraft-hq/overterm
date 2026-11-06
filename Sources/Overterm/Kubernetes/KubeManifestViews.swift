import SwiftUI

/// The bar under a Kubernetes manifest in the editor (stage 2b): what it
/// is and where it goes — a cluster object's copy names its context and
/// namespace, a checkout's file picks a context —, Diff with Cluster,
/// Apply… (greyed with why where it can't be done), after a conflict
/// Force… or Replace…, and how the last step stands.
struct KubeManifestBar: View {
    @ObservedObject var session: KubeManifestSession
    @ObservedObject var theme: ChromeTheme

    static let height: CGFloat = 56
    static let statusHeight: CGFloat = 74

    private var context: KubeContext? { session.contexts.first { $0.name == session.contextName } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "⎈").font(.system(size: 13)).foregroundStyle(theme.dimText)
                Text(verbatim: session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    .truncationMode(.middle)
                place
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Diff with Cluster") { session.diffWithCluster() }
                    .disabled(session.state.isWorking || session.contextName == nil)
                    .help("A server-side dry run (dryRun=All) compared with the live object, in the changes pane — a client-side diff where the cluster won't dry-run it")
                    .fixedSize()
                    .accessibilityIdentifier("kubernetes.manifest.diff")
                Button("Apply…") { session.apply() }
                    .disabled(session.state.isWorking || session.applyRefusal != nil)
                    .help(session.applyRefusal ?? "Server-side apply (fieldManager=overterm), after a fresh dry run shown in the confirmation")
                    .fixedSize()
                    .accessibilityIdentifier("kubernetes.manifest.apply")
                if case .fields = session.conflict, context?.isProduction != true {
                    Button("Force…") { session.forceApply() }
                        .disabled(session.state.isWorking)
                        .help("Apply again with force=true: the conflicting fields are taken from their managers — asked first")
                        .fixedSize()
                }
                if case .changed = session.conflict {
                    Button("Replace…") { session.replace() }
                        .disabled(session.state.isWorking)
                        .help("It changed in the cluster since you opened it: apply your copy over it — asked first")
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .controlSize(.small)
            if let text = session.state.text {
                Text(verbatim: text)
                    .font(.system(size: 11))
                    .foregroundStyle(session.state.isFailure ? KubernetesPageView.production : theme.dimText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .accessibilityIdentifier("kubernetes.manifest.status")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.strip)
        .task { await session.refreshContexts() }
    }

    /// The context (and namespace) it goes to: fixed for an object's copy,
    /// picked for a file — production said so.
    @ViewBuilder private var place: some View {
        if let ref = session.ref {
            Text(verbatim: (context?.isProduction == true ? "PRODUCTION · " : "") + ref.context + " · " + (ref.namespace.map { "namespace \($0)" } ?? "cluster-wide"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(context?.isProduction == true ? KubernetesPageView.production : theme.dimText)
                .lineLimit(1)
        } else {
            Menu {
                ForEach(session.contexts, id: \.name) { context in
                    Button((context.isProduction ? "PRODUCTION · " : "") + context.name + (context.isWritable ? "" : " (read-only)")) {
                        session.contextName = context.name
                    }
                }
            } label: {
                Text(verbatim: session.contextName.map { (context?.isProduction == true ? "PRODUCTION · " : "") + $0 } ?? "Pick a context")
                    .foregroundStyle(context?.isProduction == true ? KubernetesPageView.production : theme.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Not while a diff or an apply works: its answer is the context's it started with.
            .disabled(session.state.isWorking)
            .help("The context to compare with and apply to — an object without a namespace goes to the page's namespace there")
        }
    }
}

/// The right-hand pane's diff with the cluster: the session shown last.
@MainActor
final class KubeManifestPane: ObservableObject {
    enum Shown: Equatable {
        case manifest, helm, change
    }

    @Published var session: KubeManifestSession?
    /// A bound release's diff against the checkout's chart (stage 3a).
    @Published var helm: KubeHelmUpgradeSession?
    /// A change of a workload's timeline (stage 3b), and its parts' diffs, parsed.
    @Published private(set) var change: KubeChangeDiff?
    private(set) var changeFiles: [String: DiffModel.FileDiff] = [:]
    /// Which shows: the one asked for last.
    @Published var shown: Shown = .manifest

    var showsHelm: Bool {
        get { shown == .helm }
        set { shown = newValue ? .helm : .manifest }
    }

    /// A timeline's change, shown.
    func show(_ change: KubeChangeDiff) {
        changeFiles = Dictionary(
            change.diff.items.filter { !$0.diff.isEmpty }.map { ($0.id, DiffModel.FileDiff(parsing: $0.diff, path: $0.file)) }, uniquingKeysWith: { a, _ in a })
        self.change = change
        shown = .change
    }
}

struct KubeManifestDiffView: View {
    @ObservedObject var pane: KubeManifestPane
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    /// The manifest's file, back in the editor.
    let onOpen: (URL) -> Void

    var body: some View {
        if pane.shown == .change, let change = pane.change {
            KubeChangeDiffContent(pane: pane, change: change, theme: theme, onClose: onClose)
        } else if pane.showsHelm, let helm = pane.helm {
            KubeHelmDiffContent(session: helm, theme: theme, onClose: onClose, onOpen: onOpen)
        } else if let session = pane.session {
            KubeManifestDiffContent(session: session, theme: theme, onClose: onClose, onOpen: onOpen)
        } else {
            Text("Diff with Cluster, from a Kubernetes manifest in the editor, shows here.")
                .font(.system(size: 11)).foregroundStyle(theme.dimText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.strip)
        }
    }
}

/// One session's diff: how it was made (server-side, or client-side and
/// why), who else owns what it changes, the last apply's conflict, and
/// each object's diff, masked.
struct KubeManifestDiffContent: View {
    @ObservedObject var session: KubeManifestSession
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    let onOpen: (URL) -> Void
    @State private var folded: Set<String> = []

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }
    private static let warning = Color(red: 0.93, green: 0.6, blue: 0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if let result = session.result {
                content(result)
            } else {
                Text(verbatim: session.state.text ?? "Diff with Cluster from the manifest's bar in the editor.")
                    .font(.system(size: 11)).foregroundStyle(theme.dimText).padding(12)
                Spacer(minLength: 0)
            }
        }
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: "⎈").foregroundStyle(theme.dimText)
            Text(verbatim: session.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
            if let result = session.result {
                Text(verbatim: (result.production ? "PRODUCTION · " : "") + result.context)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(result.production ? KubernetesPageView.production : theme.dimText)
            }
            Spacer(minLength: 0)
            Button("Apply…") { session.apply() }
                .controlSize(.small)
                .disabled(session.state.isWorking || session.applyRefusal != nil)
                .help(session.applyRefusal ?? "Server-side apply, after a fresh dry run shown in the confirmation")
            Button {
                onOpen(session.file)
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("The manifest in the editor")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func content(_ result: KubeManifestDiffResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(verbatim: result.label)
                    .font(.system(size: 11, weight: result.isServerSide ? .regular : .semibold))
                    .foregroundStyle(result.isServerSide ? theme.dimText : Self.warning)
                    .accessibilityIdentifier("kubernetes.manifest.label")
                ForEach(result.warnings, id: \.self) { warning in
                    Text(verbatim: "⚠︎ " + warning).font(.system(size: 11)).foregroundStyle(Self.warning)
                }
                if let conflict = session.conflict {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: conflictTitle(conflict)).font(.system(size: 11, weight: .semibold)).foregroundStyle(KubernetesPageView.production)
                        Text(verbatim: conflict.said).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                        HStack {
                            if case .fields = conflict, !result.production {
                                Button("Force…") { session.forceApply() }.controlSize(.small)
                            }
                            if case .changed = conflict {
                                Button("Replace…") { session.replace() }.controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(KubernetesPageView.production.opacity(0.08)))
                }
                if let text = session.state.text {
                    Text(verbatim: text).font(.system(size: 11)).foregroundStyle(session.state.isFailure ? KubernetesPageView.production : theme.dimText)
                }
                ForEach(result.items) { item in
                    if item.unchanged {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").foregroundStyle(theme.dimText)
                            Text(verbatim: "\(item.spoken): unchanged").foregroundStyle(theme.dimText)
                        }
                        .font(.system(size: 11))
                    } else {
                        FileCard(
                            file: ChangedFile(
                                path: "\(item.ref.namespace.map { "\($0)/" } ?? "")\(item.ref.kind.singular.isEmpty ? item.ref.kind.kind.lowercased() : item.ref.kind.singular)-\(item.ref.name).yaml",
                                originalPath: nil, kind: item.isNew ? .added : .modified,
                                isStaged: false, hasUnstaged: false, added: item.added, removed: item.removed),
                            diff: session.fileDiffs[item.id], collapsed: folded.contains(item.id), theme: theme, palette: palette,
                            onToggle: {
                                if folded.contains(item.id) { folded.remove(item.id) } else { folded.insert(item.id) }
                            }, onOpen: { onOpen(session.file) })
                        if !item.masked.isEmpty {
                            Text(verbatim: "Still masked — retype before applying: " + item.masked.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(Self.warning)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func conflictTitle(_ conflict: KubeApplyConflict) -> String {
        switch conflict {
        case .fields: "Conflict: these fields are another manager's"
        case .changed: "Changed in the cluster since it was opened"
        }
    }
}
