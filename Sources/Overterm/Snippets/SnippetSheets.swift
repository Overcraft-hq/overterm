import SwiftUI

/// Add or edit a snippet.
package struct SnippetEditorView: View {
    @State package var snippet: Snippet
    package let isNew: Bool
    package let onSave: (Snippet) -> Void
    package let onCancel: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.headline)
            Form {
                TextField("Name", text: $snippet.name, prompt: Text("Deploy a service"))
                TextField("Command", text: $snippet.command, prompt: Text("deploy.sh release {{service}}"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...6)
            }
            Text(
                "{{name}} marks a value you’ll be asked for when using it. ${context}, ${namespace}, ${pod}, ${container}, ${name} and ${kind} make it a Kubernetes snippet: offered in the Kubernetes page’s menu, filled from the object, run in a tab pinned to its context."
            )
            .fixedSize(horizontal: false, vertical: true)
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
package struct SnippetFillView: View {
    package let snippet: Snippet
    /// (filled command, run?)
    package let onUse: (String, Bool) -> Void
    package let onCancel: () -> Void
    @State private var values: [String: String] = [:]

    private var filled: String { snippet.filled(with: values) }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.name).font(.headline)
            Form {
                ForEach(snippet.placeholders, id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name, default: ""] }, set: { values[name] = $0 }))
                }
            }
            Text(filled)
                .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
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
