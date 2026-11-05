import SwiftUI

/// A workload's Logs tab (stage 2e): its pods' containers merged by time,
/// each line prefixed and coloured by its pod and container — what is
/// followed and the cap said above it, include and exclude expressions in
/// a popover, how far back; then the shared log pane, one stream picked
/// or all, its options kept for the window, Save As, ⌘L.
struct KubeMergedLogsView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var logs: KubeMergedLogSession
    @ObservedObject var theme: ChromeTheme
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(theme.border).frame(height: 1)
            LogsPane(
                feed: logs.feed, theme: theme, identifier: "kubernetes.logs", runInTerminal: { page.actions?.run($0) }, sources: logs.sources,
                source: $logs.picked, noun: "container", ask: { [weak page] in page?.askAboutLogLines($0) }, options: $page.logOptions,
                save: { [weak page] in page?.saveLogs($0) },
                stoppedHelp: "Not followed now: shown again, each container is read from its last line", focusFilter: page.focusLogFilter)
        }
        .accessibilityIdentifier("kubernetes.logs.merged")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(verbatim: logs.selector).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1)
                    .truncationMode(.middle).help("The pods \(logs.title) picks")
                Spacer(minLength: 4)
                Button {
                    editing = true
                } label: {
                    Text(verbatim: logs.filter.isEmpty ? "Include / Exclude" : "Include / Exclude (\(logs.filter.count))").font(.system(size: 11.5))
                }
                .controlSize(.small)
                .help(
                    "Regular expressions over the pods' names, the containers' and the lines, as stern's --pod-query, --exclude-pod, --container, --include and --exclude"
                )
                .accessibilityIdentifier("kubernetes.logs.filters")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    KubeMergedLogFilterForm(logs: logs, draft: logs.filter) { editing = false }
                }
                Picker("", selection: $page.logSince) {
                    ForEach(KubeLogSince.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("How far back each container's log goes")
                .accessibilityIdentifier("kubernetes.logs.since")
            }
            // Its own line: the cap is said whole, never cut off; what
            // couldn't be read is said after it, never in its place.
            Text(verbatim: note).font(.system(size: 11))
                .foregroundStyle(logs.problems.isEmpty ? (logs.capped > 0 ? TabStatusStyle.waiting : theme.text3) : TabStatusStyle.failed)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(note)
                .accessibilityIdentifier("kubernetes.logs.streams")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var note: String {
        let waiting = logs.streams.filter { if case .waiting = $0.reading { true } else { false } }.count
        return ([logs.summary + (waiting > 0 ? " · \(waiting) waiting to start" : "")] + logs.problems).joined(separator: " · ")
    }
}

/// The include and exclude expressions, edited and applied at once: every
/// stream read again from its start.
private struct KubeMergedLogFilterForm: View {
    let logs: KubeMergedLogSession
    @State var draft: KubeMergedLogFilter
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regular expressions, case aside; empty picks everything").font(.system(size: 11)).foregroundStyle(.secondary)
            field("Pods", "web-.*", $draft.pods)
            field("Pods left out", "canary", $draft.excludePods)
            field("Containers", "app|worker", $draft.containers)
            field("Lines", "error|timeout", $draft.lines)
            field("Lines left out", "healthz", $draft.excludeLines)
            if let problem = draft.problem { Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed) }
            HStack {
                Button("Clear") { draft = KubeMergedLogFilter() }.disabled(draft.isEmpty)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if logs.setFilter(draft) { done() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func field(_ title: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 11.5)).frame(width: 92, alignment: .trailing)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
        }
    }
}
