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

    /// The tree flattened with depths, for an indented list.
    private var rows: [(node: ProcessNode, depth: Int)] {
        func walk(_ nodes: [ProcessNode], _ depth: Int) -> [(ProcessNode, Int)] {
            nodes.flatMap { [($0, depth)] + walk($0.children, depth + 1) }
        }
        return walk(model.processes, 0)
    }

    static func cpu(_ percent: Double) -> String { String(format: "%.0f%%", percent) }

    static func memory(_ bytes: UInt64) -> String {
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
