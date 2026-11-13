import AppKit
import SwiftUI

/// What a Prometheus, Loki or Tempo connection lists in the panel: metric
/// names; labels; tags — each one's labels or values read as it opens.
@MainActor
final class ObservabilityCatalog: ObservableObject {
    private weak var session: DatabaseSession?
    @Published private(set) var names: [String] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var values: [String: [String]] = [:]
    @Published private(set) var failed: [String: String] = [:]

    init(session: DatabaseSession) { self.session = session }

    func load(force: Bool = false) async {
        guard force || !loaded, let driver = session?.observability else { return }
        do {
            names = try await driver.names()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func loadValues(_ name: String) async {
        guard values[name] == nil, let driver = session?.observability else { return }
        do {
            values[name] = try await driver.values(of: name)
        } catch {
            failed[name] = error.localizedDescription
            values[name] = []
        }
    }
}

extension DatabaseSession {
    /// What a query on one value looks like in each language.
    nonisolated static func selector(_ kind: DatabaseKind, name: String, value: String) -> String {
        let quoted = "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        switch kind {
        case .loki: return "{\(name)=\(quoted)}"
        case .tempo:
            // status and kind are words, not strings.
            let bare = ["status", "kind", "span:status", "span:kind"].contains(name)
            // `resource.x` and `span:name` are whole; a bare tag is any scope's (`.x`).
            return "{ \(name.contains(".") || name.contains(":") || bare ? name : "." + name) = \(bare ? value : quoted) }"
        default: return "\(name){\(value)!=\"\"}"
        }
    }
}

struct ObservabilityTree: View {
    let connection: DatabaseConnection
    @ObservedObject var session: DatabaseSession
    @ObservedObject var catalog: ObservabilityCatalog
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    private var key: String { connection.id.uuidString }

    /// Names shown at most: a Prometheus with ten thousand metrics is filtered, not scrolled.
    static let shownLimit = 500

    private var folderTitle: String {
        switch connection.kind {
        case .prometheus: "Metrics"
        case .loki: "Labels"
        default: "Tags"
        }
    }

    var body: some View {
        Group {
            switch connection.kind {
            case .prometheus:
                action("Targets", symbol: "dot.radiowaves.up.forward", ".targets")
                action("Alerts", symbol: "bell", ".alerts")
                action("Rules", symbol: "list.bullet.rectangle", ".rules")
            case .tempo:
                action("Recent Traces", symbol: "point.3.connected.trianglepath.dotted", "{}")
            default:
                EmptyView()
            }
            let folder = "\(key)/names"
            TreeRow(
                depth: 1, open: model.expanded.contains(folder), symbol: "folder", title: folderTitle,
                detail: catalog.loaded ? "\(catalog.names.count)" : nil, dot: nil, theme: theme
            ) {
                if model.expanded.contains(folder) {
                    model.expanded.remove(folder)
                } else {
                    model.expanded.insert(folder)
                    Task { await catalog.load() }
                }
            }
            .contextMenu { Button("Refresh") { Task { await catalog.load(force: true) } } }
            .accessibilityIdentifier("observability-\(folderTitle)")
            if model.expanded.contains(folder) { names(folder) }
        }
        .task { if model.expanded.contains("\(key)/names") { await catalog.load() } }
    }

    private func action(_ title: String, symbol: String, _ query: String) -> some View {
        TreeRow(depth: 1, open: nil, symbol: symbol, title: title, detail: nil, dot: nil, theme: theme) {
            actions.run(connection, query)
        }
        .accessibilityIdentifier("observability-\(title)")
    }

    @ViewBuilder private func names(_ folder: String) -> some View {
        if let error = catalog.error {
            note(error, error: true)
        } else if !catalog.loaded {
            note("Reading…")
        } else {
            let matching = model.filter.isEmpty ? catalog.names : catalog.names.filter { $0.localizedCaseInsensitiveContains(model.filter) }
            if matching.isEmpty { note(catalog.names.isEmpty ? "None in the last 6 hours" : "Nothing matches") }
            ForEach(matching.prefix(Self.shownLimit), id: \.self) { name in nameRow(name, folder: folder) }
            if matching.count > Self.shownLimit {
                note("\(matching.count - Self.shownLimit) more — the panel's Filter finds them")
            }
        }
    }

    @ViewBuilder private func nameRow(_ name: String, folder: String) -> some View {
        let key = "\(folder)/\(name)"
        let isMetric = connection.kind == .prometheus
        // A Tempo tag without its scope (`service.name`, its whole name on
        // hover): cut in the middle, `resource.…` names all looked the same.
        let scoped = connection.kind == .tempo ? name.split(separator: ".", maxSplits: 1).map(String.init) : []
        let scopes = ["resource", "span", "event", "link", "instrumentation"]
        let title = scoped.count == 2 && scopes.contains(scoped[0]) ? scoped[1] : name
        TreeRow(
            depth: 2, open: model.expanded.contains(key), symbol: isMetric ? "chart.xyaxis.line" : "tag", title: title, detail: nil, dot: nil,
            theme: theme
        ) {
            if isMetric {
                // A metric's click graphs it; its chevron is its labels.
                actions.run(connection, name)
            } else if model.expanded.contains(key) {
                model.expanded.remove(key)
            } else {
                model.expanded.insert(key)
                Task { await catalog.loadValues(name) }
            }
        }
        .contextMenu {
            if isMetric {
                Button("Graph") { actions.run(connection, name) }
                Button("Graph rate(…[5m])") { actions.run(connection, "rate(\(name)[5m])") }
                Button("Show Labels") {
                    model.expanded.insert(key)
                    Task { await catalog.loadValues(name) }
                }
            }
            Button("Copy Name") { copy(name) }
        }
        .accessibilityIdentifier("observabilityName-\(name)")
        if model.expanded.contains(key) {
            if let values = catalog.values[name] {
                if let failed = catalog.failed[name] { note(failed, depth: 3, error: true) }
                if values.isEmpty, catalog.failed[name] == nil { note("None", depth: 3) }
                ForEach(values.prefix(Self.shownLimit), id: \.self) { value in
                    TreeRow(depth: 3, open: nil, symbol: isMetric ? "tag" : "line.3.horizontal", title: value, detail: nil, dot: nil, theme: theme) {
                        actions.run(
                            connection, isMetric ? "sum by (\(value)) (\(name))" : DatabaseSession.selector(connection.kind, name: name, value: value))
                    }
                    .contextMenu {
                        if isMetric {
                            Button("Graph by \(value)") { actions.run(connection, "sum by (\(value)) (\(name))") }
                        } else {
                            Button("Query") { actions.run(connection, DatabaseSession.selector(connection.kind, name: name, value: value)) }
                        }
                        Button("Copy") { copy(value) }
                    }
                    .accessibilityIdentifier("observabilityValue-\(name)-\(value)")
                }
            } else {
                note("Reading…", depth: 3)
            }
        }
    }

    private func note(_ text: String, depth: Int = 2, error: Bool = false) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(error ? DiffColors.removed : theme.text3)
            .lineLimit(4).textSelection(.enabled)
            .padding(.leading, 28 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
