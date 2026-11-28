import SwiftUI

/// The New Task sheet: branch, base, and what to start in it.
package struct NewTaskView: View {
    package let repo: URL
    package let defaultBase: String
    /// Settings ▸ Agents: what to start, and where the worktree goes.
    package let defaultAgent: Agent?
    package let location: Settings.WorktreeLocation
    /// The repository's compose file, when Docker is on and it has one:
    /// the new worktree's stack can be started with it.
    package var composeFile: String?
    /// The contexts the task's tab may be pinned to (Terminal in this
    /// context, 3.11), read as the sheet opens; nil with Kubernetes off.
    package var kubernetes: (() async -> KubeTaskPin.Offer)?
    /// The repository's setup as kept (`TaskSetupStore`): what the fields
    /// start with; what they say at Create is kept for the next task.
    package var setup = TaskSetup()
    /// Where each agent's CLI is, as a new tab's shell would find it
    /// (`AgentFinder`), read as the sheet opens: one it wouldn't find is
    /// marked, and isn't what the sheet starts with.
    package var agents: [Agent: AgentFinder.Result] = [:]
    /// Called with (branch, base, agent, start the stack, the context to
    /// pin the tab to, what the agent is to do, the repository's setup) —
    /// agent nil means a plain shell. Returns an error message to show, or
    /// nil when the task was created.
    package let onCreate: (String, String, Agent?, Bool, String?, String, TaskSetup) async -> String?
    package let onCancel: () -> Void

    @State private var branch = ""
    @State private var base = ""
    @State private var agent: Agent?
    @State private var error: String?
    @State private var working = false
    @State private var startStack = false
    @State private var offer: KubeTaskPin.Offer?
    @State private var pin: String?
    @State private var task = ""
    @State private var copyField = ""
    @State private var setupCommand = ""
    @State private var showsSetup = false
    /// The repository's branches, read once as the sheet opens (From's menu,
    /// and whether Branch exists).
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    /// Whether From names a commit; nil while it is read.
    @State private var baseResolves: Bool?

    private var branchNote: (text: String, isProblem: Bool)? { TaskFields.branchNote(branch, local: Set(localBranches)) }
    private var branchExists: Bool { localBranches.contains(branch.trimmingCharacters(in: .whitespaces)) }
    private var baseNote: (text: String, isProblem: Bool)? {
        TaskFields.baseNote(base, resolves: baseResolves, branchExists: branchExists)
    }
    private var blocked: Bool { branchNote?.isProblem == true || baseNote?.isProblem == true }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Task").font(.headline)
            Text("A worktree on its own branch, with a tab in it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Branch", text: $branch, prompt: Text("feat/something"))
                    .help("A new branch for the task, or an existing one to check out as it is")
                    .accessibilityIdentifier("newTask.branch")
                if let note = branchNote { fieldNote(note) }
                HStack(spacing: 4) {
                    TextField("From", text: $base, prompt: Text("main"))
                        .help("Where the new branch starts: a branch, a remote branch, a tag or a commit")
                        .accessibilityIdentifier("newTask.from")
                    Menu {
                        if !localBranches.isEmpty {
                            Section("Branches") { ForEach(localBranches.prefix(30), id: \.self) { name in Button(name) { base = name } } }
                        }
                        if !remoteBranches.isEmpty {
                            Section("Remote branches") { ForEach(remoteBranches.prefix(30), id: \.self) { name in Button(name) { base = name } } }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(localBranches.isEmpty && remoteBranches.isEmpty)
                    .help("Pick a branch to start from")
                }
                .disabled(branchExists)
                if let note = baseNote { fieldNote(note) }
                Picker("Start", selection: $agent) {
                    ForEach(Agent.allCases) { Text(verbatim: Self.pickerTitle($0, agents[$0])).tag(Agent?.some($0)) }
                    Text("Shell only").tag(Agent?.none)
                }
                if let agent {
                    // GIT-G11: what it is to do, typed into it once it is up.
                    TextField("Task", text: $task, prompt: Text("What \(agent.name) should do — sent when it starts"), axis: .vertical)
                        .lineLimit(3...8)
                        .help("Typed into \(agent.name) once it is ready, then Return. Leave it empty to start \(agent.name) as before.")
                        .accessibilityIdentifier("newTask.task")
                }
                if let composeFile {
                    Toggle("Start its compose stack (\(composeFile))", isOn: $startStack)
                        .help("docker compose up -d in the new worktree, in a tab, beside the other worktrees' stacks. A port another one holds is offered elsewhere first.")
                }
                if let offer, !offer.choices.isEmpty || offer.note != nil {
                    Picker("Kubernetes", selection: $pin) {
                        Text("Your current context").tag(String?.none)
                        ForEach(offer.choices) { Text(verbatim: "⎈ " + $0.title).tag(String?.some($0.context)) }
                    }
                    .help("The tab's plain kubectl, helm and k9s go to this context — the agent's too. Your current context stays as it is.")
                    if let note = offer.note {
                        Text(verbatim: note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // D-7 (a): kept in Overterm's folder for this repository, never in it.
            DisclosureGroup("Setup for \(repo.lastPathComponent)", isExpanded: $showsSetup) {
                Form {
                    TextField("Copy", text: $copyField, prompt: Text(".env, .env.local"))
                        .help("Untracked files of the repository copied into the new worktree — copied, never read. Only paths inside the repository.")
                        .accessibilityIdentifier("newTask.copy")
                    TextField("Then run", text: $setupCommand, prompt: Text("npm ci"))
                        .help("Typed in the task's tab before its agent starts, which starts only if this succeeds.")
                        .accessibilityIdentifier("newTask.setup")
                }
                .padding(.top, 4)
                Text("Kept by Overterm for this repository, not in it.").font(.caption).foregroundStyle(.secondary)
            }

            Text(branch.isEmpty ? " " : TaskCreator.worktreePath(repo: repo, branch: branch, location: location).path)
                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
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
                    .disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty || working || blocked)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            base = defaultBase
            agent = Self.startingAgent(defaultAgent, agents)
            copyField = setup.copy.joined(separator: ", ")
            setupCommand = setup.command
            showsSetup = !setup.isEmpty
        }
        .task {
            let refs = await TaskFields.refs(in: repo)
            localBranches = refs.local
            remoteBranches = refs.remote
        }
        .task(id: base) {
            // A pause while typing, then git says whether it names a commit.
            baseResolves = nil
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let resolved = await TaskFields.resolves(base, in: repo)
            guard !Task.isCancelled else { return }
            baseResolves = resolved
        }
        .task {
            guard let kubernetes else { return }
            let read = await kubernetes()
            offer = read
            pin = read.suggested
        }
    }

    /// The picker's row: the agent's name, "(not found)" when it is missing,
    /// a quiet "(not on PATH)" when found only off it. Pure.
    package nonisolated static func pickerTitle(_ agent: Agent, _ found: AgentFinder.Result?) -> String {
        guard let note = found?.pickerNote else { return agent.name }
        return "\(agent.name) (\(note))"
    }

    /// What the picker starts with: Settings ▸ Agents' agent, or Shell only
    /// when it is missing — found off the PATH (an alias's) starts as set. Pure.
    package nonisolated static func startingAgent(_ preferred: Agent?, _ agents: [Agent: AgentFinder.Result]) -> Agent? {
        guard let preferred, agents[preferred]?.isNotFound != true else { return nil }
        return preferred
    }

    private func fieldNote(_ note: (text: String, isProblem: Bool)) -> some View {
        Text(verbatim: note.text)
            .font(.caption)
            .foregroundStyle(note.isProblem ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func create() {
        working = true
        error = nil
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let base = base.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            let setup = TaskSetup(copy: TaskSetup.paths(copyField), command: setupCommand.trimmingCharacters(in: .whitespaces))
            error = await onCreate(branch, base.isEmpty ? "HEAD" : base, agent, startStack, pin, agent == nil ? "" : task, setup)
            working = false
        }
    }
}
