import AppKit
import SwiftUI

/// The API panel's MCP servers: the checkout's and the agents' as they
/// configure them, and the ones added here — a click inspects one.
struct MCPServersSection: View {
    @ObservedObject var inspector: MCPInspector
    @ObservedObject var theme: ChromeTheme
    let open: (MCPServerConfig) -> Void
    @State private var collapsed = false
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.border).frame(height: 1)
            HStack(spacing: 6) {
                Button {
                    collapsed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(8), weight: .semibold))
                        Text("MCP SERVERS").font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                        Text(verbatim: "\(inspector.servers.count)").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                    }
                    .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus").font(.system(size: ChromeMetrics.text(10.5)))
                }
                .buttonStyle(.plain).foregroundStyle(theme.text2)
                .help("Add an MCP server — a command, or a URL")
                .accessibilityIdentifier("mcpAdd")
            }
            .padding(.horizontal, 10).frame(height: ChromeMetrics.row(26))
            if !collapsed {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if inspector.servers.isEmpty {
                            Text("None configured — .mcp.json and the agents' own servers (Claude Code, Codex, opencode, Gemini CLI) show here; + adds one.")
                                .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 4)
                        }
                        ForEach(inspector.servers) { server in row(server) }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .sheet(isPresented: $adding) {
            MCPAddServerSheet(theme: theme) { server in
                try inspector.add(server)
                adding = false
                open(server)
            } cancel: {
                adding = false
            }
        }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        let state = inspector.states[server.id] ?? .idle
        let picked = inspector.selected?.id == server.id
        return HStack(spacing: 6) {
            Circle().fill(Self.color(state, theme: theme)).frame(width: 6, height: 6)
            Image(systemName: server.transport.kind == "stdio" ? "terminal" : "network").font(.system(size: ChromeMetrics.text(10)))
                .foregroundStyle(theme.text3)
            Text(verbatim: server.name).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1)
            Text(verbatim: server.source.title).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: ChromeMetrics.row(24))
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? theme.selected : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { open(server) }
        .help(server.transport.summary)
        .contextMenu {
            Button("Inspect") { open(server) }
            if case .connected = state {
                Button("Disconnect") { inspector.disconnect(server) }
            } else {
                Button("Connect") { inspector.connect(server) }
            }
            Button("Copy Command or URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.transport.summary, forType: .string)
            }
            if server.source == .overterm {
                Divider()
                Button("Remove") { try? inspector.remove(server) }
            }
        }
        .accessibilityIdentifier("mcpServer-\(server.name)")
    }

    static func color(_ state: MCPInspector.State, theme: ChromeTheme) -> Color {
        switch state {
        case .idle: theme.border
        case .connecting: theme.orangeText
        case .connected: TabStatusStyle.done
        case .failed: DiffColors.removed
        }
    }
}

