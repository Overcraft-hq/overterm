import AppKit
import SwiftUI

/// A Redis database in the panel: its keys as folders (`user:1:…`), a
/// pattern and a type to SCAN by, each key's type as a badge — Redis
/// Insight's browser, in the sidebar. A key opens its page on the right.
struct RedisDatabaseTree: View {
    let treeKey: String
    let db: Int
    @ObservedObject var session: DatabaseSession
    @ObservedObject var browser: RedisBrowser
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    var body: some View {
        TreeRow(
            depth: 1, open: model.expanded.contains(treeKey), symbol: "square.stack.3d.up", title: "db\(db)",
            detail: browser.total.map { "\($0) keys" }, dot: nil, theme: theme
        ) {
            if model.expanded.contains(treeKey) {
                model.expanded.remove(treeKey)
            } else {
                model.expanded.insert(treeKey)
                if !browser.scanned { Task { await browser.scan() } }
            }
        }
        .contextMenu {
            if !session.connection.readOnly { Button("New Key…") { actions.newRedisKey(session, db) } }
            Button("Refresh") { Task { await browser.scan() } }
            Button("Server Info") { actions.redisServer(session) }
            Divider()
            Button("New Console") { actions.console(session.connection) }
        }
        .accessibilityIdentifier("redis-db\(db)")
        if model.expanded.contains(treeKey) {
            filter
            if let error = browser.error { RedisNote(text: error, depth: 2, error: true, theme: theme) }
            RedisFolderRows(folder: browser.tree.root, depth: 2, treeKey: treeKey, db: db, session: session, model: model, theme: theme, actions: actions)
            if browser.scanned, browser.keys.isEmpty, browser.error == nil {
                RedisNote(text: browser.pattern.isEmpty && browser.type == nil ? "No keys" : "No keys match", depth: 2, theme: theme)
            }
            if browser.isScanning {
                RedisNote(text: "Scanning…", depth: 2, theme: theme)
            } else if browser.hasMore {
                Button {
                    Task { await browser.more() }
                } label: {
                    Text(verbatim: "Scan more — \(browser.keys.count)\(browser.total.map { " of \($0)" } ?? "") so far")
                }
                .buttonStyle(.plain).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.accentText)
                .padding(.leading, 36 + 2 * 14).padding(.vertical, 3)
            }
        }
    }

    /// The pattern (SCAN MATCH) and the type, as Insight's browser has them.
    private var filter: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            TextField("user:*", text: $browser.pattern)
                .textFieldStyle(.plain).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                .onSubmit { Task { await browser.scan() } }
                .accessibilityIdentifier("redisPattern")
            Menu {
                Button("All Types") {
                    browser.type = nil
                    Task { await browser.scan() }
                }
                Divider()
                ForEach(RedisKeyType.creatable, id: \.self) { type in
                    Button(RedisKeyType.label(type)) {
                        browser.type = type
                        Task { await browser.scan() }
                    }
                }
            } label: {
                Text(verbatim: browser.type.map(RedisKeyType.label) ?? "ALL").font(.system(size: ChromeMetrics.text(9.5), weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Only keys of this type (SCAN … TYPE)")
        }
        .padding(.horizontal, 6)
        .frame(height: ChromeMetrics.row(22))
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.rowHover.opacity(0.7)))
        .padding(.leading, 8 + 2 * 14).padding(.trailing, 8).padding(.vertical, 2)
    }
}

/// A folder's folders, then its keys.
private struct RedisFolderRows: View {
    let folder: RedisKeyTree.Folder
    let depth: Int
    let treeKey: String
    let db: Int
    @ObservedObject var session: DatabaseSession
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    var body: some View {
        ForEach(folder.folders, id: \.prefix) { child in
            let key = "\(treeKey)/\(child.prefix)"
            TreeRow(depth: depth, open: model.expanded.contains(key), symbol: "folder", title: child.name, detail: "\(child.count)", dot: nil, theme: theme) {
                if model.expanded.contains(key) { model.expanded.remove(key) } else { model.expanded.insert(key) }
            }
            .contextMenu {
                Button("Copy Pattern") { copy(child.prefix + "*") }
            }
            .accessibilityIdentifier("redisFolder-\(child.prefix)")
            if model.expanded.contains(key) {
                RedisFolderRows(folder: child, depth: depth + 1, treeKey: treeKey, db: db, session: session, model: model, theme: theme, actions: actions)
            }
        }
        ForEach(folder.keys, id: \.name) { entry in
            RedisKeyRow(entry: entry, shown: String(entry.name.dropFirst(folder.prefix.count)), depth: depth, theme: theme) {
                actions.openRedisKey(session, db, entry.name)
            }
            .contextMenu {
                Button("Open") { actions.openRedisKey(session, db, entry.name) }
                Button("View in Console") { actions.run(session.connection, (db == 0 ? "" : "SELECT \(db)\n") + "VIEW \(RedisProtocol.quoted(entry.name))") }
                Divider()
                Button("Copy Name") { copy(entry.name) }
                if !session.connection.readOnly {
                    Divider()
                    Button("Delete…") { actions.deleteRedisKey(session, db, entry.name) }
                }
            }
            .accessibilityIdentifier("redisKey-\(entry.name)")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A key: its type's badge and its name past its folder.
private struct RedisKeyRow: View {
    let entry: RedisKeyEntry
    let shown: String
    let depth: Int
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            RedisTypeBadge(type: entry.type, compact: true)
            Text(verbatim: shown.isEmpty ? entry.name : shown).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(depth) * 14 + 4)
        .padding(.trailing, 8)
        .frame(height: ChromeMetrics.row(24))
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(entry.name)
    }
}

/// A key type's badge, in the colours Insight gives them.
struct RedisTypeBadge: View {
    let type: String
    var compact = false

    static func color(_ type: String) -> Color {
        switch type {
        case "string": Color(red: 0.36, green: 0.55, blue: 0.95)
        case "hash": Color(red: 0.62, green: 0.42, blue: 0.95)
        case "list": Color(red: 0.25, green: 0.68, blue: 0.48)
        case "set": Color(red: 0.93, green: 0.58, blue: 0.20)
        case "zset": Color(red: 0.90, green: 0.35, blue: 0.45)
        case "stream": Color(red: 0.20, green: 0.66, blue: 0.75)
        case "ReJSON-RL": Color(red: 0.80, green: 0.66, blue: 0.15)
        default: Color.gray
        }
    }

    var body: some View {
        Text(verbatim: RedisKeyType.label(type))
            .font(.system(size: ChromeMetrics.text(compact ? 8 : 9.5), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 3 : 5)
            .frame(minWidth: compact ? 38 : 0)
            .frame(height: compact ? 14 : 17)
            .background(RoundedRectangle(cornerRadius: 3).fill(Self.color(type)))
            // Whole, always: the key's name is what gives way.
            .fixedSize()
    }
}

private struct RedisNote: View {
    let text: String
    let depth: Int
    var error = false
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(error ? DiffColors.removed : theme.text3)
            .lineLimit(4).textSelection(.enabled)
            .padding(.leading, 28 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
    }
}
