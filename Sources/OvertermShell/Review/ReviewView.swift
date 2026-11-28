import AppKit
import SwiftUI

/// What the review page asks the window to do.
package struct ReviewActions {
    /// The file as it is in the checkout, in the editor.
    package var openFile: (ReviewModel, ChangedFile) -> Void = { _, _ in }
    package var openOnGitHub: (URL) -> Void = { _ in }
    /// The notes, as one brief, to the checkout's agent (GIT-N2).
    package var sendNotes: (ReviewModel) -> Void = { _ in }
    /// Who Send names: the checkout's agent, if it has one tab of them.
    package var noteRecipient: (ReviewModel) -> String? = { _ in nil }
    /// The picked lines to Ask Agent's sheet (⌘L).
    package var askAboutLines: (ReviewModel) -> Void = { _ in }
    /// A thread drawn at its line, to the checkout's agent (Address This Thread).
    package var addressThread: (ReviewModel, ReviewThread) -> Void = { _, _ in }
    /// The comments kept, posted with a decision as one review — asked first (GIT-G3).
    package var submitReview: (ReviewModel) -> Void = { _ in }
    package var terraform = TerraformReviewActions()
}

/// A review's page — a tab of its own, the whole window under the strip:
/// the files on the left, the one picked on the right, side by side or as
/// one column. Keys: j/k file, n/p change, v viewed (`ReviewHostingView`).
package struct ReviewPageView: View {
    @ObservedObject package var store: TabStore
    @ObservedObject package var theme: ChromeTheme
    package let actions: ReviewActions

    package var body: some View {
        if let review = store.reviews.first(where: { $0.id == store.reviewShowing }) {
            ReviewView(model: review, theme: theme, actions: actions).id(review.id)
        } else {
            Color.clear
        }
    }
}

