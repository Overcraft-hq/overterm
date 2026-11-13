import AppKit
import SwiftUI

/// What the Redis page asks the window to do.
struct RedisSlotActions {
    /// Asks (title, detail, button) before something that can't be undone.
    var confirm: (_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) -> Void
    var openKey: (DatabaseSession, Int, String) -> Void
    var close: () -> Void
}

/// The right-hand pane's Redis page.
struct RedisSlotView: View {
    @ObservedObject var model: RedisSlotModel
    @ObservedObject var theme: ChromeTheme
    let actions: RedisSlotActions

    var body: some View {
        Group {
            switch model.page {
            case .key: RedisKeyView(model: model.key, theme: theme, actions: actions)
            case .newKey: RedisNewKeyView(model: model, theme: theme, actions: actions)
            case .server: RedisServerView(model: model.server, theme: theme, actions: actions)
            case .none:
                VStack {
                    Text("Pick a key in the Database panel (⌥⌘B).").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
                    Spacer()
                }
                .frame(maxWidth: .infinity).padding(16)
            }
        }
        .background(theme.panelGround)
    }
}

/// The pieces every Redis page is made of.
@MainActor
struct RedisChrome {
    let theme: ChromeTheme

    func header<Leading: View>(_ title: String, close: @escaping () -> Void, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(verbatim: title).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11))) }
                .buttonStyle(.plain).foregroundStyle(theme.dimText).help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: ChromeMetrics.row(34))
    }

    func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(12))).frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.selected.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }

    func field(_ label: String, _ text: Binding<String>, mono: Bool = true) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: ChromeMetrics.text(12), design: mono ? .monospaced : .default))
            .padding(.horizontal, 6)
            .frame(height: ChromeMetrics.row(24))
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.rowHover.opacity(0.8)))
    }

    func editor(_ text: Binding<String>, minHeight: CGFloat = 80) -> some View {
        TextEditor(text: text)
            .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.rowHover.opacity(0.8)))
    }

    func error(_ text: String?) -> some View {
        Group {
            if let text {
                Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(DiffColors.removed)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func note(_ text: String) -> some View {
        VStack {
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText).multilineTextAlignment(.center)
                .textSelection(.enabled)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: A key

struct RedisKeyView: View {
    @ObservedObject var model: RedisKeyModel
    @ObservedObject var theme: ChromeTheme
    let actions: RedisSlotActions
    @State private var renaming: String?
    @State private var ttlText = ""
    @State private var editingTTL = false
    @State private var selected: RedisKeyModel.Row?
    @State private var editValue = ""
    @State private var adding = false
    @State private var newValues = ["", ""]
    @State private var addAtHead = false

    private var chrome: RedisChrome { RedisChrome(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome.header(model.name, close: actions.close) {
                if !model.type.isEmpty { RedisTypeBadge(type: model.type) }
            }
            Divider().opacity(0.3)
            switch model.phase {
            case .idle, .loading: chrome.note("Reading…")
            case .failed(let message): chrome.note(message)
            case .loaded:
                details
                Divider().opacity(0.3)
                if model.isText { textValue } else { collection }
            }
        }
        .onChange(of: model.name) { _ in
            selected = nil
            adding = false
        }
    }

    // MARK: What it is

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let renaming {
                HStack(spacing: 6) {
                    chrome.field("New name", Binding(get: { renaming }, set: { self.renaming = $0 }))
                        .onSubmit { rename() }
                    Button("Rename") { rename() }.controlSize(.small)
                    Button("Cancel") { self.renaming = nil }.controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                Button {
                    ttlText = model.ttl < 0 ? "" : String(model.ttl)
                    editingTTL = true
                } label: {
                    Label(model.ttl < 0 ? "No expiry" : "TTL \(RedisKeyInfo.duration(model.ttl))", systemImage: "timer")
                }
                .buttonStyle(.plain)
                .disabled(model.readOnly)
                .popover(isPresented: $editingTTL, arrowEdge: .bottom) { ttlEditor }
                .help("The key's time to live — click to change it")
                if let memory = model.memory { Text(verbatim: "\(FilePreview.size(Int64(memory))) in memory").help("MEMORY USAGE") }
                if let length = model.length { Text(verbatim: lengthText(length)) }
                if let encoding = model.encoding { Text(verbatim: encoding).help("OBJECT ENCODING") }
                Text(verbatim: "db\(model.db)")
            }
            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            HStack(spacing: 4) {
                chrome.iconButton("arrow.clockwise", "Read it again") { model.reload() }
                chrome.iconButton("doc.on.doc", "Copy the key's name") { chrome.copy(model.name) }
                if !model.readOnly {
                    chrome.iconButton("pencil", "Rename…") { renaming = model.name }
                }
                Spacer(minLength: 0)
                if !model.readOnly {
                    chrome.iconButton("trash", "Delete the key…") { delete() }
                        .accessibilityIdentifier("redisDeleteKey")
                }
            }
            chrome.error(model.error)
        }
        .padding(12)
    }

    private func lengthText(_ n: Int) -> String {
        switch model.type {
        case "string": FilePreview.size(Int64(n))
        case "hash": n == 1 ? "1 field" : "\(n) fields"
        case "stream": n == 1 ? "1 entry" : "\(n) entries"
        case "list": n == 1 ? "1 element" : "\(n) elements"
        default: n == 1 ? "1 member" : "\(n) members"
        }
    }

    private var ttlEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time to live").font(.system(size: ChromeMetrics.text(12), weight: .semibold))
            HStack {
                chrome.field("Seconds", $ttlText).frame(width: 120).onSubmit { applyTTL() }
                Text("seconds").foregroundStyle(theme.dimText)
            }
            HStack {
                Button("No Expiry") {
                    Task { await model.setTTL(-1) }
                    editingTTL = false
                }
                Spacer()
                Button("Set") { applyTTL() }.keyboardShortcut(.defaultAction).disabled(Int(ttlText) == nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func applyTTL() {
        guard let seconds = Int(ttlText), seconds > 0 else { return }
        Task { await model.setTTL(seconds) }
        editingTTL = false
    }

    private func rename() {
        guard let newName = renaming, let session = model.session else { return }
        let old = model.name
        let db = model.db
        Task {
            if await model.rename(to: newName) {
                renaming = nil
                session.browser(db).removed(old)
                session.browser(db).added(RedisKeyEntry(name: newName, type: model.type))
            }
        }
    }

    private func delete() {
        guard let session = model.session else { return }
        let name = model.name
        let db = model.db
        actions.confirm("Delete “\(name)”?", "From db\(db) of \(session.connection.name). This can't be undone.", "Delete") {
            Task {
                if await model.delete() {
                    session.browser(db).removed(name)
                    actions.close()
                }
            }
        }
    }

    // MARK: A string, a JSON document

    private var textValue: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.textTooLong {
                Text("The value's first \(FilePreview.size(Int64(RedisKeyModel.textLimit))) — too long to edit here.")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            }
            TextEditor(text: $model.text)
                .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                .scrollContentBackground(.hidden)
                .disabled(model.readOnly || model.textTooLong)
                .accessibilityIdentifier("redisValue")
            HStack(spacing: 8) {
                if model.type == "string", RedisKeyModel.pretty(model.text) != model.text {
                    Button("Format JSON") { model.text = RedisKeyModel.pretty(model.text) }.controlSize(.small)
                        .help("Lays the JSON out — saving then writes it so")
                }
                Spacer()
                if model.text != model.savedText {
                    Button("Revert") { model.text = model.savedText }.controlSize(.small)
                }
                Button("Save") { Task { await model.saveText() } }
                    .controlSize(.small).keyboardShortcut("s", modifiers: .command)
                    .disabled(model.readOnly || model.textTooLong || model.text == model.savedText)
                    .accessibilityIdentifier("redisSave")
            }
        }
        .padding(12)
    }

    // MARK: A hash, a list, a set, a sorted set, a stream

    private var filterable: Bool { ["hash", "set", "zset"].contains(model.type) }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if filterable {
                    Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                    TextField(model.type == "hash" ? "Filter fields" : "Filter members", text: $model.filter)
                        .textFieldStyle(.plain).font(.system(size: ChromeMetrics.text(12)))
                        .onSubmit { Task { await model.applyFilter() } }
                } else {
                    Text(verbatim: model.type == "stream" ? "Newest first" : "In order").font(.system(size: ChromeMetrics.text(11)))
                        .foregroundStyle(theme.dimText)
                    Spacer()
                }
                if !model.readOnly {
                    Button {
                        adding.toggle()
                        newValues = ["", ""]
                        selected = nil
                    } label: {
                        Label(addLabel, systemImage: "plus")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("redisAdd")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if adding { addForm }
            columnsHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    if model.hasMore {
                        Button("Load more") { Task { await model.more() } }
                            .buttonStyle(.plain).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.accentText)
                            .padding(12)
                    } else if model.rows.isEmpty {
                        Text(model.filter.isEmpty ? "Empty" : "Nothing matches").font(.system(size: ChromeMetrics.text(11.5)))
                            .foregroundStyle(theme.dimText).padding(12)
                    }
                }
            }
            if let selected { rowEditor(selected) }
            if model.type == "stream", !model.groups.isEmpty { groupsView }
        }
    }

    private var addLabel: String {
        switch model.type {
        case "hash": "Field"
        case "list": "Element"
        case "stream": "Entry"
        default: "Member"
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.type {
            case "hash":
                chrome.field("Field", $newValues[0])
                chrome.editor($newValues[1], minHeight: 50)
            case "zset":
                chrome.field("Member", $newValues[0])
                chrome.field("Score", $newValues[1])
            case "stream":
                Text("Fields, one `field value` a line").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                chrome.editor($newValues[0], minHeight: 50)
            case "list":
                chrome.editor($newValues[0], minHeight: 50)
                Picker("", selection: $addAtHead) {
                    Text("To the tail").tag(false)
                    Text("To the head").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            default:
                chrome.field("Member", $newValues[0])
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }.controlSize(.small)
                Button("Add") { add() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func add() {
        let values: [String]
        switch model.type {
        case "hash", "zset": values = [newValues[0], newValues[1]]
        case "stream":
            values = newValues[0].split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.count == 2 ? [String(parts[0]), String(parts[1])] : []
            }
            guard !values.isEmpty else {
                model.error = "An entry needs a `field value` line."
                return
            }
        default: values = [newValues[0]]
        }
        Task {
            await model.add(values, atHead: addAtHead)
            if model.error == nil { adding = false }
        }
    }

    private var columnsHeader: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                Text(verbatim: column).frame(width: index == 0 && model.columns.count > 1 ? firstWidth : nil, alignment: .leading)
                if index == 0, model.columns.count > 1 { Divider().frame(height: 12) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.dimText)
        .padding(.horizontal, 12).frame(height: ChromeMetrics.row(22))
        .background(theme.rowHover.opacity(0.4))
    }

    private var firstWidth: CGFloat {
        switch model.type {
        case "list": 56
        case "stream": 150
        default: 160
        }
    }

    private func rowView(_ row: RedisKeyModel.Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                Text(verbatim: cell.count > 300 ? String(cell.prefix(300)) + "…" : cell)
                    .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                    .foregroundStyle(index == 0 && row.cells.count > 1 ? theme.text2 : theme.text)
                    .lineLimit(3)
                    .frame(width: index == 0 && row.cells.count > 1 ? firstWidth : nil, alignment: .leading)
                    .frame(maxWidth: index == row.cells.count - 1 ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(selected == row ? theme.selected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = row
            adding = false
            editValue = model.type == "set" ? row.cells[0] : row.cells.last ?? ""
        }
        .contextMenu {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                Button("Copy \(model.columns[safe: index] ?? "Value")") { chrome.copy(cell) }
            }
            if !model.readOnly {
                Divider()
                Button("Delete") { remove(row) }
            }
        }
        .accessibilityIdentifier("redisRow-\(row.id)")
    }

    /// The row picked: its value, edited — a stream's entries are never
    /// changed, only added and deleted, as Redis has them.
    private func rowEditor(_ row: RedisKeyModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.3)
            HStack {
                Text(verbatim: editTitle(row)).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(10)))
                }
                .buttonStyle(.plain).foregroundStyle(theme.dimText)
            }
            if model.type == "zset" {
                chrome.field("Score", $editValue)
            } else {
                chrome.editor($editValue, minHeight: 70)
                    .disabled(model.type == "stream" || model.readOnly)
            }
            HStack {
                Button("Copy") { chrome.copy(editValue) }.controlSize(.small)
                if model.type == "string" || RedisKeyModel.pretty(editValue) != editValue {
                    Button("Format JSON") { editValue = RedisKeyModel.pretty(editValue) }.controlSize(.small)
                }
                Spacer()
                if !model.readOnly {
                    Button("Delete") { remove(row) }.controlSize(.small)
                    if model.type != "stream" {
                        Button("Save") {
                            Task {
                                await model.update(row, to: editValue)
                                if model.error == nil { selected = nil }
                            }
                        }
                        .controlSize(.small).keyboardShortcut("s", modifiers: .command)
                        .disabled(editValue == (model.type == "set" ? row.cells[0] : row.cells.last ?? ""))
                        .accessibilityIdentifier("redisRowSave")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxHeight: 260)
    }

    private func editTitle(_ row: RedisKeyModel.Row) -> String {
        switch model.type {
        case "hash": "Field “\(row.cells[0])”"
        case "list": "Element \(row.cells[0])"
        case "zset": "Score of “\(row.cells[0])”"
        case "stream": "Entry \(row.cells[0])"
        default: "Member"
        }
    }

    private func remove(_ row: RedisKeyModel.Row) {
        let what = model.type == "stream" ? "entry \(row.cells[0])" : "“\(row.cells[0])”"
        actions.confirm("Delete \(what)?", "From \(model.name). This can't be undone.", "Delete") {
            Task {
                await model.remove(row)
                if selected == row { selected = nil }
            }
        }
    }

    private var groupsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.3)
            Text("Consumer groups").font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
            ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 10) {
                    Text(verbatim: group["name"] ?? "").foregroundStyle(theme.text)
                    Text(verbatim: "\(group["consumers"] ?? "0") consumers")
                    Text(verbatim: "\(group["pending"] ?? "0") pending")
                    Text(verbatim: "last \(group["last-delivered-id"] ?? "")")
                    if let lag = group["lag"], !lag.isEmpty { Text(verbatim: "lag \(lag)") }
                }
                .font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.dimText)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

