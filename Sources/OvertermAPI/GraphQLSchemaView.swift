import AppKit
import SwiftUI

/// A GraphQL request's Schema tab: the server's types as its introspection
/// says them — the roots first, each type's fields with their arguments and
/// types, a filter over all of it — GraphiQL's docs, in the request.
package struct GraphQLSchemaView: View {
    @ObservedObject package var model: APIRequestModel
    @ObservedObject package var workspace: APIWorkspace
    @ObservedObject package var theme: ChromeTheme
    @State private var filter = ""
    @State private var open: Set<String> = []

    private var state: GraphQLSchemaState? { workspace.graphQLSchema(model.file, at: model.url) }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                TextField("Filter types and fields", text: $filter).textFieldStyle(.plain).font(.system(size: ChromeMetrics.text(12)))
                    .accessibilityIdentifier("graphQLSchemaFilter")
                Spacer()
                if case .loading = state { ProgressView().controlSize(.mini) }
                Button("Refresh") { workspace.loadGraphQLSchema(model.file, at: model.url, force: true) }
                    .controlSize(.small)
                    .help("Read the schema again — introspection, with this request's URL, headers and auth")
            }
            .padding(.horizontal, 12).frame(height: ChromeMetrics.row(30))
            Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1)
            content
        }
        .onAppear { workspace.loadGraphQLSchema(model.file, at: model.url) }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loaded(let schema): types(schema)
        case .failed(let message):
            note("Couldn't read the schema: \(message)")
        case .loading:
            note("Reading the schema…")
        case nil:
            note("Set the URL, then Refresh.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
    }

    private func types(_ schema: GraphQLSchema) -> some View {
        let query = filter.lowercased()
        let roots = [schema.queryType, schema.mutationType, schema.subscriptionType].compactMap { $0 }
        let shown = schema.browsable.filter { type in
            query.isEmpty || type.name.lowercased().contains(query) || type.fields.contains { $0.name.lowercased().contains(query) }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.name) { type in
                    // A filter opens what it matched; the roots start open.
                    let expanded = open.contains(type.name) || (!query.isEmpty) || (open.isEmpty && roots.first == type.name)
                    typeRow(type, root: roots.contains(type.name), expanded: expanded)
                    if expanded { members(type, query: query) }
                }
                if shown.isEmpty { note("Nothing matches.") }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("graphQLSchema")
    }

    private func typeRow(_ type: GraphQLSchema.NamedType, root: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: ChromeMetrics.text(8), weight: .semibold))
                .foregroundStyle(theme.text3).frame(width: 10)
            Text(verbatim: type.name).font(.system(size: ChromeMetrics.text(12), weight: root ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(root ? theme.accentText : theme.text)
            Text(verbatim: type.kind.lowercased().replacingOccurrences(of: "_", with: " ")).font(.system(size: ChromeMetrics.text(10.5)))
                .foregroundStyle(theme.text3)
            if let description = type.description, !description.isEmpty {
                Text(verbatim: description).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: ChromeMetrics.row(24))
        .contentShape(Rectangle())
        .onTapGesture {
            if open.contains(type.name) { open.remove(type.name) } else { open.insert(type.name) }
        }
        .accessibilityIdentifier("graphQLType-\(type.name)")
    }

    @ViewBuilder private func members(_ type: GraphQLSchema.NamedType, query: String) -> some View {
        let fields = type.fields.filter { query.isEmpty || type.name.lowercased().contains(query) || $0.name.lowercased().contains(query) }
        ForEach(fields, id: \.name) { field in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(verbatim: field.name).foregroundStyle(field.deprecation == nil ? theme.text : theme.text3)
                        .strikethrough(field.deprecation != nil)
                    if !field.arguments.isEmpty {
                        Text(verbatim: "(" + field.arguments.map { "\($0.name): \($0.type.display)" }.joined(separator: ", ") + ")")
                            .foregroundStyle(theme.text2)
                    }
                    Text(verbatim: ": ").foregroundStyle(theme.text3)
                    Text(verbatim: field.type.display).foregroundStyle(theme.orangeText)
                }
                .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                .lineLimit(2)
                if let description = field.description, !description.isEmpty {
                    Text(verbatim: description).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(3)
                }
            }
            .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Copy Field") { copy(field.name) }
                if let named = field.type.named { Button("Show \(named)") { open.insert(named) } }
            }
        }
        if !type.inputFields.isEmpty {
            ForEach(type.inputFields, id: \.name) { field in
                HStack(spacing: 0) {
                    Text(verbatim: field.name).foregroundStyle(theme.text)
                    Text(verbatim: ": ").foregroundStyle(theme.text3)
                    Text(verbatim: field.type.display).foregroundStyle(theme.orangeText)
                    if let value = field.defaultValue { Text(verbatim: " = \(value)").foregroundStyle(theme.text3) }
                }
                .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                .padding(.leading, 34).padding(.vertical, 3)
            }
        }
        if !type.enumValues.isEmpty {
            Text(verbatim: type.enumValues.joined(separator: " · ")).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                .foregroundStyle(theme.text2).padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
        }
        if !type.possibleTypes.isEmpty {
            Text(verbatim: "one of: " + type.possibleTypes.joined(separator: ", ")).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                .foregroundStyle(theme.text2).padding(.leading, 34).padding(.vertical, 3)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
