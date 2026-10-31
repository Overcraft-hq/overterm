import AppKit
import SwiftUI

/// The Pull Request pane: the checkout's PR — state, checks, description,
/// conversation, review threads by file and line — with a comment box and
/// a reply box per thread.
struct PullRequestView: View {
    @ObservedObject var model: PullRequestModel
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    /// A thread's file, at its line, in the editor.
    let onOpenFile: (String, Int?) -> Void
    /// The pull request's changes in a review tab.
    var onReview: (Int) -> Void = { _ in }
    @State private var draft = ""
    @State private var replies: [Int: String] = [:]
    @State private var checksOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.picked != nil { pickedBar }
            Divider().opacity(0.4)
            switch model.phase {
            case .idle,
                .loading where model.detail == nil:
                placeholder("Loading pull request…")
            case .none:
                placeholder(model.branch.map { "No pull request for \($0)." } ?? "Not on a branch.")
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
            Image(systemName: "pin").font(.system(size: 10))
            Text(verbatim: model.detail.map { "\($0.summary.branch)" } ?? "Picked in Overgit")
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(model.branch.map { "Show \($0)’s" } ?? "Show this branch’s") { model.unpick() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pr.title)
            } else {
                Text("Pull Request").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
            if model.phase == .loading { ProgressView().controlSize(.small) }
            if let number = model.detail?.summary.number {
                iconButton("rectangle.split.2x1", help: "Review Changes") { onReview(number) }
            }
            if let url = model.detail?.summary.url {
                iconButton("safari", help: "Open on GitHub") { NSWorkspace.shared.open(url) }
            }
            iconButton("arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            iconButton("xmark", help: "Close (⌥⌘D)", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
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
                            .font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.dimText)
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
        .font(.system(size: 11))
    }

    private func checks(_ detail: PullRequestDetail) -> some View {
        let summary = CheckSummary(detail.checks)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                checksOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: checksOpen ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                    CIGlyph(overall: summary.overall)
                    Text(checksLine(summary)).foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if checksOpen || summary.overall == .failing {
                ForEach(detail.checks.filter { checksOpen || $0.state == .failure }) { check in
                    Button {
                        check.url.map { NSWorkspace.shared.open($0) }
                    } label: {
                        HStack(spacing: 6) {
                            CheckGlyph(state: check.state).frame(width: 12)
                            Text(verbatim: check.name).foregroundStyle(theme.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(check.url?.absoluteString ?? "")
                }
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
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
                    Image(systemName: "doc.text").font(.system(size: 10))
                    Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? "\(thread.path) (outdated)")
                        .lineLimit(1).truncationMode(.head)
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.dimText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in the editor")
            if !thread.context.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(thread.context.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 12))
                .lineLimit(1...5)
                Button("Reply") {
                    let text = replies[thread.id] ?? ""
                    Task {
                        if await model.reply(to: thread, text) { replies[thread.id] = nil }
                    }
                }
                .controlSize(.small)
                .disabled((replies[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.posting)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.postError {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(DiffColors.removed)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Comment on this pull request…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
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
            Text(verbatim: author).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
            if let badge {
                Text(badge.0).font(.system(size: 10, weight: .medium)).foregroundStyle(badge.1)
            }
            if let date {
                Text(date, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(theme.dimText)
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
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.dimText).multilineTextAlignment(.center).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

/// open / draft / merged / closed, in GitHub's colours.
struct StatePill: View {
    let state: PullRequestSummary.State

    var body: some View {
        Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
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

    var color: Color { Self.color(state) }

    static func color(_ state: PullRequestSummary.State) -> Color {
        switch state {
        case .open: Color(red: 0.14, green: 0.63, blue: 0.29)
        case .draft: Color.gray
        case .merged: TabStatusStyle.merged
        case .closed: Color(red: 0.85, green: 0.27, blue: 0.25)
        }
    }
}

/// CI at a glance: ✓ passing, ✗ failing, ● running.
struct CIGlyph: View {
    let overall: CheckSummary.Overall

    var body: some View {
        switch overall {
        case .passing: Image(systemName: "checkmark").foregroundStyle(DiffColors.added)
        case .failing: Image(systemName: "xmark").foregroundStyle(DiffColors.removed)
        case .pending: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(TabStatusStyle.signal)
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
        case .pending: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(TabStatusStyle.signal)
        case .skipped: Image(systemName: "minus").foregroundStyle(.gray)
        }
    }
}
