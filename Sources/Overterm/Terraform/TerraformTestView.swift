import SwiftUI

/// A `terraform test` in the right slot (analysis 2.9, stage 2d): the
/// root, the files it ran and whether every provider was mocked; each
/// run by file with its status, a failure's diagnostics under it with
/// "Open at file:line"; the summary; the raw log under all of it.
struct TerraformTestView: View {
    @ObservedObject var run: TerraformTestRun
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPlanActions

    private var red: Color { TerraformPanelView.production }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(run.report.files) { file in
                        fileRow(file)
                    }
                    ForEach(Array(run.report.diagnostics.prefix(20).enumerated()), id: \.offset) { _, diagnostic in
                        diagnosticView(diagnostic).padding(.horizontal, 12)
                    }
                    if !run.log.isEmpty {
                        Text("LOG").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text3)
                            .padding(.horizontal, 12).padding(.top, 10)
                        ForEach(Array(run.log.suffix(200).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("terraform.test.runs")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.test")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if run.card.isProduction {
                    Text("PRODUCTION").font(.system(size: ChromeMetrics.text(9.5), weight: .bold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).frame(height: 16).background(RoundedRectangle(cornerRadius: 4).fill(red))
                }
                Text(verbatim: "Test · " + run.card.name).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "· \(run.scope) · \(run.isGoing ? "running" : run.age())" + (run.agent.map { " · asked by \($0)" } ?? ""))
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button(action: actions.close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(10))) }
                    .buttonStyle(.plain).foregroundStyle(theme.text3).help("Close the pane")
            }
            HStack(spacing: 6) {
                if run.isGoing {
                    button("Stop", "stop.circle") { run.stop() }.accessibilityIdentifier("terraform.test.stop")
                } else {
                    button("Run Again", "arrow.clockwise") { actions.testAgain(run) }.accessibilityIdentifier("terraform.test.again")
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: status.text).font(.system(size: ChromeMetrics.text(11.5), weight: .semibold)).foregroundStyle(status.color)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.test.status")
            if let mocking = run.mocking {
                Text(
                    verbatim: mocking.isMocked
                        ? "Every provider mocked: run without credentials."
                        : "Real providers (\(Self.why(mocking))): this run creates real infrastructure with the root's credentials."
                )
                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(mocking.isMocked ? theme.text3 : theme.orangeText)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.test.mocking")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    static func why(_ mocking: TerraformTestFiles.Mocking) -> String {
        if case .real(let why) = mocking { return why }
        return ""
    }

    private var status: (text: String, color: Color) {
        switch run.phase {
        case .preparing: ("Reading the test files…", theme.text2)
        case .running:
            ("Running · \(run.report.runs.filter { !($0.status == .pending || $0.status == .running) }.count) of \(run.report.runs.count) runs", theme.text2)
        case .passed(let said): ("Passed — \(said).", theme.text2)
        case .failed(let said): ("Failed — \(said)", red)
        case .refused(let why): (why, red)
        case .stopped: ("Stopped.", theme.orangeText)
        }
    }

    private func fileRow(_ file: TerraformTestReport.FileRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: file.status.symbol).font(.system(size: ChromeMetrics.text(11.5), weight: .bold, design: .monospaced))
                    .foregroundStyle(color(file.status)).frame(width: 14)
                Button {
                    actions.open(run.card.folder.appendingPathComponent(file.path), nil)
                } label: {
                    Text(verbatim: file.path).font(.system(size: ChromeMetrics.text(11.5), weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.plain).foregroundStyle(theme.text)
            }
            ForEach(file.diagnostics.prefix(10).indices, id: \.self) { index in
                diagnosticView(file.diagnostics[index]).padding(.leading, 20)
            }
            ForEach(file.runs) { row in
                runRow(row)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.test.file.\(file.path)")
    }

    private func runRow(_ row: TerraformTestReport.RunRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: row.status.symbol).font(.system(size: ChromeMetrics.text(11), weight: .bold, design: .monospaced))
                    .foregroundStyle(color(row.status)).frame(width: 14)
                Text(verbatim: "run \"\(row.name)\"").font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text)
                Text(verbatim: row.status.rawValue).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(color(row.status))
                if let line = row.line {
                    Button {
                        actions.open(run.card.folder.appendingPathComponent(row.file), line)
                    } label: {
                        Text(verbatim: "line \(line)").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            ForEach(row.diagnostics.prefix(10).indices, id: \.self) { index in
                diagnosticView(row.diagnostics[index]).padding(.leading, 20)
            }
        }
        .padding(.leading, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: "run \(row.name) \(row.status.rawValue)" + row.diagnostics.map { " — " + TerraformTestReport.said($0) }.joined())
        )
        .accessibilityIdentifier("terraform.test.run.\(row.file).\(row.name)")
    }

    private func diagnosticView(_ diagnostic: TerraformDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(diagnostic.severity == .error ? "Error" : "Warning"): \(diagnostic.summary)")
                .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(diagnostic.severity == .error ? red : theme.orangeText)
            if !diagnostic.detail.isEmpty {
                Text(verbatim: diagnostic.detail).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file = diagnostic.file {
                Button {
                    actions.open(run.card.folder.appendingPathComponent(file), diagnostic.start?.line)
                } label: {
                    Text(verbatim: "Open at \(file)" + (diagnostic.start.map { ":\($0.line)" } ?? "")).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                }
                .buttonStyle(.link)
            }
        }
    }

    private func color(_ status: TerraformTestReport.Status) -> Color {
        switch status {
        case .pass: theme.accentText
        case .fail, .error: red
        case .skip, .pending: theme.text3
        case .running: theme.text2
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: ChromeMetrics.text(11)))
                .padding(.horizontal, 7).frame(height: ChromeMetrics.row(22))
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.iconBg))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }
}