/// Add an MCP server: a command run on this Mac, or a URL — its env's or
/// headers' values going to the keychain.
struct MCPAddServerSheet: View {
    @ObservedObject var theme: ChromeTheme
    let add: (MCPServerConfig) throws -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var kind = "stdio"
    @State private var command = ""
    @State private var url = ""
    @State private var pairs = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP Server").font(.system(size: ChromeMetrics.text(15), weight: .semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Transport", selection: $kind) {
                    Text("Command (stdio)").tag("stdio")
                    Text("HTTP (Streamable)").tag("http")
                    Text("SSE (2024)").tag("sse")
                }
                if kind == "stdio" {
                    TextField("Command", text: $command, prompt: Text(verbatim: "npx -y @modelcontextprotocol/server-everything"))
                } else {
                    TextField("URL", text: $url, prompt: Text(verbatim: "https://example.com/mcp"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == "stdio" ? "Environment — NAME=value a line" : "Headers — Name: value a line")
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(.secondary)
                    TextEditor(text: $pairs).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).frame(height: 70)
                    Text("Their values are kept in your keychain.").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let problem { Text(verbatim: problem).foregroundStyle(.red).font(.system(size: ChromeMetrics.text(12))) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (kind == "stdio" ? command.isEmpty : url.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        let separator: Character = kind == "stdio" ? "=" : ":"
        var values: [String: String] = [:]
        for line in pairs.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: separator, maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let transport: MCPServerConfig.Transport
        switch kind {
        case "stdio":
            let words = (try? RedisProtocol.words(command)) ?? command.split(separator: " ").map(String.init)
            guard let first = words.first else { return problem = "A command, please." }
            transport = .stdio(command: first, args: Array(words.dropFirst()), env: values)
        case "sse": transport = .sse(url: url.trimmingCharacters(in: .whitespaces), headers: values)
        default: transport = .http(url: url.trimmingCharacters(in: .whitespaces), headers: values)
        }
        do {
            try add(MCPServerConfig(name: name.trimmingCharacters(in: .whitespaces), source: .overterm, transport: transport))
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One MCP server, inspected in the right-hand pane: what it says it is,
/// its tools (called with JSON arguments), resources (read), prompts (got)
/// and every message both ways.
struct MCPPageView: View {
    @ObservedObject var inspector: MCPInspector
    @ObservedObject var theme: ChromeTheme
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server = inspector.selected {
                header(server)
                Divider().opacity(0.3)
                switch inspector.state {
                case .connected:
                    Picker("", selection: $inspector.tab) {
                        ForEach(MCPInspector.Tab.allCases) { tab in Text(verbatim: title(tab)).tag(tab) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(10)
                    .accessibilityIdentifier("mcpTabs")
                    if let error = inspector.error {
                        Text(verbatim: error).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(DiffColors.removed).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    switch inspector.tab {
                    case .tools: tools
                    case .resources: resources
                    case .prompts: prompts
                    case .log: log
                    }
                case .connecting: note("Connecting to \(server.name)…")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: message).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(DiffColors.removed).textSelection(.enabled)
                        Button("Try Again") { inspector.connect(server) }.controlSize(.small)
                        log
                    }
                    .padding(12)
                case .idle:
                    VStack {
                        Button("Connect") { inspector.connect(server) }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity).padding(16)
                }
            } else {
                note("Pick an MCP server in the API panel (⌥⌘R).")
            }
        }
        .background(theme.panelGround)
    }

    private func title(_ tab: MCPInspector.Tab) -> String {
        switch tab {
        case .tools: "Tools \(inspector.tools.count)"
        case .resources: "Resources \(inspector.resources.count)"
        case .prompts: "Prompts \(inspector.prompts.count)"
        case .log: "Log"
        }
    }

    private func header(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(MCPServersSection.color(inspector.state, theme: theme)).frame(width: 7, height: 7)
                Text(verbatim: server.name).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text)
                if let name = inspector.serverInfo["name"].string {
                    Text(verbatim: "\(name) \(inspector.serverInfo["version"].string ?? "")").font(.system(size: ChromeMetrics.text(11)))
                        .foregroundStyle(theme.text3)
                }
                Spacer()
                if case .connected = inspector.state {
                    Button("Reconnect") { inspector.connect(server) }.controlSize(.small)
                }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11))) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimText).help("Close")
            }
            Text(verbatim: "\(server.transport.kind) · \(server.transport.summary) · \(server.source.title)")
                .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3).lineLimit(2).textSelection(.enabled)
            if let instructions = inspector.instructions, !instructions.isEmpty {
                DisclosureGroup("Instructions") {
                    Text(verbatim: instructions).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: ChromeMetrics.text(11)))
            }
        }
        .padding(12)
    }

    private func note(_ text: String) -> some View {
        VStack {
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(16)
    }

    // MARK: Tools

    private var tools: some View {
        VSplitView {
            list(inspector.tools.map { ($0.id, $0.title ?? $0.name, $0.description, $0.destructive == true ? "destructive" : $0.readOnly == true ? "read-only" : nil) }, picked: inspector.pickedTool) {
                id in
                if let tool = inspector.tools.first(where: { $0.id == id }) { inspector.pick(tool: tool) }
            }
            .frame(minHeight: 80, idealHeight: 150, maxHeight: 240)
            if let tool = inspector.tools.first(where: { $0.name == inspector.pickedTool }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: tool.name).font(.system(size: ChromeMetrics.text(12), weight: .semibold, design: .monospaced))
                    if !tool.description.isEmpty {
                        Text(verbatim: tool.description).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2).lineLimit(4)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text("Arguments").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.text3)
                        Spacer()
                        DisclosureGroup("Schema") {
                            ScrollView { Text(verbatim: tool.inputSchema.pretty).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).textSelection(.enabled) }
                                .frame(maxHeight: 120)
                        }
                        .font(.system(size: ChromeMetrics.text(10.5)))
                    }
                    APICodeView(text: $inspector.toolArguments, language: "json", accessibilityIdentifier: "mcpArguments").frame(minHeight: 70)
                    HStack {
                        if inspector.running { ProgressView().controlSize(.mini) }
                        Spacer()
                        Button("Call Tool") { inspector.call() }.keyboardShortcut(.return, modifiers: .command).disabled(inspector.running)
                            .accessibilityIdentifier("mcpCall")
                    }
                    outcome
                }
                .padding(10)
                .frame(minHeight: 280, maxHeight: .infinity)
            }
        }
    }

    // MARK: Resources

    private var resources: some View {
        VSplitView {
            list(inspector.resources.map { ($0.id, $0.name.isEmpty ? $0.uri : $0.name, $0.isTemplate ? "template · \($0.uri)" : $0.uri, $0.mimeType) }, picked: inspector.pickedResource) { id in
                if let resource = inspector.resources.first(where: { $0.id == id }) { inspector.pick(resource: resource) }
            }
            .frame(minHeight: 80, idealHeight: 150, maxHeight: 240)
            if inspector.pickedResource != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("URI", text: $inspector.resourceURI).textFieldStyle(.roundedBorder).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                        Button("Read") { inspector.read() }.disabled(inspector.running)
                    }
                    outcome
                }
                .padding(10)
                .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
    }

    // MARK: Prompts

    private var prompts: some View {
        VSplitView {
            list(inspector.prompts.map { ($0.id, $0.name, $0.description, $0.arguments.isEmpty ? nil : "\($0.arguments.count) arguments") }, picked: inspector.pickedPrompt) { id in
                if let prompt = inspector.prompts.first(where: { $0.id == id }) { inspector.pick(prompt: prompt) }
            }
            .frame(minHeight: 80, idealHeight: 150, maxHeight: 240)
            if let prompt = inspector.prompts.first(where: { $0.name == inspector.pickedPrompt }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompt.arguments, id: \.name) { argument in
                        TextField(
                            argument.name + (argument.required ? " *" : ""),
                            text: Binding(get: { inspector.promptArguments[argument.name] ?? "" }, set: { inspector.promptArguments[argument.name] = $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .help(argument.description)
                    }
                    HStack {
                        Spacer()
                        Button("Get Prompt") { inspector.getPrompt() }.disabled(inspector.running)
                    }
                    outcome
                }
                .padding(10)
                .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
    }

    // MARK: Pieces

    private func list(_ items: [(id: String, title: String, detail: String, badge: String?)], picked: String?, pick: @escaping (String) -> Void) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("This server has none.").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).padding(12)
                }
                ForEach(items, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: item.title).font(.system(size: ChromeMetrics.text(12), weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.text).lineLimit(1)
                            if let badge = item.badge {
                                Text(verbatim: badge).font(.system(size: ChromeMetrics.text(9.5), weight: .semibold))
                                    .foregroundStyle(badge == "destructive" ? DiffColors.removed : theme.text3)
                                    .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(theme.rowHover))
                            }
                        }
                        if !item.detail.isEmpty {
                            Text(verbatim: item.detail).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(picked == item.id ? theme.selected : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(item.id) }
                    .accessibilityIdentifier("mcpItem-\(item.id)")
                }
            }
        }
    }

    /// What came back: its text content as text, an image as an image,
    /// the rest (structured content, resources) as JSON.
    @ViewBuilder private var outcome: some View {
        if let outcome = inspector.outcome {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: outcome.isError ? "Error" : "Result").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold))
                        .foregroundStyle(outcome.isError ? DiffColors.removed : TabStatusStyle.done)
                    Text(verbatim: SQLConsoleView.duration(outcome.duration)).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                    Spacer()
                    Button("Copy JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(outcome.value.pretty, forType: .string)
                    }
                    .controlSize(.small)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(MCPContent.parts(outcome.value).enumerated()), id: \.offset) { _, part in
                            switch part {
                            case .text(let text):
                                Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            case .image(let data):
                                if let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 240)
                                }
                            case .json(let value):
                                Text(verbatim: value.pretty).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text2)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("mcpOutcome")
            }
        }
    }

    // MARK: Log

    private var log: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "\(inspector.log.count) messages").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                Spacer()
                Button("Clear") { inspector.clearLog() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(inspector.log.reversed()) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(verbatim: symbol(line.direction)).foregroundStyle(line.direction == .stderr ? theme.orangeText : theme.accentText)
                            Text(verbatim: line.text.count > 2000 ? String(line.text.prefix(2000)) + "…" : line.text).foregroundStyle(theme.text2)
                                .textSelection(.enabled).lineLimit(6)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func symbol(_ direction: MCPClient.Direction) -> String {
        switch direction {
        case .sent: "→"
        case .received: "←"
        case .stderr: "!"
        case .note: "·"
        }
    }
}

/// A result's `content`, as the inspector shows it.
enum MCPContent {
    enum Part: Equatable {
        case text(String)
        case image(Data)
        case json(JSONValue)
    }

    static func parts(_ result: JSONValue) -> [Part] {
        var out: [Part] = []
        // A tool's content, a resource's contents, a prompt's messages.
        let items = result["content"].array ?? result["contents"].array ?? []
        for item in items {
            switch item["type"].string {
            case "text": out.append(.text(item["text"].string ?? ""))
            case "image": out.append(Data(base64Encoded: item["data"].string ?? "").map(Part.image) ?? .json(item))
            default:
                if let text = item["text"].string { out.append(.text(text)) } else { out.append(.json(item)) }
            }
        }
        for message in result["messages"].array ?? [] {
            let role = message["role"].string ?? ""
            let text = message["content"]["text"].string ?? message["content"].pretty
            out.append(.text("\(role): \(text)"))
        }
        if result["structuredContent"] != .null { out.append(.json(result["structuredContent"])) }
        if out.isEmpty { out.append(.json(result)) }
        return out
    }
}
