import AppKit
import SwiftUI

/// A Bruno gRPC request in the editor: its server and method on top (the
/// methods as reflection or the collection's .proto files say), its
/// messages as JSON, its metadata, auth and docs — and what came back: the
/// status, every message (a stream's as they arrive), headers and trailers.
package struct GRPCRequestView: View {
    @ObservedObject package var model: APIRequestModel
    @ObservedObject package var workspace: APIWorkspace
    @ObservedObject package var theme: ChromeTheme
    @State private var tab = "messages"
    @State private var responseTab = "messages"

    private var schema: GRPCSchemaState? { workspace.grpcSchema(model.file, at: model.url) }
    private var registry: Protobuf.Registry? { if case .loaded(let registry)? = schema { registry } else { nil } }
    private var result: GRPCResult? { workspace.grpcResult(for: model.url) }
    private var method: Protobuf.Method? { registry?.method(path: model.file.grpcMethod)?.1 }
    private var streamsIn: Bool { method?.clientStreaming ?? (model.file.grpcMethodType == "client-streaming" || model.file.grpcMethodType == "bidi-streaming") }

    package var body: some View {
        VStack(spacing: 0) {
            addressBar
            Rectangle().fill(theme.border).frame(height: 1)
            VSplitView {
                requestPane.frame(minWidth: 0, maxWidth: .infinity, minHeight: 140, idealHeight: 260)
                responsePane.frame(minWidth: 0, maxWidth: .infinity, minHeight: 160)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(theme.term)
        .onAppear { workspace.loadGRPCSchema(model.file, at: model.url) }
    }

    // MARK: Address, method, Invoke

    private var addressBar: some View {
        HStack(spacing: 8) {
            Text("gRPC").font(.system(size: ChromeMetrics.text(11), weight: .bold, design: .monospaced)).foregroundStyle(APIMethodStyle.color("GRPC"))
            TextField(
                "grpc://localhost:50051", text: Binding(get: { model.file.grpcURL }, set: { value in model.update { $0.grpcURL = value } })
            )
            .textFieldStyle(.plain)
            .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
            .foregroundStyle(theme.text)
            .onSubmit { workspace.loadGRPCSchema(model.file, at: model.url, force: true) }
            .accessibilityIdentifier("grpcURL")
            methodMenu
            Button {
                if result?.running == true { workspace.cancelGRPC(model.url) } else { workspace.sendGRPC(model.file, at: model.url) }
            } label: {
                HStack(spacing: 4) {
                    if result?.running == true { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(result?.running == true ? "Cancel" : "Invoke").font(.system(size: ChromeMetrics.text(12), weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: ChromeMetrics.row(24))
                .background(RoundedRectangle(cornerRadius: 6).fill(result?.running == true ? theme.rowHover : theme.accentText.opacity(0.22)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Call the method — ⌘↩")
            .accessibilityIdentifier("grpcInvoke")
            Menu {
                Button("Read the Methods Again") { workspace.loadGRPCSchema(model.file, at: model.url, force: true) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: ChromeMetrics.text(12)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeMetrics.row(40))
    }

    private var methodMenu: some View {
        Menu {
            switch schema {
            case .loaded(let registry):
                ForEach(registry.services, id: \.fullName) { service in
                    Section(service.fullName) {
                        ForEach(service.methods, id: \.name) { method in
                            Button("\(method.name)  ·  \(method.kind)") { pick("/\(service.fullName)/\(method.name)", method, registry) }
                        }
                    }
                }
                if registry.services.isEmpty { Text("No services") }
            case .loading: Text("Reading the methods…")
            case .failed(let message): Text(verbatim: message)
            case nil: Text("Type the server's address first")
            }
            Divider()
            Button("Read the Methods Again") { workspace.loadGRPCSchema(model.file, at: model.url, force: true) }
        } label: {
            HStack(spacing: 4) {
                if case .loading = schema { ProgressView().controlSize(.mini) }
                if case .failed = schema { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DiffColors.removed) }
                Text(verbatim: model.file.grpcMethod.isEmpty ? "Method" : String(model.file.grpcMethod.split(separator: "/").last ?? ""))
                    .font(.system(size: ChromeMetrics.text(12), weight: .medium, design: .monospaced)).lineLimit(1)
                Text(verbatim: model.file.grpcMethodType).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.file.grpcMethod.isEmpty ? "The methods, from the server's reflection or the collection's .proto files" : model.file.grpcMethod)
        .accessibilityIdentifier("grpcMethod")
    }

    /// The method picked: its kind written, and an empty message a start.
    private func pick(_ path: String, _ method: Protobuf.Method, _ registry: Protobuf.Registry) {
        model.update { file in
            file.grpcMethod = path
            file.grpcMethodType = method.kind
            let empty = file.grpcMessages.allSatisfy { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" || $0.content.isEmpty }
            if empty {
                file.grpcMessages = [.init(name: "message 1", content: Protobuf.skeleton(method.input, registry: registry).pretty)]
            }
        }
    }

    // MARK: The request's tabs

    private var requestPane: some View {
        VStack(spacing: 0) {
            APITabBar(
                tabs: [
                    ("messages", streamsIn ? "Messages" : "Message", model.file.grpcMessages.count > 1 ? model.file.grpcMessages.count : 0),
                    ("metadata", "Metadata", model.file.metadata.filter(\.enabled).count), ("auth", "Auth", 0),
                    ("docs", "Docs", model.file.docs?.isEmpty == false ? 1 : 0),
                ],
                selection: $tab, theme: theme)
            Group {
                switch tab {
                case "metadata":
                    APIPairsEditor(
                        pairs: Binding(get: { model.file.metadata }, set: { value in model.update { $0.metadata = value } }), keyPlaceholder: "Key",
                        valuePlaceholder: "Value", addTitle: "Add Metadata", theme: theme)
                case "auth": APIAuthEditor(model: model, theme: theme)
                case "docs":
                    APIDocsView(text: Binding(get: { model.file.docs ?? "" }, set: { value in model.update { $0.docs = value } }), theme: theme)
                default: messages
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var messages: some View {
        let list = model.file.grpcMessages
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let method, let registry {
                    Text(verbatim: String(method.input.dropFirst())).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3)
                    Button("Example") {
                        let skeleton = Protobuf.skeleton(method.input, registry: registry).pretty
                        model.update { $0.grpcMessages = [.init(name: list.first?.name ?? "message 1", content: skeleton)] + Array(list.dropFirst()) }
                    }
                    .controlSize(.small)
                    .help("Every field of \(method.input.dropFirst()), empty, to fill in")
                }
                Spacer()
                if streamsIn {
                    Button {
                        model.update { $0.grpcMessages = list + [.init(name: "message \(list.count + 1)", content: list.last?.content ?? "{}")] }
                    } label: {
                        Label("Add Message", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .help("A client stream sends them in order, then ends")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if streamsIn && list.count > 1 {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(list.enumerated()), id: \.offset) { index, _ in messageEditor(index, removable: true).frame(height: 110) }
                    }
                    .padding(.horizontal, 10)
                }
            } else {
                messageEditor(0, removable: false)
            }
        }
    }

    private func messageEditor(_ index: Int, removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if removable {
                HStack {
                    Text(verbatim: model.file.grpcMessages[safe: index]?.name ?? "").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold))
                        .foregroundStyle(theme.text3)
                    Spacer()
                    Button {
                        model.update { file in
                            var all = file.grpcMessages
                            if all.indices.contains(index) { all.remove(at: index) }
                            file.grpcMessages = all
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.text3)
                }
            }
            APICodeView(
                text: Binding(
                    get: { model.file.grpcMessages[safe: index]?.content ?? "{}" },
                    set: { value in
                        model.update { file in
                            var all = file.grpcMessages
                            if all.isEmpty { all = [.init(name: "message 1", content: "{}")] }
                            if all.indices.contains(index) { all[index].content = value }
                            file.grpcMessages = all
                        }
                    }), language: "json", accessibilityIdentifier: "grpcMessage\(index)")
        }
    }

    // MARK: What came back

    private var responsePane: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.border).frame(height: 1)
            if let result {
                HStack(spacing: 10) {
                    if result.running {
                        ProgressView().controlSize(.mini)
                        Text("Calling…").foregroundStyle(theme.text3)
                    } else if let error = result.error {
                        Text(verbatim: error).foregroundStyle(DiffColors.removed).lineLimit(2).textSelection(.enabled)
                    } else {
                        Text(verbatim: "\(result.statusName)").font(.system(size: ChromeMetrics.text(12), weight: .bold, design: .monospaced))
                            .foregroundStyle(result.succeeded ? TabStatusStyle.done : DiffColors.removed)
                            .accessibilityIdentifier("grpcStatus")
                        if !result.statusMessage.isEmpty { Text(verbatim: result.statusMessage).foregroundStyle(theme.text2).lineLimit(1).textSelection(.enabled) }
                    }
                    Spacer()
                    Text(verbatim: "\(result.received.count) received").foregroundStyle(theme.text3)
                    if !result.running { Text(verbatim: SQLConsoleView.duration(result.duration)).foregroundStyle(theme.text3) }
                }
                .font(.system(size: ChromeMetrics.text(11.5)))
                .padding(.horizontal, 10).frame(height: ChromeMetrics.row(30))
                APITabBar(
                    tabs: [("messages", "Response", result.received.count), ("headers", "Headers", result.headers.count + result.trailers.count), ("sent", "Sent", result.sent.count)],
                    selection: $responseTab, theme: theme)
                switch responseTab {
                case "headers":
                    APICodeView(
                        text: .constant((["# Headers"] + result.headers + ["", "# Trailers"] + result.trailers).joined(separator: "\n")), language: nil,
                        editable: false)
                case "sent":
                    APICodeView(text: .constant(result.sent.map(\.pretty).joined(separator: "\n\n")), language: "json", editable: false)
                default:
                    APICodeView(
                        text: .constant(result.received.map(\.pretty).joined(separator: "\n\n")), language: "json", editable: false,
                        accessibilityIdentifier: "grpcResponse")
                }
            } else {
                VStack(spacing: 4) {
                    Text("⌘↩ calls the method").foregroundStyle(theme.text3)
                    Text(verbatim: sourceNote).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                }
                .font(.system(size: ChromeMetrics.text(12)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Where the methods come from, said.
    private var sourceNote: String {
        let protos = (try? workspace.grpcPlan(model.file, at: model.url))?.protoFiles ?? []
        if !protos.isEmpty { return "Methods from \(protos.map(\.lastPathComponent).joined(separator: ", ")), by protoc" }
        return "Methods from the server's reflection"
    }
}