// MARK: A new key

struct RedisNewKeyView: View {
    @ObservedObject var model: RedisSlotModel
    @ObservedObject var theme: ChromeTheme
    let actions: RedisSlotActions
    @State private var name = ""
    @State private var type = "string"
    @State private var ttl = ""
    @State private var first = ""
    @State private var second = ""
    @State private var error: String?
    @State private var creating = false

    private var chrome: RedisChrome { RedisChrome(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome.header("New Key in db\(model.newKeyDB)", close: actions.close) {
                Image(systemName: "plus.square").foregroundStyle(theme.dimText)
            }
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    label("Type")
                    Picker("", selection: $type) {
                        ForEach(RedisKeyType.creatable, id: \.self) { type in Text(RedisKeyType.label(type)).tag(type) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    label("Name")
                    chrome.field("user:1", $name).accessibilityIdentifier("redisNewName")
                    label("TTL")
                    chrome.field("Seconds — empty: no expiry", $ttl)
                    label(valueLabel)
                    values
                    chrome.error(error)
                    HStack {
                        Spacer()
                        Button("Cancel", action: actions.close)
                        Button("Add Key") { create() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || creating)
                            .accessibilityIdentifier("redisCreate")
                    }
                }
                .padding(12)
            }
        }
        .onChange(of: type) { type in
            if type == "ReJSON-RL", first.isEmpty { first = "{}" }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
    }

    private var valueLabel: String {
        switch type {
        case "hash": "First field"
        case "list": "First element"
        case "set": "First member"
        case "zset": "First member and its score"
        case "stream": "First entry: `field value` a line"
        case "ReJSON-RL": "Document"
        default: "Value"
        }
    }

    @ViewBuilder private var values: some View {
        switch type {
        case "hash":
            chrome.field("Field", $first)
            chrome.editor($second, minHeight: 60)
        case "zset":
            chrome.field("Member", $first)
            chrome.field("Score", $second)
        case "set":
            chrome.field("Member", $first)
        default:
            chrome.editor($first, minHeight: 120).accessibilityIdentifier("redisNewValue")
        }
    }

    private func create() {
        guard let session = model.newKeySession, let driver = session.redis else {
            error = "Not connected."
            return
        }
        let values: [String]
        switch type {
        case "hash", "zset": values = [first, second]
        case "stream":
            values = first.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.count == 2 ? [String(parts[0]), String(parts[1])] : []
            }
        default: values = [first]
        }
        let db = model.newKeyDB
        let name = name
        let type = type
        creating = true
        Task {
            defer { creating = false }
            do {
                try await RedisKeyModel.create(name, type: type, values: values, ttl: Int(ttl), db: db, driver: driver)
                session.browser(db).added(RedisKeyEntry(name: name, type: type))
                self.name = ""
                first = ""
                second = ""
                ttl = ""
                error = nil
                actions.openKey(session, db, name)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: The server

struct RedisServerView: View {
    @ObservedObject var model: RedisServerModel
    @ObservedObject var theme: ChromeTheme
    let actions: RedisSlotActions
    @State private var channel = ""
    @State private var message = ""
    @State private var published: String?

    private var chrome: RedisChrome { RedisChrome(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome.header(model.name, close: actions.close) {
                Image(systemName: "server.rack").foregroundStyle(theme.dimText)
            }
            Picker("", selection: $model.tab) {
                ForEach(RedisServerModel.Tab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider().opacity(0.3)
            if let error = model.error {
                chrome.error(error).padding(.horizontal, 12).padding(.top, 8)
            }
            switch model.tab {
            case .overview: overview
            case .slowlog: slowlog
            case .clients: clients
            case .pubsub: pubsub
            case .profiler: profiler
            }
        }
    }

    // MARK: Overview

    private var overview: some View {
        let info = model.info
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    stat("Version", info.version ?? "—", info["redis_mode"].map { "\($0) · \(info["role"] ?? "")" })
                    stat("Uptime", info.uptime ?? "—", nil)
                    stat("Memory", info["used_memory_human"] ?? "—", info["used_memory_peak_human"].map { "peak \($0)" })
                    stat("Max memory", (info["maxmemory_human"].flatMap { $0 == "0B" ? nil : $0 }) ?? "none", info["maxmemory_policy"])
                    stat("Clients", info["connected_clients"] ?? "—", info["blocked_clients"].map { "\($0) blocked" })
                    stat("Ops / s", info["instantaneous_ops_per_sec"] ?? "—", info["total_commands_processed"].map { "\($0) total" })
                    stat("Hit ratio", info.hitRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "—", info["keyspace_misses"].map { "\($0) misses" })
                    stat("Keys", String(info.totalKeys), info["expired_keys"].map { "\($0) expired · \(info["evicted_keys"] ?? "0") evicted" })
                    stat(
                        "Network", "\(info["instantaneous_input_kbps"] ?? "0") / \(info["instantaneous_output_kbps"] ?? "0")",
                        "KB/s in / out")
                    stat(
                        "Persistence", info["aof_enabled"] == "1" ? "AOF" : (info["rdb_last_bgsave_status"].map { "RDB \($0)" } ?? "—"),
                        info["rdb_changes_since_last_save"].map { "\($0) changes unsaved" })
                }
                if !info.keyspace.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyspace").font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
                        ForEach(info.keyspace, id: \.db) { entry in
                            HStack {
                                Text(verbatim: "db\(entry.db)").frame(width: 50, alignment: .leading)
                                Text(verbatim: "\(entry.keys) keys").frame(width: 110, alignment: .leading)
                                Text(verbatim: "\(entry.expires) with a TTL")
                                Spacer()
                            }
                            .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                        }
                    }
                }
                DisclosureGroup("Everything INFO says") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(info.fields.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(verbatim: key).foregroundStyle(theme.dimText).frame(width: 220, alignment: .leading)
                                Text(verbatim: info.fields[key] ?? "").foregroundStyle(theme.text).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: ChromeMetrics.text(11.5)))
                if let updated = model.updated {
                    Text("Read \(updated, format: .dateTime.hour().minute().second()) — again every 5 s while this shows")
                        .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
                }
            }
            .padding(12)
        }
    }

