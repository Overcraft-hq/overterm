import SwiftUI

/// What the Create Pull Request sheet is about, read as it opens.
package struct CreatePullRequestFacts: Equatable, Sendable {
    /// `acme/shop`, as the remote names it (no credentials).
    package var repository: String
    package var branch: String
    /// The repository's default branch, else the main worktree's.
    package var base: String
    /// The branch's commits the base hasn't, newest first.
    package var commits: [PullRequestDraft.Commit]
    /// No upstream: the branch is published (pushed, its upstream set) first.
    package var publishes: Bool
    /// Commits not pushed yet: pushed first.
    package var unpushed: Int

    package init(repository: String, branch: String, base: String, commits: [PullRequestDraft.Commit], publishes: Bool, unpushed: Int) {
        self.repository = repository
        self.branch = branch
        self.base = base
        self.commits = commits
        self.publishes = publishes
        self.unpushed = unpushed
    }

    /// What happens before the pull request is opened, said. Pure.
    package var pushLine: String? {
        if publishes { return "\(branch) isn't on GitHub yet: it is published first (git push --set-upstream origin HEAD)." }
        if unpushed > 0 { return unpushed == 1 ? "1 commit isn't pushed: it is pushed first." : "\(unpushed) commits aren't pushed: they are pushed first." }
        return nil
    }
}

/// Create Pull Request… (GIT-N1): the branch's commits, a title and body
/// filled from them, the base, draft or not — and the button that opens it,
/// the sheet being its question (D-9): nothing is sent before it.
package struct CreatePullRequestView: View {
    package let facts: CreatePullRequestFacts
    /// (title, body, base, draft): an error to show, or nil once opened.
    package let onCreate: (String, String, String, Bool) async -> String?
    package let onCancel: () -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var draft = true
    @State private var error: String?
    @State private var working = false

    package init(facts: CreatePullRequestFacts, onCreate: @escaping (String, String, String, Bool) async -> String?, onCancel: @escaping () -> Void) {
        self.facts = facts
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    package static let shownCommits = 8

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Pull Request").font(.headline)
            Text(verbatim: "\(facts.repository) · \(facts.branch) → \(base.isEmpty ? facts.base : base)")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("createPR.scope")

            VStack(alignment: .leading, spacing: 3) {
                Text(facts.commits.count == 1 ? "1 commit" : "\(facts.commits.count) commits")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(facts.commits.prefix(Self.shownCommits).enumerated()), id: \.offset) { _, commit in
                    Text(verbatim: "• " + commit.subject).font(.callout).lineLimit(1).truncationMode(.tail)
                }
                if facts.commits.count > Self.shownCommits {
                    Text(verbatim: "… and \(facts.commits.count - Self.shownCommits) more").font(.caption).foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Title", text: $title).accessibilityIdentifier("createPR.title")
                TextField("Base", text: $base).accessibilityIdentifier("createPR.base")
                Toggle("Draft", isOn: $draft)
            }
            TextEditor(text: $bodyText)
                .font(.callout)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("createPR.body")

            if let line = facts.pushLine {
                Text(verbatim: line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(verbatim: error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(working ? "Opening…" : draft ? "Open Draft" : "Open Pull Request") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            let filled = PullRequestDraft.fill(commits: facts.commits, branch: facts.branch)
            title = filled.title
            bodyText = filled.body
            base = facts.base
        }
    }

    private func create() {
        working = true
        error = nil
        Task { @MainActor in
            error = await onCreate(title.trimmingCharacters(in: .whitespaces), bodyText, base.trimmingCharacters(in: .whitespaces), draft)
            working = false
        }
    }
}
