import AppKit
import SwiftUI

/// The Pull Request pane: the checkout's PR — state, checks, description,
/// conversation, review threads by file and line — with a comment box and
/// a reply box per thread.
package struct PullRequestView: View {
    @ObservedObject package var model: PullRequestModel
    @ObservedObject package var theme: ChromeTheme
    /// The keys it names, as bound now.
    @ObservedObject var keys = Keybindings.shared
    package let onClose: () -> Void
    /// A thread's file, at its line, in the editor.
    package let onOpenFile: (String, Int?) -> Void
    /// The pull request's changes in a review tab.
    package var onReview: (Int) -> Void = { _ in }
    /// Create Pull Request… for the branch that has none.
    package var onCreate: () -> Void = {}
    /// A write on it (Mark Ready, Approve, Request Changes, Merge…, a
    /// run's Re-run): the window asks, then sends it.
    package var onWrite: (PullRequestWrite) -> Void = { _ in }
    /// Check Out in a New Worktree… (asked by the window).
    package var onCheckOut: () -> Void = {}
    /// Address This Thread: the thread to the checkout's agent (GIT-N2).
    package var onAddress: (ReviewThread) -> Void = { _ in }
    @State private var draft = ""
    @State private var replies: [Int: String] = [:]
    @State private var checksOpen = false

    package init(
        model: PullRequestModel, theme: ChromeTheme, onClose: @escaping () -> Void, onOpenFile: @escaping (String, Int?) -> Void,
        onReview: @escaping (Int) -> Void = { _ in }, onCreate: @escaping () -> Void = {}, onCheckOut: @escaping () -> Void = {},
        onWrite: @escaping (PullRequestWrite) -> Void = { _ in }, onAddress: @escaping (ReviewThread) -> Void = { _ in }
    ) {
        self.onCheckOut = onCheckOut
        self.onAddress = onAddress
        self._model = ObservedObject(wrappedValue: model)
        self._theme = ObservedObject(wrappedValue: theme)
        self.onClose = onClose
        self.onOpenFile = onOpenFile
        self.onReview = onReview
        self.onCreate = onCreate
        self.onWrite = onWrite
    }

    package var body: some View {
        VStack(spacing: 0) {
            header
            if model.picked != nil { pickedBar }
            Divider().opacity(0.4)
            switch model.phase {
            case .idle,
                .loading where model.detail == nil:
                placeholder("Loading pull request…")
            case .none:
                if let branch = model.branch {
                    VStack(spacing: 10) {
                        Text(verbatim: "No pull request for \(branch).").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
                        // GIT-U13: the way on from here, not a dead end.
                        Button("Create Pull Request…", action: onCreate).accessibilityIdentifier("pullRequest.create")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("Not on a branch.")
                }
            case .failed(let message) where model.detail == nil:
                placeholder(message)
            default:
                if let detail = model.detail { content(detail) }
            }
        }
        .background(theme.strip)
    }

    // MARK: Header

    /// Picked in Overgit: not this checkout's branch's — said, with the way back.
    private var pickedBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin").font(.system(size: ChromeMetrics.text(10)))
            Text(verbatim: model.detail.map { "\($0.summary.branch)" } ?? "Picked in Overgit")
                .font(.system(size: ChromeMetrics.text(11))).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(model.branch.map { "Show \($0)’s" } ?? "Show this branch’s") { model.unpick() }
                .buttonStyle(.plain)
                .font(.system(size: ChromeMetrics.text(11), weight: .medium))
                .foregroundStyle(theme.accentText)
        }
        .foregroundStyle(theme.dimText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let pr = model.detail?.summary {
                StatePill(state: pr.state)
                Text(verbatim: "#\(pr.number) \(pr.title)")
                    .font(.system(size: ChromeMetrics.text(12), weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pr.title)
            } else {
                Text("Pull Request").font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
            if model.phase == .loading { ProgressView().controlSize(.small) }
            if let number = model.detail?.summary.number {
                iconButton("rectangle.split.2x1", help: "Review Changes") { onReview(number) }
            }
            if let pr = model.detail?.summary, pr.state == .open || pr.state == .draft { writes(pr) }
            if let url = model.detail?.summary.url {
                iconButton("safari", help: "Open on GitHub") { NSWorkspace.shared.open(url) }
            }
            iconButton("arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            iconButton("xmark", help: KeyHints.help("Close", command: "changes.toggle", keys: keys), action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: ChromeMetrics.row(36))
    }

    /// Its writes (D-9 (c)), each asked by the window first. Approve and
    /// Request Changes say what the comment box says.
    private func writes(_ pr: PullRequestSummary) -> some View {
        Menu {
            if pr.state == .draft {
                Button("Mark Ready for Review…") { onWrite(.ready(number: pr.number)) }
                Divider()
            }
            Button("Approve…") { onWrite(.approve(number: pr.number, body: draft.trimmingCharacters(in: .whitespacesAndNewlines))) }
            Button("Request Changes…") { onWrite(.requestChanges(number: pr.number, body: draft.trimmingCharacters(in: .whitespacesAndNewlines))) }
                .help("What the comment box says is the review's body.")
            Divider()
            Button("Check Out in a New Worktree…", action: onCheckOut)
            if pr.state == .open {
                Divider()
                ForEach(PullRequestWrite.MergeMethod.allCases) { method in
                    Button(method.title + "…") { onWrite(.merge(number: pr.number, method: method, head: pr.headOid)) }
                }
            }
        } label: {
            Image(systemName: "checkmark.seal").font(.system(size: ChromeMetrics.text(11)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.dimText)
        .help("Review or merge")
        .accessibilityIdentifier("pullRequest.writes")
    }

    // MARK: Content

    private func content(_ detail: PullRequestDetail) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    meta(detail)
                    if !detail.checks.isEmpty { checks(detail) }
                    if !detail.body.isEmpty {
                        card(author: detail.author, date: nil, badge: nil) { markdown(detail.body) }
                    }
                    ForEach(detail.conversation) { item in
                        card(author: item.author, date: item.date, badge: badge(for: item.kind)) {
                            if !item.body.isEmpty { markdown(item.body) }
                        }
                    }
                    if !model.threads.isEmpty {
                        Text(model.threads.count == 1 ? "1 review thread" : "\(model.threads.count) review threads")
                            .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.dimText)
                            .padding(.top, 4)
                        ForEach(model.threads) { thread($0) }
                    }
                }
                .padding(12)
            }
            composer
        }
    }

    private func meta(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: detail.author).foregroundStyle(theme.text)
            Text(verbatim: "\(detail.summary.branch) → \(detail.base)").foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(verbatim: "+\(detail.additions)").foregroundStyle(DiffColors.added)
            Text(verbatim: "−\(detail.deletions)").foregroundStyle(DiffColors.removed)
            Text(verbatim: detail.changedFiles == 1 ? "1 file" : "\(detail.changedFiles) files").foregroundStyle(theme.dimText)
        }
        .font(.system(size: ChromeMetrics.text(11)))
    }

    private func checks(_ detail: PullRequestDetail) -> some View {
        let summary = CheckSummary(detail.checks)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                checksOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: checksOpen ? "chevron.down" : "chevron.right").font(.system(size: ChromeMetrics.text(9))).frame(width: 10)
                    CIGlyph(overall: summary.overall)
                    Text(checksLine(summary)).foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if checksOpen || summary.overall == .failing {
                ForEach(detail.checks.filter { checksOpen || $0.state == .failure }) { check in
                    checkRow(check)
                }
            }
        }
        .font(.system(size: ChromeMetrics.text(12)))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
    }

    /// A check: a failed GitHub Actions job opens its failed step's log
    /// here (GIT-G5), with Re-run (asked) and its page on GitHub beside it;
    /// anything else opens its page.
    @ViewBuilder private func checkRow(_ check: Check) -> some View {
        let job = check.state == .failure ? check.actionsJob : nil
        let log = model.logs[check.name]
        HStack(spacing: 6) {
            Button {
                if job == nil {
                    check.url.map { NSWorkspace.shared.open($0) }
                } else if log == nil {
                    Task { await model.loadLog(of: check) }
                } else {
                    model.closeLog(of: check)
                }
            } label: {
                HStack(spacing: 6) {
                    if job != nil {
                        Image(systemName: log == nil ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(8))).frame(width: 8)
                    }
                    CheckGlyph(state: check.state).frame(width: 12)
                    Text(verbatim: check.name).foregroundStyle(theme.text).lineLimit(1)
                    if let workflow = check.workflow { Text(verbatim: workflow).foregroundStyle(theme.dimText).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job == nil ? (check.url?.absoluteString ?? "") : "Its failed step's log")
            .accessibilityIdentifier("pullRequest.check.\(check.name)")
            if let job {
                iconButton("arrow.counterclockwise", help: "Re-run Failed Jobs…") { onWrite(.rerunFailed(run: job.run)) }
                if let url = check.url { iconButton("safari", help: "Open on GitHub") { NSWorkspace.shared.open(url) } }
            }
        }
        .padding(.leading, 16)
        if let log {
            Group {
                switch log {
                case .loading:
                    ProgressView().controlSize(.small)
                case .loaded(let text):
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: text)
                            .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                            .foregroundStyle(theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(6)
                    }
                    .frame(maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.strip))
                    .accessibilityIdentifier("pullRequest.log.\(check.name)")
                case .failed(let message):
                    Text(verbatim: message).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(DiffColors.removed)
                }
            }
            .padding(.leading, 30)
        }
    }

    private func checksLine(_ summary: CheckSummary) -> String {
        switch summary.overall {
        case .failing: "\(summary.failed) failing, \(summary.passed) passing"
        case .pending: "\(summary.pending) running, \(summary.passed) passing"
        case .passing: summary.passed == 1 ? "1 check passing" : "All \(summary.passed) checks passing"
        case .none: "No checks ran"
        }
    }

    private func thread(_ thread: ReviewThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onOpenFile(thread.path, thread.line)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: ChromeMetrics.text(10)))
                    Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? "\(thread.path) (outdated)")
                        .lineLimit(1).truncationMode(.head)
                }
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.dimText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in the editor")
            if !thread.context.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(thread.context.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") ? DiffColors.added : line.hasPrefix("-") ? DiffColors.removed : theme.dimText)
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.18)))
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    byline(comment.author, comment.date, badge: nil)
                    markdown(comment.body)
                }
            }
            HStack(spacing: 6) {
                TextField(
                    "Reply…", text: Binding(get: { replies[thread.id] ?? "" }, set: { replies[thread.id] = $0 }), axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ChromeMetrics.text(12)))
                .lineLimit(1...5)
                Button("Reply") {
                    let text = replies[thread.id] ?? ""
                    Task {
                        if await model.reply(to: thread, text) { replies[thread.id] = nil }
                    }
                }
                .controlSize(.small)
                .disabled((replies[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.posting)
                Button("Address This Thread") { onAddress(thread) }
                    .controlSize(.small)
                    .help("Type this thread into the checkout's agent — the reviewers' words as data, not instructions")
                    .accessibilityIdentifier("pullRequest.thread.address")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.postError {
                Text(verbatim: error).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(DiffColors.removed)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Comment on this pull request…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: ChromeMetrics.text(12)))
                    .lineLimit(2...8)
                Button("Comment") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.posting)
            }
        }
        .padding(12)
        .background(theme.strip)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private func send() {
        let text = draft
        Task {
            if await model.comment(text) { draft = "" }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(author: String, date: Date?, badge: (String, Color)?, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            byline(author, date, badge: badge)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
    }

    private func byline(_ author: String, _ date: Date?, badge: (String, Color)?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: author).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text)
            if let badge {
                Text(badge.0).font(.system(size: ChromeMetrics.text(10), weight: .medium)).foregroundStyle(badge.1)
            }
            if let date {
                Text(date, format: .relative(presentation: .named)).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText)
            }
        }
    }

    private func badge(for kind: ConversationItem.Kind) -> (String, Color)? {
        switch kind {
        case .comment: nil
        case .review("APPROVED"): ("approved", DiffColors.added)
        case .review("CHANGES_REQUESTED"): ("requested changes", DiffColors.removed)
        case .review: ("reviewed", theme.dimText)
        }
    }

    /// GitHub-flavoured enough: inline markdown (bold, code, links) with
    /// the line breaks kept.
    private func markdown(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return Text(attributed)
            .font(.system(size: ChromeMetrics.text(12)))
            .foregroundStyle(theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText).multilineTextAlignment(.center).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(11))).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

