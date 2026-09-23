import AppKit
import SwiftUI

/// Tab Info: where the tab is, and what it is running.
struct TabInfoView: View {
    @ObservedObject var model: TabInfoModel
    let theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            locationSection
            processSection
            portSection
            claudeSection
        }
        .padding(16)
        .frame(width: 480)
        .foregroundStyle(theme.text)
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.tab.agent?.symbol ?? "terminal").font(.system(size: 13))
            Text(model.tab.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer()
        }
    }

    @ViewBuilder private var locationSection: some View {
        if let location = model.location {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text((location.directory as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder")
                }
                if location.checkout != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").frame(width: 16)
                        Text(location.branch ?? "(detached)")
                        if let main = location.worktreeOf {
                            Text("· worktree of \(main)").foregroundStyle(theme.dimText)
                        }
                        if let changed = location.changedFiles {
                            Text(changed == 0 ? "· clean" : "· \(changed) changed").foregroundStyle(theme.dimText)
                        }
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Running").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.dimText)
                Spacer()
                Text("CPU").frame(width: 60, alignment: .trailing)
                Text("Memory").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.dimText)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.node.pid) { row in
                        ProcessRow(node: row.node, depth: row.depth, theme: theme)
                    }
                }
            }
            // As tall as its rows, up to 12 of them; then it scrolls.
            .frame(height: CGFloat(min(max(rows.count, 1), 12)) * 20)
            Divider().opacity(0.4)
            HStack {
                Text("Total").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Self.cpu(model.totalCPU)).frame(width: 60, alignment: .trailing)
                Text(Self.memory(model.totalMemory)).frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder private var portSection: some View {
        if !model.ports.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Listening").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.dimText)
                ForEach(model.ports) { port in
                    HStack(spacing: 8) {
                        Text(verbatim: ":\(port.port)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(port.process).foregroundStyle(theme.dimText)
                        if port.address != "*" && port.address != "127.0.0.1" && port.address != "[::1]" {
                            Text(port.address).font(.system(size: 10)).foregroundStyle(theme.dimText)
                        }
                        Spacer()
                        if let url = port.url {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open", systemImage: "arrow.up.forward.app")
                            }
                            .controlSize(.small)
                            .help(url.absoluteString)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder private var claudeSection: some View {
        if model.readingClaude {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the Claude session…").foregroundStyle(theme.dimText)
            }
            .font(.system(size: 12))
        } else if let usage = model.claude {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Claude session").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.dimText)
                    Spacer()
                    if let modelName = usage.model {
                        Text(verbatim: modelName.replacingOccurrences(of: "claude-", with: "")).foregroundStyle(theme.dimText)
                    }
                    if let started = usage.started, let last = usage.lastActivity {
                        Text(verbatim: "· " + Self.duration(last.timeIntervalSince(started))).foregroundStyle(theme.dimText)
                    }
                }
                .font(.system(size: 11))
                HStack(spacing: 14) {
                    tokenStat("input", usage.input)
                    tokenStat("output", usage.output)
                    tokenStat("cache read", usage.cacheRead)
                    tokenStat("cache write", usage.cacheWrite)
                }
                Text(verbatim: "\(usage.replies) replies · \(Self.tokens(usage.total)) tokens in all")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dimText)
            }
        }
    }

    private func tokenStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: Self.tokens(value)).font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 10)).foregroundStyle(theme.dimText)
        }
    }

    /// 1234 → 1.2K, 38_400_000 → 38M.
    nonisolated static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: n < 10_000 ? "%.1fK" : "%.0fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: n < 10_000_000 ? "%.1fM" : "%.0fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    /// The tree flattened with depths, for an indented list.
    private var rows: [(node: ProcessNode, depth: Int)] {
        func walk(_ nodes: [ProcessNode], _ depth: Int) -> [(ProcessNode, Int)] {
            nodes.flatMap { [($0, depth)] + walk($0.children, depth + 1) }
        }
        return walk(model.processes, 0)
    }

    nonisolated static func cpu(_ percent: Double) -> String { String(format: "%.0f%%", percent) }

    nonisolated static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private struct ProcessRow: View {
    let node: ProcessNode
    let depth: Int
    let theme: ChromeTheme

    var body: some View {
        HStack(spacing: 4) {
            if depth > 0 {
                Text("└").foregroundStyle(theme.dimText).padding(.leading, CGFloat(depth - 1) * 14)
            }
            Text(node.name).lineLimit(1)
            Text(String(node.pid)).font(.system(size: 10)).foregroundStyle(theme.dimText)
            Spacer(minLength: 8)
            Text(TabInfoView.cpu(node.cpuPercent))
                .foregroundStyle(node.cpuPercent >= 50 ? TabStatusStyle.signal : theme.text)
                .frame(width: 60, alignment: .trailing)
            Text(TabInfoView.memory(node.memory)).frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 20)
        .help(node.command.isEmpty ? node.name : node.command)
    }
}