package struct ReviewView: View {
    @ObservedObject package var model: ReviewModel
    @ObservedObject package var theme: ChromeTheme
    @ObservedObject var keybindings = Keybindings.shared
    package let actions: ReviewActions

    package var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model, theme: theme, actions: actions)
            Rectangle().fill(theme.border).frame(height: 1)
            TerraformReviewSectionView(review: model, model: model.terraform, theme: theme, actions: actions.terraform)
            switch model.phase {
            case .loading:
                note("Loading…")
            case .failed(let message):
                note(message)
            case .loaded where model.files.isEmpty:
                note("Nothing changed.")
            case .loaded:
                HStack(spacing: 0) {
                    ReviewFileTable(
                        rows: model.listRows, selected: model.selected, viewed: model.viewed, theme: theme,
                        select: { model.select($0) }, toggleViewed: { model.toggleViewed($0) }
                    )
                    .frame(width: 290)
                    Rectangle().fill(theme.border).frame(width: 1)
                    ReviewFilePane(model: model, theme: theme, actions: actions)
                }
                ReviewNotesBar(model: model, theme: theme, actions: actions)
            }
        }
        .background(theme.card)
        .overlay {
            if model.showsKeys {
                ZStack {
                    Color.black.opacity(0.001).onTapGesture { model.showsKeys = false }
                    KeySheetView(
                        theme: theme, title: "Keys in the review", groups: ReviewKey.groups { keybindings.key(for: $0)?.display },
                        identifier: "review.keys"
                    ) { model.showsKeys = false }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: ChromeMetrics.text(12)))
            .foregroundStyle(theme.dimText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What is under review, its size, and Split / Unified.
private struct ReviewHeader: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var theme: ChromeTheme
    let actions: ReviewActions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.source.symbol).font(.system(size: ChromeMetrics.text(14))).foregroundStyle(theme.dimText)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.title)
                    .font(.system(size: ChromeMetrics.text(14), weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.dimText)
                    .lineLimit(1)
            }
            if let url = model.pullRequest?.summary.url {
                Button {
                    actions.openOnGitHub(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: ChromeMetrics.text(12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Open on GitHub")
            }
            Spacer(minLength: 8)
            if model.phase == .loaded, !model.files.isEmpty {
                Text(verbatim: "\(model.viewed.count)/\(model.files.count) viewed")
                    .font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.dimText)
                HStack(spacing: 3) {
                    Text(verbatim: "+\(model.added)").foregroundStyle(DiffColors.added)
                    Text(verbatim: "−\(model.removed)").foregroundStyle(DiffColors.removed)
                }
                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
            }
            Picker("", selection: $model.layout) {
                Text("Split").tag(ReviewModel.Layout.split)
                Text("Unified").tag(ReviewModel.Layout.unified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("review.layout")
            Button {
                model.showsKeys.toggle()
            } label: {
                Image(systemName: "keyboard").font(.system(size: ChromeMetrics.text(12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Keys — ?")
            .accessibilityIdentifier("review.keysButton")
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: ChromeMetrics.text(12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Reload")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var subtitle: String {
        guard let pr = model.pullRequest else { return model.source.subtitle }
        var parts = ["\(pr.author) wants to merge \(pr.summary.branch) into \(pr.base)"]
        switch pr.summary.checks.overall {
        case .failing: parts.append("checks failing")
        case .pending: parts.append("checks running")
        case .passing: parts.append("checks passed")
        case .none: break
        }
        return parts.joined(separator: " · ")
    }
}

/// The picked file: its header, then its diff in the layout picked.
private struct ReviewFilePane: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var theme: ChromeTheme
    let actions: ReviewActions

    var body: some View {
        if let file = model.selectedFile {
            VStack(spacing: 0) {
                header(file)
                Rectangle().fill(theme.border).frame(height: 1)
                content(file)
            }
        } else {
            Color.clear
        }
    }

    private func header(_ file: ChangedFile) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                model.toggleViewed(file.path)
            } label: {
                Label("Viewed", systemImage: model.viewed.contains(file.path) ? "checkmark.square.fill" : "square")
                    .font(.system(size: ChromeMetrics.text(11)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.viewed.contains(file.path) ? theme.text : theme.dimText)
            .help("Mark as Viewed — v")
            Button {
                actions.openFile(model, file)
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: ChromeMetrics.text(12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Editor")
            .disabled(file.kind == .deleted)
        }
        .padding(.horizontal, 14)
        .frame(height: ChromeMetrics.row(34))
    }

    @ViewBuilder private func content(_ file: ChangedFile) -> some View {
        if let diff = model.diffs[file.path] {
            if diff.lines.isEmpty {
                note(file.kind == .renamed ? "Renamed, content unchanged." : "No textual diff (binary or empty).")
            } else {
                ReviewDiffView(
                    diff: diff, layout: model.layout, target: model.scrollTarget, rows: model.rows[file.path] ?? [], theme: theme,
                    fraction: $model.splitFraction, selection: model.lineSelection?.path == file.path ? model.lineSelection : nil,
                    threads: model.placedThreads[file.path] ?? [:], address: { [weak model] thread in model.map { actions.addressThread($0, thread) } },
                    openURL: actions.openOnGitHub,
                    pick: { [weak model] id, extending in model?.pickLine(id, extending: extending) }
                )
                .id(file.path)
            }
        } else if let failure = model.failures[file.path] {
            note(failure)
        } else {
            note("Loading…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: ChromeMetrics.text(12)))
            .foregroundStyle(theme.dimText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Under the diff: the lines picked — a note for them, Copy, Ask — and
/// the notes written so far, sent to the checkout's agent as one brief.
/// Nothing while there is neither.
private struct ReviewNotesBar: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var theme: ChromeTheme
    /// The keys it names, as bound now.
    @ObservedObject var keys = Keybindings.shared
    let actions: ReviewActions
    @FocusState private var writing: Bool

    var body: some View {
        if model.lineSelection != nil || !model.notes.isEmpty || !model.drafts.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(theme.border).frame(height: 1)
                if let selection = model.lineSelection { picked(selection) }
                if let problem = model.draftProblem {
                    Text(verbatim: problem).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(DiffColors.removed).padding(.horizontal, 14)
                        .accessibilityIdentifier("review.comments.problem")
                }
                if !model.drafts.isEmpty { drafts }
                if !model.notes.isEmpty { notes }
            }
            .font(.system(size: ChromeMetrics.text(12)))
        }
    }

    private func picked(_ selection: ReviewLineSelection) -> some View {
        let lines = model.selectedLines
        return HStack(spacing: 8) {
            Text(verbatim: "\((selection.path as NSString).lastPathComponent), \(ReviewNotes.span(lines))")
                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .accessibilityIdentifier("review.notes.picked")
            TextField("Note for the agent — what should change here?", text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .focused($writing)
                .onSubmit { model.addNote() }
                .accessibilityIdentifier("review.notes.field")
            if model.pullRequestNumber != nil {
                Button("Comment on GitHub") { model.addDraftComment() }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Kept for your review: it goes to GitHub with Submit Review, with a decision, asked first")
                    .accessibilityIdentifier("review.comments.add")
            }
            Button("Add Note") { model.addNote() }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("review.notes.add")
            Button("Copy") {
                guard let text = model.copyText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .help(KeyHints.text("Copy the picked lines — %@", command: "edit.copy", keys: keys) ?? "Copy the picked lines")
            .accessibilityIdentifier("review.notes.copy")
            Button("Ask an Agent…") { actions.askAboutLines(model) }
                .help(KeyHints.text("Ask an agent about these lines — %@", command: "agents.askSelection", keys: keys) ?? "Ask an agent about these lines")
            Button {
                model.clearLineSelection()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Unpick — Esc")
        }
        .padding(.horizontal, 14)
        .frame(height: ChromeMetrics.row(40))
    }

    /// The comments kept for the pull request's review (GIT-G3).
    private var drafts: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.drafts) { comment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "text.bubble").foregroundStyle(theme.dimText)
                            Text(verbatim: "\(comment.path), \(comment.span)")
                                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                                .foregroundStyle(theme.dimText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(verbatim: comment.body).foregroundStyle(theme.text).lineLimit(2)
                            Spacer(minLength: 4)
                            Button {
                                model.removeDraftComment(comment.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.dimText)
                            .help("Remove this comment")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 110)
            HStack(spacing: 8) {
                Text(verbatim: model.drafts.count == 1 ? "1 comment for GitHub" : "\(model.drafts.count) comments for GitHub")
                    .foregroundStyle(theme.dimText)
                    .accessibilityIdentifier("review.comments.count")
                Spacer()
                Button("Discard") { model.clearDraftComments() }
                Button("Submit Review…") { actions.submitReview(model) }
                    .help("Post the comments as one review — Comment, Approve or Request Changes — asked first")
                    .accessibilityIdentifier("review.comments.submit")
            }
            .padding(.horizontal, 14)
            .frame(height: ChromeMetrics.row(36))
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.notes) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(note.path), \(note.span)")
                                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                                .foregroundStyle(theme.dimText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(verbatim: note.text).foregroundStyle(theme.text).lineLimit(2)
                            Spacer(minLength: 4)
                            Button {
                                model.removeNote(note.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.dimText)
                            .help("Remove this note")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 110)
            HStack(spacing: 8) {
                Text(verbatim: model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
                    .foregroundStyle(theme.dimText)
                    .accessibilityIdentifier("review.notes.count")
                Spacer()
                Button("Clear") { model.clearNotes() }
                Button(actions.noteRecipient(model).map { "Send to \($0)" } ?? "Send to Agent…") { actions.sendNotes(model) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Type the notes into the checkout's agent, as one message — Return is yours to press")
                    .accessibilityIdentifier("review.notes.send")
            }
            .padding(.horizontal, 14)
            .frame(height: ChromeMetrics.row(36))
        }
    }
}

/// A diff's lines or rows with the threads after the line each is on.
private enum ReviewThreadItems {
    enum Unified: Identifiable {
        case line(DiffLine)
        case threads(after: Int, [ReviewThread])
        var id: Int {
            switch self {
            case .line(let line): line.id
            case .threads(let after, _): -1 - after
            }
        }
    }

    enum Split: Identifiable {
        case row(SplitDiff.Row)
        case threads(after: Int, [ReviewThread])
        var id: Int {
            switch self {
            case .row(let row): row.id
            case .threads(let after, _): -1 - after
            }
        }
    }

    static func unified(_ lines: [DiffLine], _ threads: [Int: [ReviewThread]]) -> [Unified] {
        lines.flatMap { line -> [Unified] in
            guard let here = threads[line.id] else { return [.line(line)] }
            return [.line(line), .threads(after: line.id, here)]
        }
    }

    static func split(_ rows: [SplitDiff.Row], _ threads: [Int: [ReviewThread]]) -> [Split] {
        rows.flatMap { row -> [Split] in
            let here = [row.left?.id, row.right?.id].compactMap { $0 }.reduce(into: [ReviewThread]()) { found, id in
                for thread in threads[id] ?? [] where !found.contains(where: { $0.id == thread.id }) { found.append(thread) }
            }
            return here.isEmpty ? [.row(row)] : [.row(row), .threads(after: row.id, here)]
        }
    }
}

/// A pull request's threads under the line they are on: who said what,
/// Open on GitHub, Address This Thread.
private struct ReviewThreadsView: View {
    let threads: [ReviewThread]
    @ObservedObject var theme: ChromeTheme
    let address: (ReviewThread) -> Void
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(threads) { thread in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(thread.comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: comment.author).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text)
                            Text(verbatim: comment.body).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(10)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Address This Thread") { address(thread) }
                            .help("Type this thread into the checkout's agent — the reviewers' words as data, not instructions")
                        if let url = thread.url { Button("Open on GitHub") { openURL(url) } }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: ChromeMetrics.text(11)))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.5)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("review.thread")
            }
        }
        .font(.system(size: ChromeMetrics.text(12)))
        .padding(.horizontal, 48)
        .padding(.vertical, 6)
    }
}

/// A file's diff, as one column or side by side, scrolled to the change
/// `n`/`p` picked.
private struct ReviewDiffView: View {
    let diff: DiffModel.FileDiff
    let layout: ReviewModel.Layout
    let target: Int?
    let rows: [SplitDiff.Row]
    @ObservedObject var theme: ChromeTheme
    /// The old side's share of the width (ReviewModel.splitFraction).
    @Binding var fraction: CGFloat
    /// The lines picked in this file.
    let selection: ReviewLineSelection?
    /// A pull request's threads by the line they are drawn under (GIT-G3).
    let threads: [Int: [ReviewThread]]
    let address: (ReviewThread) -> Void
    let openURL: (URL) -> Void
    let pick: (Int, Bool) -> Void
    /// The fraction as a drag began.
    @State private var dragStart: CGFloat?

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        GeometryReader { geometry in
            let left = (geometry.size.width * fraction).rounded()
            content(left: layout == .split ? left : nil)
                .overlay(alignment: .topLeading) {
                    if layout == .split { divider(at: left, width: geometry.size.width) }
                }
        }
    }

    /// A band over the 1 pt line between the sides, the whole height: drag
    /// it, or double-click it for half and half.
    private func divider(at x: CGFloat, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: x - 4)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? fraction
                        if dragStart == nil { dragStart = start }
                        guard width > 0 else { return }
                        let moved = start + drag.translation.width / width
                        fraction = min(max(moved, ReviewModel.splitRange.lowerBound), ReviewModel.splitRange.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { fraction = 0.5 }
            .help("Drag to resize the sides; double-click for half and half")
            .accessibilityIdentifier("reviewSplitDivider")
    }

    private func content(left: CGFloat?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Threads between the lines in a stack of their own: a file
                // with none keeps the plain list as it was (its scroll is
                // measured, and a deeper choice inside the lazy stack cost
                // a millisecond a step).
                if threads.isEmpty { plain(left: left) } else { threaded(left: left) }
                // No .textSelection: it cost 40% of every scroll step (a
                // 3,000-line file side by side, 17 ms a step → 10.5 ms).
                // Lines are picked by their numbers instead, and copied
                // from the pick (⌘C).
            }
            .onChange(of: target) { target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.2))
            }
        }
    }

    private func plain(left: CGFloat?) -> some View {
        let palette = palette
        // Lazy: a file at the cap is twenty thousand lines.
        return LazyVStack(alignment: .leading, spacing: 0) {
            switch layout {
            case .unified:
                ForEach(diff.lines) { line in
                    DiffLineView(
                        line: line, style: diff.style(of: line), palette: palette, theme: theme, picked: selection?.contains(line.id) == true,
                        onNumber: { pick(line.id, $0) }
                    )
                    .equatable()
                    .id(line.id)
                }
            case .split:
                let colors = ReviewRowColors(theme)
                ForEach(rows) { row in
                    SplitRowView(
                        row: row, left: row.left.map(diff.style(of:)) ?? DiffLineStyle(),
                        right: row.right.map(diff.style(of:)) ?? DiffLineStyle(), palette: palette, colors: colors,
                        leftWidth: left, leftPicked: selection?.contains(row.left?.id) == true,
                        rightPicked: selection?.contains(row.right?.id) == true, pick: pick
                    )
                    .equatable()
                    .id(row.id)
                }
            }
            if diff.truncated { truncatedNote }
        }
        .padding(.vertical, 4)
        .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
    }

    private func threaded(left: CGFloat?) -> some View {
        let palette = palette
        return LazyVStack(alignment: .leading, spacing: 0) {
            switch layout {
            case .unified:
                ForEach(ReviewThreadItems.unified(diff.lines, threads)) { item in
                    switch item {
                    case .line(let line):
                        DiffLineView(
                            line: line, style: diff.style(of: line), palette: palette, theme: theme,
                            picked: selection?.contains(line.id) == true, onNumber: { pick(line.id, $0) }
                        )
                        .equatable()
                        .id(line.id)
                    case .threads(_, let threads):
                        ReviewThreadsView(threads: threads, theme: theme, address: address, openURL: openURL)
                    }
                }
            case .split:
                let colors = ReviewRowColors(theme)
                ForEach(ReviewThreadItems.split(rows, threads)) { item in
                    switch item {
                    case .row(let row):
                        SplitRowView(
                            row: row, left: row.left.map(diff.style(of:)) ?? DiffLineStyle(),
                            right: row.right.map(diff.style(of:)) ?? DiffLineStyle(), palette: palette, colors: colors,
                            leftWidth: left, leftPicked: selection?.contains(row.left?.id) == true,
                            rightPicked: selection?.contains(row.right?.id) == true, pick: pick
                        )
                        .equatable()
                        .id(row.id)
                    case .threads(_, let threads):
                        ReviewThreadsView(threads: threads, theme: theme, address: address, openURL: openURL)
                    }
                }
            }
            if diff.truncated { truncatedNote }
        }
        .padding(.vertical, 4)
        .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
    }

    private var truncatedNote: some View {
        Text("Diff truncated.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(8)
    }
}

/// The colours a diff row is drawn in, read once from the chrome — rows
/// hold these, not the theme: a row observing the theme was one more
/// thing to check on every row for every step of a scroll.
package struct ReviewRowColors: Equatable {
    package var text: Color
    package var dim: Color
    package var border: Color
    package var empty: Color
    package var hunk: Color
    /// A picked line's.
    package var picked: Color

    @MainActor package init(_ theme: ChromeTheme) {
        text = theme.text
        dim = theme.dimText
        border = theme.border
        empty = theme.selected.opacity(0.25)
        hunk = theme.selected.opacity(0.6)
        picked = Color.accentColor.opacity(0.28)
    }
}

/// One row side by side: the old line on the left, the new on the right,
/// each half its own colour; a hunk's header across both. Equatable: a
/// row is drawn again only when it or its colours change.
private struct SplitRowView: View, Equatable {
    let row: SplitDiff.Row
    let left: DiffLineStyle
    let right: DiffLineStyle
    let palette: DiffPalette
    let colors: ReviewRowColors
    /// The old side's width, the divider's place (nil: half each).
    let leftWidth: CGFloat?
    /// Each half's line picked.
    let leftPicked: Bool
    let rightPicked: Bool
    /// A click on a half's number: its line, and whether ⇧ was down.
    let pick: (Int, Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.left == b.left && a.right == b.right && a.colors == b.colors && a.leftWidth == b.leftWidth
            && a.leftPicked == b.leftPicked && a.rightPicked == b.rightPicked
    }

    var body: some View {
        if let full = row.full {
            Text(verbatim: full.text)
                .foregroundStyle(colors.dim)
                .lineLimit(1)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .background(full.kind == .hunk ? colors.hunk : .clear)
        } else {
            HStack(alignment: .top, spacing: 0) {
                half(row.left, style: left, number: row.left?.oldNumber, side: .removed, picked: leftPicked)
                    .frame(width: leftWidth.map { max(0, $0 - 0.5) })
                colors.border.frame(width: 1)
                half(row.right, style: right, number: row.right?.newNumber, side: .added, picked: rightPicked)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func half(_ line: DiffLine?, style: DiffLineStyle, number: Int?, side: DiffLine.Kind, picked: Bool) -> some View {
        let changed = line?.kind == side
        let tint = side == .added ? DiffColors.added : DiffColors.removed
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundStyle(colors.dim.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let line { pick(line.id, NSEvent.modifierFlags.contains(.shift)) }
                }
            text(line, style)
                .foregroundStyle(colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: .infinity, alignment: .topLeading)
        .background(picked ? colors.picked : line == nil ? colors.empty : (changed ? tint.opacity(0.14) : .clear))
        .overlay(alignment: .leading) {
            if picked { Color.accentColor.frame(width: 3) } else if changed { tint.frame(width: 3) }
        }
    }

    private func text(_ line: DiffLine?, _ style: DiffLineStyle) -> Text {
        guard let line, !line.text.isEmpty else { return Text(verbatim: " ") }
        if style.isEmpty { return Text(verbatim: line.text) }
        return Text(palette.text(line, style))
    }
}

/// The review page's host: the page's keys, when nothing in it took them.
package final class ReviewHostingView: NSHostingView<ReviewPageView> {
    package var review: () -> ReviewModel? = { nil }

    /// ⌘C: the picked lines, as the file has them.
    @objc package func copy(_ sender: Any?) {
        guard let text = review()?.copyText else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    package override var acceptsFirstResponder: Bool { true }
    /// A press in a window not in front acts at once — the divider between
    /// the sides drags on the first one, as the terminal's dividers do.
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    package override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, let review = review(), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.keyDown(with: event)
        }
        if review.showsKeys {
            review.showsKeys = false
            return
        }
        if key == "\u{1b}", review.lineSelection != nil { return review.clearLineSelection() }
        switch ReviewKey.of(event.characters ?? key) {
        case .nextFile: review.selectFile(by: 1)
        case .previousFile: review.selectFile(by: -1)
        case .nextChange: review.moveToChange(by: 1)
        case .previousChange: review.moveToChange(by: -1)
        case .viewed: review.toggleViewed()
        case .help: review.showsKeys = true
        case nil: super.keyDown(with: event)
        }
    }
}
