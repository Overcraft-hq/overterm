import SwiftUI

/// The right-hand pane's Runner: a collection or folder run, request by
/// request — status, time, tests — the failures' messages under them.
struct APIRunnerView: View {
    @ObservedObject var runner: APIRunner
    @ObservedObject var workspace: APIWorkspace
    @ObservedObject var theme: ChromeTheme
    /// Opens a request in the editor.
    let open: (URL) -> Void
    /// Runs the same under bru, in a terminal tab.
    let runWithBru: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $runner.filter) {
                ForEach(APIRunner.Filter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(runner.shown) { entry in
                        APIRunnerRow(entry: entry, theme: theme) { open(entry.url) }
                    }
                }
            }
        }
        .accessibilityIdentifier("apiRunner")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: runner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Label(runner.environment ?? "No Environment", systemImage: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .help("The environment this run uses")
                Spacer()
                if runner.isRunning {
                    Button("Stop") { runner.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accentText)
                } else {
                    Button("Run Again") { runner.runAgain(workspace: workspace) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accentText)
                }
                if APIRunner.bruExecutable() != nil {
                    Button("Run with bru") { runWithBru() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                        .help("The same requests under Bruno's CLI, in a terminal tab — for scripts that need npm packages")
                }
            }
            HStack(spacing: 10) {
                if runner.isRunning {
                    ProgressView(value: Double(runner.done), total: Double(max(runner.entries.count, 1)))
                        .frame(width: 80)
                }
                Text(verbatim: "\(runner.done)/\(runner.entries.count)")
                    .help("Requests run")
                    .foregroundStyle(theme.text2)
                if runner.passedCount > 0 {
                    Text(verbatim: "\(runner.passedCount) passed").foregroundStyle(APIResponseView.statusColor(200))
                }
                if runner.failedCount > 0 {
                    Text(verbatim: "\(runner.failedCount) failed").foregroundStyle(APIResponseView.statusColor(500))
                }
                if runner.testsTotal > 0 {
                    Text(verbatim: "tests \(runner.testsPassed)/\(runner.testsTotal)").foregroundStyle(theme.text2)
                }
                Spacer()
                Text(verbatim: APIResponse.formatDuration(runner.duration * 1000)).foregroundStyle(theme.text3)
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            .accessibilityIdentifier("apiRunnerSummary")
        }
        .padding(12)
    }
}

private struct APIRunnerRow: View {
    let entry: APIRunner.Entry
    @ObservedObject var theme: ChromeTheme
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                stateIcon.frame(width: 14)
                Text(verbatim: APIMethodStyle.short(entry.method))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(APIMethodStyle.color(entry.method))
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: entry.name).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
                    if !entry.folder.isEmpty {
                        Text(verbatim: entry.folder).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let response = entry.result?.response {
                    Text(verbatim: "\(response.status)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(APIResponseView.statusColor(response.status))
                    Text(verbatim: APIResponse.formatDuration(response.duration)).font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                if let result = entry.result, !result.tests.isEmpty {
                    Text(verbatim: "\(result.passed)/\(result.tests.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(result.failed == 0 ? APIResponseView.statusColor(200) : APIResponseView.statusColor(500))
                }
            }
            if let result = entry.result {
                if let error = result.error {
                    Text(verbatim: error).font(.system(size: 11)).foregroundStyle(APIResponseView.statusColor(500)).padding(.leading, 54)
                }
                ForEach(Array(result.tests.filter { !$0.passed }.enumerated()), id: \.offset) { _, test in
                    Text(verbatim: "✕ \(test.name)\(test.error.map { " — \($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.text2)
                        .lineLimit(3)
                        .padding(.leading, 54)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Open the request")
    }

    @ViewBuilder private var stateIcon: some View {
        switch entry.state {
        case .waiting: Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(theme.text3)
        case .running: ProgressView().controlSize(.mini)
        case .skipped: Image(systemName: "forward.circle").font(.system(size: 11)).foregroundStyle(theme.text3)
        case .done:
            Image(systemName: entry.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(entry.passed ? APIResponseView.statusColor(200) : APIResponseView.statusColor(500))
        }
    }
}