/// A root card's drift and test lines (2.6, 2.9): its last drift check,
/// its age always said, a stale one's count as then; its last test run.
/// Each a button to it in the slot. Nothing when neither ran.
struct TerraformRootChecksView: View {
    let card: TerraformRootCard
    let checkout: URL
    @ObservedObject var registry: TerraformRunRegistry
    @ObservedObject var tests: TerraformTestResults
    @ObservedObject var theme: ChromeTheme
    let showPlan: (TerraformPlanRun) -> Void
    let showTest: (TerraformTestRun) -> Void

    var body: some View {
        if let drift = registry.latest(checkout: checkout, root: card.path, drift: true) {
            TerraformDriftLineView(run: drift, registry: registry, theme: theme, show: showPlan)
                .accessibilityIdentifier("terraform.panel.drift.\(card.path)")
        }
        if let test = tests.latest(checkout: checkout, root: card.path) {
            TerraformTestLineView(run: test, theme: theme, show: showTest)
                .accessibilityIdentifier("terraform.panel.test.\(card.path)")
        }
    }
}

private struct TerraformDriftLineView: View {
    @ObservedObject var run: TerraformPlanRun
    @ObservedObject var registry: TerraformRunRegistry
    @ObservedObject var theme: ChromeTheme
    let show: (TerraformPlanRun) -> Void

    var body: some View {
        Button {
            show(run)
        } label: {
            // On a clock: its age moves, and past 30 minutes it says stale.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let line = run.driftLine(registry, now: context.date)
                Text(verbatim: line.text).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    .foregroundStyle(line.drifted ? theme.orangeText : line.stale ? theme.text3 : theme.text2).lineLimit(2).truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .help("Show the drift check: Accept into State writes what the providers read into the state")
    }
}

private struct TerraformTestLineView: View {
    @ObservedObject var run: TerraformTestRun
    @ObservedObject var theme: ChromeTheme
    let show: (TerraformTestRun) -> Void

    var body: some View {
        Button {
            show(run)
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: words(now: context.date)).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    .foregroundStyle(run.failed ? TerraformPanelView.production : theme.text2).lineLimit(1).truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .help("Show the test run")
    }

    private func words(now: Date) -> String {
        run.line(now: now)
    }
}
