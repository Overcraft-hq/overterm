import SwiftUI

/// The New Task sheet: branch, base, and what to start in it.
struct NewTaskView: View {
    let repo: URL
    let defaultBase: String
    /// Called with (branch, base, agent) — agent nil means a plain shell.
    /// Returns an error message to show, or nil when the task was created.
    let onCreate: (String, String, Agent?) async -> String?
    let onCancel: () -> Void

    @State private var branch = ""
    @State private var base = ""
    @State private var agent: Agent? = .claude
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Task").font(.headline)
            Text("A worktree on its own branch, with a tab in it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Branch", text: $branch, prompt: Text("feat/something"))
                TextField("From", text: $base)
                Picker("Start", selection: $agent) {
                    ForEach(Agent.allCases) { Text($0.name).tag(Agent?.some($0)) }
                    Text("Shell only").tag(Agent?.none)
                }
            }

            Text(branch.isEmpty ? " " : TaskCreator.worktreePath(repo: repo, branch: branch).path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { base = defaultBase }
    }

    private func create() {
        working = true
        error = nil
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let base = base.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            error = await onCreate(branch, base.isEmpty ? "HEAD" : base, agent)
            working = false
        }
    }
}
