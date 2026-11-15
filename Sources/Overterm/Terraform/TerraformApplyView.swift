import SwiftUI

/// The apply in the right slot (6.4): the plan view become its progress
/// in place — the same rows, each waiting, running, done or failed, its
/// provisioners' output under it, an error's diagnostic with "Open at";
/// the bar's counts and the time it has run; Stop (`.`). Then how it
/// ended, from the exit code and an apply summary. One followed again
/// after Overterm last quit says so.
struct TerraformApplyView: View {
    @ObservedObject var apply: TerraformApplyRun
    @ObservedObject var pane: TerraformPlanPaneModel
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPlanActions
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var red: Color { TerraformPanelView.production }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(apply.rows) { row in rowView(row) }
                    if !apply.log.isEmpty {
                        Text("LOG").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text3)
                            .padding(.horizontal, 12).padding(.top, 10)
                        ForEach(Array(apply.log.suffix(300).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                        }
                        .accessibilityIdentifier("terraform.apply.log")
                    }
                }
                .padding(.bottom, 10)
            }
            .background(
                TerraformPlanKeyCatcher(
                    request: pane.keyboard,
                    press: { code, characters in
                        guard let key = TerraformPlanPaneModel.key(keyCode: code, characters: characters), key == .stop || key == .askWhy else { return false }
                        return pane.press(key, actions: actions)
                    },
                    copy: { nil }))
        }
        .onReceive(ticker) { now = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.apply")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if apply.marker.rootClass == TerraformClass.production.rawValue {
                    Text("PRODUCTION").font(.system(size: ChromeMetrics.text(9.5), weight: .bold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).frame(height: 16).background(RoundedRectangle(cornerRadius: 4).fill(red))
                }
                Text(verbatim: "Apply · " + apply.marker.name).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "· workspace \(apply.marker.workspace) · \(apply.worktree) · since \(TerraformPlanRun.clock(apply.started))")
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: actions.close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(10))) }
                    .buttonStyle(.plain).foregroundStyle(theme.text3).help("Close the pane: the apply goes on")
            }
            if apply.reattached {
                Text(
                    verbatim:
                        "An apply in \(apply.marker.name) has been running since \(TerraformPlanRun.clock(apply.started)), started before Overterm last quit."
                )
                .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.orangeText)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.apply.reattached")
            }
            HStack(spacing: 8) {
                switch apply.phase {
                case .running:
                    ProgressView().controlSize(.small)
                    status(apply.progressText(now: now), theme.text2)
                    stop
                case .stopping(let times):
                    ProgressView().controlSize(.small)
                    status(
                        times == 1
                            ? "Stopping: running resources may be left tainted · \(apply.progressText(now: now))"
                            : "Stopping now — data loss may occur · \(apply.progressText(now: now))", theme.orangeText)
                    stop
                case .applied(let said):
                    status(said, theme.accentText)
                case .failed(let said):
                    status(said, red)
                case .stopped(let said):
                    status(said, theme.orangeText)
                }
                Spacer(minLength: 0)
            }
            if let silence = apply.silenceText(now: now) {
                Text(verbatim: silence).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !apply.isGoing {
                HStack(spacing: 6) {
                    button("Plan Again", "arrow.clockwise") { actions.planAfterApply(apply) }.accessibilityIdentifier("terraform.apply.planAgain")
                    // The apply's own failure, a reattached one's too (2.3, 6.4).
                    if case .failed = apply.phase {
                        button("Ask Why", "questionmark.bubble") { actions.askWhyApply(apply) }.accessibilityIdentifier("terraform.apply.askWhy")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var stop: some View {
        button(apply.phase == .running ? "Stop" : "Stop Again…", "stop.circle") { actions.stopApply(apply) }
            .accessibilityIdentifier("terraform.apply.stop")
    }

    private func status(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5), weight: .semibold)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.apply.status")
    }

    private func rowView(_ row: TerraformApplyRun.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: TerraformApplySheet.symbol(row.action)).font(.system(size: ChromeMetrics.text(12), weight: .bold, design: .monospaced))
                    .foregroundStyle(row.action == .delete || row.action == .replace ? red : theme.text).frame(width: 14)
                Text(verbatim: TerraformPlanText.escaped(row.address)).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                    .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: stateWords(row)).font(.system(size: ChromeMetrics.text(10.5), weight: .medium)).foregroundStyle(stateColor(row.state))
            }
            if let error = row.error {
                Text(verbatim: error).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(red).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                if let file = row.file {
                    Button {
                        actions.open(apply.rootFolder.appendingPathComponent(file), row.line)
                    } label: {
                        Text(verbatim: "Open at \(file)" + (row.line.map { ":\($0)" } ?? "")).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    }
                    .buttonStyle(.link).padding(.leading, 20)
                }
            }
            ForEach(Array(row.output.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.system(size: ChromeMetrics.text(10), design: .monospaced)).foregroundStyle(theme.text3).lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terraform.apply.row.\(row.address)")
    }

    private func stateWords(_ row: TerraformApplyRun.Row) -> String {
        let elapsed = row.elapsed.map { " · \($0)s" } ?? ""
        switch row.state {
        case .waiting: return "waiting"
        case .running: return (row.expected > 1 ? "running \(row.completed + 1) of \(row.expected)" : "running") + elapsed
        case .done: return "done" + elapsed
        case .errored: return "failed" + elapsed
        }
    }

    private func stateColor(_ state: TerraformApplyRun.RowState) -> Color {
        switch state {
        case .waiting: theme.text3
        case .running: theme.text
        case .done: theme.accentText
        case .errored: red
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