    private func stat(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
            Text(verbatim: value).font(.system(size: ChromeMetrics.text(15), weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            // A line even without one: the cards stay one height.
            Text(verbatim: detail ?? " ").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.rowHover.opacity(0.6)))
    }

    // MARK: Slow log

    private var slowlog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "\(model.slowlog.count) commands slower than \(slowerThan)").font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.dimText)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.controlSize(.small)
                if model.session?.connection.readOnly == false {
                    Button("Reset") {
                        actions.confirm("Clear the slow log?", "Every entry on \(model.name) goes.", "Clear") { Task { await model.resetSlowlog() } }
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.slowlog) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.command).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                                .lineLimit(2).textSelection(.enabled)
                            HStack(spacing: 10) {
                                Text(verbatim: String(format: "%.2f ms", Double(entry.micros) / 1000)).foregroundStyle(theme.orangeText)
                                Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                Text(verbatim: entry.client)
                            }
                            .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .contextMenu { Button("Copy Command") { chrome.copy(entry.command) } }
                    }
                }
            }
        }
    }

    private var slowerThan: String {
        guard let micros = model.slowerThan else { return "the threshold" }
        return String(format: "%.0f ms", Double(micros) / 1000)
    }

    // MARK: Clients

    private var clients: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.clients.enumerated()), id: \.offset) { _, client in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(verbatim: client["addr"] ?? "").foregroundStyle(theme.text)
                            if let name = client["name"], !name.isEmpty { Text(verbatim: name).foregroundStyle(theme.accentText) }
                            Spacer()
                            Text(verbatim: "db\(client["db"] ?? "0")")
                        }
                        HStack(spacing: 10) {
                            Text(verbatim: "age \(RedisKeyInfo.duration(Int(client["age"] ?? "0") ?? 0))")
                            Text(verbatim: "idle \(RedisKeyInfo.duration(Int(client["idle"] ?? "0") ?? 0))")
                            Text(verbatim: client["cmd"] ?? "")
                            if let lib = client["lib-name"], !lib.isEmpty { Text(verbatim: lib) }
                        }
                        .foregroundStyle(theme.dimText)
                    }
                    .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contextMenu {
                        Button("Copy Address") { chrome.copy(client["addr"] ?? "") }
                        if model.session?.connection.readOnly == false, let id = client["id"] {
                            Divider()
                            Button("Kill Client…") {
                                actions.confirm("Disconnect \(client["addr"] ?? "this client")?", "CLIENT KILL closes its connection.", "Kill") {
                                    Task { await model.kill(client: id) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Pub/Sub

    private var pubsub: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chrome.field("Channels or patterns: news.* orders", $model.channels)
                    .onSubmit { Task { await model.subscribe() } }
                if model.subscribed != nil {
                    Button("Unsubscribe") { model.stopSubscriber() }.controlSize(.small)
                } else {
                    Button("Subscribe") { Task { await model.subscribe() } }.controlSize(.small)
                        .accessibilityIdentifier("redisSubscribe")
                }
            }
            if let subscribed = model.subscribed {
                Text(verbatim: "Listening to \(subscribed) on a connection of its own").font(.system(size: ChromeMetrics.text(10.5)))
                    .foregroundStyle(TabStatusStyle.done)
            }
            HStack(spacing: 6) {
                chrome.field("Channel", $channel).frame(maxWidth: 140)
                chrome.field("Message", $message).onSubmit { publish() }
                Button("Publish") { publish() }.controlSize(.small).disabled(channel.isEmpty)
            }
            if let published { Text(verbatim: published).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText) }
            HStack {
                Text(verbatim: "\(model.messages.count) messages").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
                Spacer()
                Button("Clear") { model.clearMessages() }.controlSize(.small).disabled(model.messages.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.messages) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Text(message.date, format: .dateTime.hour().minute().second()).foregroundStyle(theme.dimText)
                            Text(verbatim: message.channel).foregroundStyle(theme.accentText)
                            Text(verbatim: message.text).foregroundStyle(theme.text).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(12)
    }

    private func publish() {
        guard !channel.isEmpty else { return }
        let channel = channel
        Task {
            if let n = await model.publish(channel, message) {
                published = n == 1 ? "Received by 1 subscriber" : "Received by \(n) subscribers"
                message = ""
            }
        }
    }

    // MARK: Profiler

    private var profiler: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.monitoring {
                    Button("Stop") { model.stopMonitor() }.controlSize(.small)
                    ProgressView().controlSize(.mini)
                    Text("Every command the server runs").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                } else {
                    Button("Start Profiler") { Task { await model.startMonitor() } }.controlSize(.small)
                        .accessibilityIdentifier("redisMonitor")
                    Text("MONITOR slows a busy server — it stops after \(RedisServerModel.keep) commands.")
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                }
                Spacer()
                Button("Clear") { model.clearCommands() }.controlSize(.small).disabled(model.commands.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.commands) { command in
                        HStack(alignment: .top, spacing: 8) {
                            Text(command.date, format: .dateTime.hour().minute().second()).foregroundStyle(theme.dimText)
                            Text(verbatim: command.text).foregroundStyle(theme.text).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(12)
    }
}
