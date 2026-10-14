import SwiftUI

/// Add or edit a snippet.
struct SnippetEditorView: View {
    @State var snippet: Snippet
    let isNew: Bool
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.headline)
            Form {
                TextField("Name", text: $snippet.name, prompt: Text("Deploy a service"))
                TextField("Command", text: $snippet.command, prompt: Text("deploy.sh release {{service}}"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...6)
            }
            Text("{{name}} marks a value you’ll be asked for when using it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Asks for a snippet's placeholder values, then runs or inserts it.
struct SnippetFillView: View {
    let snippet: Snippet
    /// (filled command, run?)
    let onUse: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]

    private var filled: String { snippet.filled(with: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.name).font(.headline)
            Form {
                ForEach(snippet.placeholders, id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name, default: ""] }, set: { values[name] = $0 }))
                }
            }
            Text(filled)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Insert") { onUse(filled, false) }
                Button("Run") { onUse(filled, true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