/// open / draft / merged / closed, in GitHub's colours.
package struct StatePill: View {
    package let state: PullRequestSummary.State

    package var body: some View {
        Text(label).font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }

    private var label: String {
        switch state {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    package var color: Color { Self.color(state) }

    package static func color(_ state: PullRequestSummary.State) -> Color {
        switch state {
        case .open: Color(red: 0.14, green: 0.63, blue: 0.29)
        case .draft: Color.gray
        case .merged: TabStatusStyle.merged
        case .closed: Color(red: 0.85, green: 0.27, blue: 0.25)
        }
    }
}

/// CI at a glance: ✓ passing, ✗ failing, ● running.
package struct CIGlyph: View {
    package let overall: CheckSummary.Overall

    package init(overall: CheckSummary.Overall) {
        self.overall = overall
    }

    package var body: some View {
        switch overall {
        case .passing: Image(systemName: "checkmark").foregroundStyle(DiffColors.added)
        case .failing: Image(systemName: "xmark").foregroundStyle(DiffColors.removed)
        case .pending: Image(systemName: "circle.fill").font(.system(size: ChromeMetrics.text(6))).foregroundStyle(TabStatusStyle.signal)
        case .none: EmptyView()
        }
    }
}

private struct CheckGlyph: View {
    let state: Check.State

    var body: some View {
        switch state {
        case .success: Image(systemName: "checkmark").foregroundStyle(DiffColors.added)
        case .failure: Image(systemName: "xmark").foregroundStyle(DiffColors.removed)
        case .pending: Image(systemName: "circle.fill").font(.system(size: ChromeMetrics.text(6))).foregroundStyle(TabStatusStyle.signal)
        case .skipped: Image(systemName: "minus").foregroundStyle(.gray)
        }
    }
}
