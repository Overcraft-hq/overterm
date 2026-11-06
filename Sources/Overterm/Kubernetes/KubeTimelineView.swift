import SwiftUI

/// A workload's History tab: its changes newest first — template
/// revisions (images, the template, restarts, rollbacks), its Helm
/// release's revisions, scaling and warnings — each with Diff, which opens
/// it in the changes pane; and two revisions picked to compare.
struct KubeTimelineView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var timeline: KubeTimelineSession
    @ObservedObject var theme: ChromeTheme
    @State private var compareFrom: Int?
    @State private var compareTo: Int?
    @State private var comparesHelm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                if timeline.diffing != nil { ProgressView().controlSize(.mini) }
                Button("Refresh") { page.detail?.showHistory(again: true) }.font(.system(size: 11.5)).disabled(timeline.state == .loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch timeline.state {
                    case .idle, .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    case .failed(let reason): Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(TabStatusStyle.failed)
                    case .loaded:
                        if let problem = timeline.diffProblem {
                            Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
                        }
                        ForEach(timeline.notes, id: \.self) { note in
                            Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.waiting).fixedSize(horizontal: false, vertical: true)
                        }
                        compare
                        if timeline.entries.isEmpty {
                            Text("No changes kept: no revisions, Helm records or recent events.").font(.system(size: 12)).foregroundStyle(theme.text3)
                        }
                        ForEach(timeline.entries) { entry in row(entry) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { page.detail?.showHistory() }
        .accessibilityIdentifier("kubernetes.timeline")
    }

    private var note: String {
        guard timeline.state == .loaded else { return "Its changes, newest first" }
        let count = timeline.entries.count
        return "\(count) change\(count == 1 ? "" : "s"), newest first"
            + (timeline.release.map { " · Helm release \($0)" } ?? "") + " · \(timeline.templates.count) revision\(timeline.templates.count == 1 ? "" : "s") kept"
    }

    // MARK: Compare two revisions

    /// Helm's revisions are compared when picked, or when the templates kept are too few.
    private var usesHelm: Bool { comparesHelm || timeline.templateRevisions.count < 2 }
    private var revisions: [Int] { usesHelm ? timeline.helmRevisions : timeline.templateRevisions }

    @ViewBuilder private var compare: some View {
        if timeline.templateRevisions.count > 1 || timeline.helmRevisions.count > 1 {
            HStack(spacing: 8) {
                Text("Compare").font(.system(size: 11.5)).foregroundStyle(theme.text3)
                if timeline.templateRevisions.count > 1 && timeline.helmRevisions.count > 1 {
                    Picker("", selection: $comparesHelm) {
                        Text("Template").tag(false)
                        Text("Helm").tag(true)
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .onChange(of: comparesHelm) { _ in
                        compareFrom = nil
                        compareTo = nil
                    }
                }
                picker(selection: Binding(get: { compareFrom ?? defaultFrom }, set: { compareFrom = $0 }))
                Text(verbatim: "→").font(.system(size: 11.5)).foregroundStyle(theme.text3)
                picker(selection: Binding(get: { compareTo ?? revisions.last ?? 0 }, set: { compareTo = $0 }))
                Button("Diff") {
                    let from = compareFrom ?? defaultFrom
                    let to = compareTo ?? revisions.last ?? 0
                    page.openChange(usesHelm ? .helm(from: from, to: to) : .template(from: from, to: to))
                }
                .font(.system(size: 11.5))
                .disabled(timeline.diffing != nil || (compareFrom ?? defaultFrom) == (compareTo ?? revisions.last ?? 0))
                .help("The two revisions against each other in the changes pane, masked")
                .accessibilityIdentifier("kubernetes.timeline.compare")
                Spacer(minLength: 0)
            }
        }
    }

    private var defaultFrom: Int { revisions.count > 1 ? revisions[revisions.count - 2] : revisions.first ?? 0 }

    private func picker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(revisions, id: \.self) { Text(verbatim: "revision \($0)").tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: An entry

    private func row(_ entry: KubeTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(entry.kind)).font(.system(size: 11)).foregroundStyle(color(entry.kind)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(entry.kind == .warning ? TabStatusStyle.waiting : theme.text)
                    if entry.count > 1 { Text(verbatim: "×\(entry.count)").font(.system(size: 11)).foregroundStyle(theme.text3) }
                    Spacer(minLength: 0)
                    if let time = entry.time {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: (entry.approximate ? "after " : "") + KubeAge.format(context.date.timeIntervalSince(time)) + " ago")
                                .font(.system(size: 11)).foregroundStyle(theme.text3)
                                .help(time.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    if let change = entry.change {
                        Button("Diff") { page.openChange(change) }
                            .font(.system(size: 11)).controlSize(.small)
                            .disabled(timeline.diffing != nil)
                            .help("What changed, in the changes pane — masked")
                            .accessibilityIdentifier("kubernetes.timeline.diff.\(entry.id)")
                    }
                }
                if let detail = entry.detail {
                    Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(theme.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("kubernetes.timeline.entry")
    }

    private func symbol(_ kind: KubeTimelineEntry.Kind) -> String {
        switch kind {
        case .revision: "square.stack.3d.up"
        case .restart: "arrow.clockwise"
        case .rollback: "arrow.uturn.backward"
        case .helm: "helm"
        case .scale: "arrow.up.and.down"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: KubeTimelineEntry.Kind) -> Color {
        switch kind {
        case .warning: TabStatusStyle.waiting
        case .rollback: TabStatusStyle.failed
        default: theme.text3
        }
    }
}

/// The changes pane's diff of one change of a workload's timeline: what is
/// compared, each part's diff — masked.
struct KubeChangeDiffContent: View {
    @ObservedObject var pane: KubeManifestPane
    let change: KubeChangeDiff
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    @State private var folded: Set<String> = []

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: "⎈").foregroundStyle(theme.dimText)
                Text(verbatim: change.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(verbatim: (change.production ? "PRODUCTION · " : "") + change.context)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(change.production ? KubernetesPageView.production : theme.dimText)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Close")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: change.label).font(.system(size: 11)).foregroundStyle(theme.dimText).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kubernetes.change.label")
                    if change.diff.withheld > 0 {
                        Text(verbatim: "\(change.diff.withheld) document\(change.diff.withheld == 1 ? "" : "s") left out: unreadable, so it couldn't be masked.")
                            .font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
                    }
                    ForEach(change.diff.items) { item in
                        if item.change == .unchanged {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle").foregroundStyle(theme.dimText)
                                Text(verbatim: "\(item.spoken): unchanged").foregroundStyle(theme.dimText)
                            }
                            .font(.system(size: 11))
                        } else {
                            FileCard(
                                file: ChangedFile(
                                    path: "\(item.namespace.map { "\($0)/" } ?? "")\(item.file)", originalPath: nil,
                                    kind: item.change == .added ? .added : item.change == .removed ? .deleted : .modified, isStaged: false, hasUnstaged: false,
                                    added: item.added, removed: item.removed),
                                diff: pane.changeFiles[item.id], collapsed: folded.contains(item.id), theme: theme, palette: palette,
                                onToggle: {
                                    if folded.contains(item.id) { folded.remove(item.id) } else { folded.insert(item.id) }
                                }, onOpen: {})
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(theme.strip)
        .accessibilityIdentifier("kubernetes.change")
    }
}
