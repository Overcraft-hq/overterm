import AppKit
import SwiftUI

/// A request, as the editor shows a `.bru` file: method, URL and Send on
/// top, Bruno's tabs under them, and the response below — the same parts
/// as Bruno's, laid out for a pane half a window wide.
struct APIRequestView: View {
    @ObservedObject var model: APIRequestModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Rectangle().fill(theme.border).frame(height: 1)
            VSplitView {
                requestPane
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 140, idealHeight: 260)
                APIResponseView(model: model, theme: theme)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 160)
            }
        }
        // Never wider than the pane: a line that wanted more (the response's
        // status, size, tests and buttons) widened the whole view, and the
        // pane centred it — Params, the status and Body cut off on the left.
        // Now what doesn't fit is cut on the right.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(theme.term)
    }

    // MARK: Method, URL, Send

    private var addressBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BruFile.methods, id: \.self) { method in
                    Button(method.uppercased()) { model.update { $0.method = method } }
                }
            } label: {
                Text(verbatim: model.file.method)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(APIMethodStyle.color(model.file.method))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("apiMethod")
            TextField("{{baseUrl}}/path", text: Binding(get: { model.file.url }, set: { model.setURL($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .onSubmit { model.send() }
                .accessibilityIdentifier("apiURL")
            Button {
                model.send()
            } label: {
                HStack(spacing: 4) {
                    if model.isSending { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(model.isSending ? "Cancel" : "Send")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(model.isSending ? theme.rowHover : theme.accentText.opacity(0.22)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the request — ⌘↩")
            .accessibilityIdentifier("apiSend")
            Menu {
                Button("Copy as cURL") { model.copyCurl() }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                if let workspace = model.workspace {
                    Divider()
                    Button("Clear Runtime Variables") { workspace.clearRuntimeVariables() }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    // MARK: The request's tabs

    private var requestPane: some View {
        VStack(spacing: 0) {
            APITabBar(
                tabs: APIRequestModel.RequestTab.allCases.map { ($0.id, $0.title, model.count($0)) },
                selection: Binding(get: { model.requestTab.id }, set: { model.requestTab = APIRequestModel.RequestTab(rawValue: $0) ?? .params }),
                theme: theme)
            Group {
                switch model.requestTab {
                case .params: params
                case .body: APIBodyEditor(model: model, theme: theme)
                case .headers:
                    APIPairsEditor(
                        pairs: binding(\.headers), keyPlaceholder: "Header", valuePlaceholder: "Value", addTitle: "Add Header", theme: theme)
                case .auth: APIAuthEditor(model: model, theme: theme)
                case .vars: vars
                case .script: scripts
                case .assert:
                    APIPairsEditor(
                        pairs: binding(\.assertions), keyPlaceholder: "res.status", valuePlaceholder: "eq 200", addTitle: "Add Assertion",
                        theme: theme, monospacedValues: true)
                case .tests:
                    APICodeView(
                        text: textBinding(\.tests), language: "javascript",
                        placeholder: "test(\"status\", () => expect(res.status).to.equal(200));", accessibilityIdentifier: "apiTests")
                case .docs:
                    APICodeView(text: textBinding(\.docs), language: "markdown", wraps: true)
                case .settings: settings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var params: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                APISection(title: "Query", theme: theme) {
                    APIPairsEditor(
                        pairs: Binding(get: { model.file.queryParams }, set: { model.setQueryParams($0) }), keyPlaceholder: "Name",
                        valuePlaceholder: "Value", addTitle: "Add Param", theme: theme, scrolls: false)
                }
                if !model.file.pathParams.isEmpty {
                    APISection(title: "Path", theme: theme) {
                        APIPairsEditor(
                            pairs: binding(\.pathParams), keyPlaceholder: "Name", valuePlaceholder: "Value", addTitle: nil, theme: theme,
                            scrolls: false, fixedKeys: true)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var vars: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                APISection(title: "Pre Request", theme: theme) {
                    APIPairsEditor(
                        pairs: binding(\.preRequestVars), keyPlaceholder: "Name", valuePlaceholder: "Value", addTitle: "Add Variable",
                        theme: theme, scrolls: false)
                }
                APISection(title: "Post Response", theme: theme) {
                    APIPairsEditor(
                        pairs: binding(\.postResponseVars), keyPlaceholder: "Name", valuePlaceholder: "res.body.token",
                        addTitle: "Add Variable", theme: theme, scrolls: false, monospacedValues: true)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var scripts: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                APISectionTitle(title: "Pre Request", theme: theme)
                APICodeView(text: textBinding(\.preRequestScript), language: "javascript", accessibilityIdentifier: "apiPreScript")
            }
            .frame(minHeight: 80)
            VStack(alignment: .leading, spacing: 0) {
                APISectionTitle(title: "Post Response", theme: theme)
                APICodeView(text: textBinding(\.postResponseScript), language: "javascript")
            }
            .frame(minHeight: 80)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Encode the URL", isOn: Binding(get: { model.file.encodesURL }, set: { value in model.update { $0.encodesURL = value } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
            Text("Spaces and characters a URL can't hold are percent-encoded before it is sent.")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
        }
        .padding(12)
    }

    private func binding(_ path: WritableKeyPath<BruFile, [BruPair]>) -> Binding<[BruPair]> {
        Binding(get: { model.file[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }

    private func textBinding(_ path: WritableKeyPath<BruFile, String?>) -> Binding<String> {
        Binding(get: { model.file[keyPath: path] ?? "" }, set: { value in model.update { $0[keyPath: path] = value.isEmpty ? nil : value } })
    }
}

/// Method colours, as API clients have taught everyone to read them.
enum APIMethodStyle {
    static func color(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": Color(red: 0.35, green: 0.78, blue: 0.45)
        case "POST": Color(red: 0.96, green: 0.70, blue: 0.25)
        case "PUT": Color(red: 0.36, green: 0.62, blue: 0.98)
        case "PATCH": Color(red: 0.70, green: 0.52, blue: 0.98)
        case "DELETE": Color(red: 0.96, green: 0.40, blue: 0.40)
        default: Color(red: 0.6, green: 0.6, blue: 0.65)
        }
    }

    /// GET, POST, DEL… — short enough for a row.
    static func short(_ method: String) -> String {
        switch method.uppercased() {
        case "DELETE": "DEL"
        case "OPTIONS": "OPT"
        case "PATCH": "PATCH"
        default: method.uppercased()
        }
    }
}

/// A row of tabs with what each holds counted, Bruno's way.
struct APITabBar: View {
    let tabs: [(id: String, title: String, count: Int)]
    @Binding var selection: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.id) { tab in
                    Button {
                        selection = tab.id
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.title).font(.system(size: 11.5, weight: selection == tab.id ? .semibold : .regular))
                            if tab.count > 0 {
                                Text(verbatim: "\(tab.count)")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(theme.iconBg))
                            }
                        }
                        .foregroundStyle(selection == tab.id ? theme.text : theme.text2)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selection == tab.id ? theme.accentText : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("apiTab-\(tab.id)")
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

struct APISectionTitle: View {
    let title: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

struct APISection<Content: View>: View {
    let title: String
    @ObservedObject var theme: ChromeTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            APISectionTitle(title: title, theme: theme)
            content
        }
    }
}

/// Key–value rows — params, headers, vars, form fields, assertions: a box
/// to switch one off (Bruno's `~`), its name, its value, ✕.
struct APIPairsEditor: View {
    @Binding var pairs: [BruPair]
    let keyPlaceholder: String
    let valuePlaceholder: String
    /// nil: rows come from elsewhere (path params come from the URL).
    let addTitle: String?
    @ObservedObject var theme: ChromeTheme
    var scrolls = true
    var fixedKeys = false
    /// Values are code (an expression, an assertion), else as typed.
    var monospacedValues = true
    /// A trailing control per row (multipart's file picker).
    var accessory: ((Int) -> AnyView)?
    /// A row's identity, which moves with it: rows named by their index were
    /// rebound to the next pair when one above them went, and a field still
    /// being edited then wrote its text into that other pair.
    @State private var ids: [UUID] = []

    private var rowIDs: [UUID] {
        ids.count == pairs.count ? ids : Array((ids + (0..<max(0, pairs.count - ids.count)).map { _ in UUID() }).prefix(pairs.count))
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { rows.padding(.vertical, 6) }
            } else {
                rows
            }
        }
        // Rows that came from elsewhere (the URL, the file reloaded) get theirs.
        .onAppear { ids = rowIDs }
        .onChange(of: pairs.count) { _ in if ids.count != pairs.count { ids = rowIDs } }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(zip(pairs.indices, rowIDs)), id: \.1) { index, _ in
                row(index)
            }
            if let addTitle {
                Button {
                    ids = rowIDs + [UUID()]
                    pairs.append(BruPair(key: "", value: ""))
                } label: {
                    Label(addTitle, systemImage: "plus")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.accentText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .accessibilityIdentifier("apiAdd-\(addTitle)")
            }
        }
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { pairs.indices.contains(index) ? pairs[index].enabled : false },
                    set: { value in if pairs.indices.contains(index) { pairs[index].enabled = value } })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            field(
                keyPlaceholder,
                Binding(
                    get: { pairs.indices.contains(index) ? pairs[index].key : "" },
                    set: { value in if pairs.indices.contains(index) { pairs[index].key = value } }), monospaced: true
            )
            .disabled(fixedKeys)
            .frame(maxWidth: 220)
            field(
                valuePlaceholder,
                Binding(
                    get: { pairs.indices.contains(index) ? pairs[index].value : "" },
                    set: { value in if pairs.indices.contains(index) { pairs[index].value = value } }), monospaced: monospacedValues)
            if let accessory { accessory(index) }
            if !fixedKeys {
                Button {
                    guard pairs.indices.contains(index) else { return }
                    var kept = rowIDs
                    kept.remove(at: index)
                    ids = kept
                    pairs.remove(at: index)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .opacity(pairs.indices.contains(index) && pairs[index].enabled ? 1 : 0.55)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func field(_ placeholder: String, _ text: Binding<String>, monospaced: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.rowHover.opacity(0.6)))
    }
}

/// The Body tab: the kind of body, and the editor for that kind.
struct APIBodyEditor: View {
    @ObservedObject var model: APIRequestModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: Binding(get: { model.file.bodyMode }, set: { mode in model.update { $0.bodyMode = mode } })) {
                    ForEach(BruFile.BodyMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("apiBodyMode")
                Spacer()
                if model.file.bodyMode == .json {
                    Button("Prettify") { prettify() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.accentText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch model.file.bodyMode {
        case .none:
            Text("This request sends no body.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text3)
                .padding(12)
        case .json, .text, .xml, .sparql:
            APICodeView(text: bodyText(model.file.bodyMode), language: language, accessibilityIdentifier: "apiBody")
        case .graphql:
            VSplitView {
                APICodeView(text: bodyText(.graphql), language: nil, accessibilityIdentifier: "apiGraphQL").frame(minHeight: 80)
                VStack(alignment: .leading, spacing: 0) {
                    APISectionTitle(title: "Variables", theme: theme)
                    APICodeView(
                        text: Binding(
                            get: { model.file.graphQLVariables ?? "" },
                            set: { value in model.update { $0.graphQLVariables = value.isEmpty ? nil : value } }), language: "json")
                }
                .frame(minHeight: 60)
            }
        case .formUrlEncoded:
            APIPairsEditor(
                pairs: Binding(get: { model.file.formFields }, set: { value in model.update { $0.formFields = value } }), keyPlaceholder: "Name",
                valuePlaceholder: "Value", addTitle: "Add Field", theme: theme)
        case .multipartForm:
            APIPairsEditor(
                pairs: Binding(get: { model.file.multipartFields }, set: { value in model.update { $0.multipartFields = value } }),
                keyPlaceholder: "Name", valuePlaceholder: "Value or @file(path)", addTitle: "Add Field", theme: theme,
                accessory: { index in AnyView(pickFileButton(index)) })
        case .file:
            APIPairsEditor(
                pairs: Binding(get: { model.file.pairs("body:file") }, set: { value in model.update { $0.setPairs("body:file", value) } }),
                keyPlaceholder: "file", valuePlaceholder: "@file(path) @contentType(type)", addTitle: "Add File", theme: theme)
        }
    }

    private var language: String? {
        switch model.file.bodyMode {
        case .json: "json"
        case .xml: "html"
        default: nil
        }
    }

    private func bodyText(_ mode: BruFile.BodyMode) -> Binding<String> {
        Binding(get: { model.file.body(mode) ?? "" }, set: { value in model.update { $0.setBody(mode, value) } })
    }

    private func prettify() {
        guard let text = model.file.body(.json), let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return NSSound.beep() }
        // JSONSerialization indents with two spaces and ` : `; Bruno's
        // writer and most people use `: `.
        let text2 = String(decoding: pretty, as: UTF8.self).replacingOccurrences(of: "\" : ", with: "\": ")
        model.update { $0.setBody(.json, text2) }
    }

    /// Picks a file for a multipart field: `@file(path)`, relative to the
    /// collection when it is inside it.
    private func pickFileButton(_ index: Int) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            let root = model.workspace?.collection(containing: model.url)?.root.standardizedFileURL.path
            let path = root.flatMap { picked.path.hasPrefix($0 + "/") ? String(picked.path.dropFirst($0.count + 1)) : nil } ?? picked.path
            model.update { file in
                var fields = file.multipartFields
                guard fields.indices.contains(index) else { return }
                fields[index].value = "@file(\(path))"
                file.multipartFields = fields
            }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help("Choose a file")
    }
}

/// The Auth tab: the mode, and its fields.
struct APIAuthEditor: View {
    @ObservedObject var model: APIRequestModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { model.file.authMode }, set: { mode in model.update { $0.authMode = mode } })) {
                ForEach(BruFile.AuthMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("apiAuthMode")
            switch model.file.authMode {
            case .none:
                note("No auth is sent.")
            case .inherit:
                note(inherited)
            case .bearer:
                field("Token", "token", mode: .bearer)
            case .basic:
                field("Username", "username", mode: .basic)
                field("Password", "password", mode: .basic, secure: true)
            case .apikey:
                field("Key", "key", mode: .apikey)
                field("Value", "value", mode: .apikey)
                Picker(
                    "Add to",
                    selection: Binding(
                        get: { model.file.value("placement", in: "auth:apikey") ?? "header" },
                        set: { value in model.update { $0.setValue(value, for: "placement", in: "auth:apikey") } })
                ) {
                    Text("Header").tag("header")
                    Text("Query Params").tag("queryparams")
                }
                .fixedSize()
            default:
                note("\(model.file.authMode.title) is kept in the file as it is; Overterm doesn't send it yet — run this request with bru.")
            }
            Spacer()
        }
        .padding(12)
    }

    private var inherited: String {
        guard let workspace = model.workspace, let collection = workspace.collection(containing: model.url) else {
            return "Inherits the auth of its folder or collection."
        }
        // The collection's and folders' files only — not setup(for:), which
        // reads the environment and the keychain, on every draw of the tab.
        let folders = collection.folders(containing: model.url).compactMap(BrunoCollection.folderFile)
        let (_, mode) = APIRequestPlan.effectiveAuth(
            model.file,
            context: APIRequestPlan.Context(collectionRoot: collection.root, collectionFile: collection.collectionFile, folderFiles: folders))
        return mode == .none ? "Inherits — and nothing above it sets auth." : "Inherits \(mode.title) from its folder or collection."
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ title: String, _ key: String, mode: BruFile.AuthMode, secure: Bool = false) -> some View {
        let binding = Binding(
            get: { model.file.value(key, in: "auth:\(mode.rawValue)") ?? "" },
            set: { value in model.update { $0.setValue(value, for: key, in: "auth:\(mode.rawValue)") } })
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.text2).frame(width: 80, alignment: .leading)
            Group {
                if secure { SecureField("", text: binding) } else { TextField("", text: binding) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.rowHover.opacity(0.6)))
        }
    }
}
