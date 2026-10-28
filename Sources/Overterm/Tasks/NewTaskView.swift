import SwiftUI

/// The New Task sheet: branch, base, and what to start in it.
struct NewTaskView: View {
    let repo: URL
    let defaultBase: String
    /// Settings ▸ Agents: what to start, and where the worktree goes.
    let defaultAgent: Agent?
    let location: Settings.WorktreeLocation
    /// The repository's compose file, when Docker is on and it has one:
    /// the new worktree's stack can be started with it.
    var composeFile: String?
    /// Called with (branch, base, agent, start the stack) — agent nil means
    /// a plain shell. Returns an error message to show, or nil when the
    /// task was created.
    let onCreate: (String, String, Agent?, Bool) async -> String?
    let onCancel: () -> Void

    @State private var branch = ""
    @State private var base = ""
    @State private var agent: Agent?
    @State private var error: String?
    @State private var working = false
    @State private var startStack = false

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
                if let composeFile {
                    Toggle("Start its compose stack (\(composeFile))", isOn: $startStack)
                        .help("docker compose up -d in the new worktree, in a tab. Its project is the worktree's folder, so it runs beside the other worktrees' stacks — unless their ports collide.")
                }
            }

            Text(branch.isEmpty ? " " : TaskCreator.worktreePath(repo: repo, branch: branch, location: location).path)
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
        .onAppear {
            base = defaultBase
            agent = defaultAgent
        }
    }

    private func create() {
        working = true
        error = nil
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let base = base.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            error = await onCreate(branch, base.isEmpty ? "HEAD" : base, agent, startStack)
            working = false
        }
    }
}
