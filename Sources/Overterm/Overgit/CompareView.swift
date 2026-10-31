import SwiftUI

/// The comparison in the right-hand pane: the two sides, the commits on
/// each, and every file `head` changed since they parted.
struct CompareView: View {
    @ObservedObject var model: CompareModel
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    let onCommit: (Commit) -> Void
    let onOpen: (String) -> Void
    /// The comparison in a review tab.
    var onReview: (_ base: String, _ head: String) -> Void = { _, _ in }
    @State private var behindOpen = false

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            switch model.phase {
            case .idle:
                note("Pick two in Overgit: a branch, tag or commit's menu ▸ Compare.")
            case .loading where model.files.isEmpty:
                note("Comparing…")
            case .failed(let message):
                note(message)
            default:
                content
            }
        }
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 6) {
            side(model.base ?? "—")
            Image(systemName: "arrow.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.dimText)
            side(model.head ?? "—")
            Button {
                model.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Swap the two")
            Spacer(minLength: 0)
            if let base = model.base, let head = model.head {
                Button {
                    onReview(base, head)
                } label: {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Review in a tab of its own")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func side(_ name: String) -> some View {
        Text(verbatim: name)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.iconBg))
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                summary
                if !model.ahead.isEmpty {
                    commitList(
                        "\(model.aheadCount) commit\(model.aheadCount == 1 ? "" : "s") in \(model.head ?? "") not in \(model.base ?? "")",
                        model.ahead)
                }
                if model.behindCount > 0 {
                    Button {
                        behindOpen.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: behindOpen ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                            Text(verbatim: "\(model.behindCount) in \(model.base ?? "") not in \(model.head ?? "")")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dimText)
                    }
                    .buttonStyle(.plain)
                    if behindOpen { commitList(nil, model.behind) }
                }
                if model.files.isEmpty {
                    Text("No file differs.").font(.system(size: 11)).foregroundStyle(theme.dimText)
                }
                ForEach(model.files.prefix(CompareModel.maxFiles)) { file in
                    FileCard(
                        file: file, diff: model.diffs[file.path], collapsed: model.isFolded(file.path), theme: theme, palette: palette,
                        onToggle: { model.toggleFold(file.path) }, onOpen: { onOpen(file.path) })
                }
                if model.files.count > CompareModel.maxFiles {
                    Text("Diffs shown for the first \(CompareModel.maxFiles) files.").font(.system(size: 11)).foregroundStyle(theme.dimText)
                }
            }
            .padding(12)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Label {
                Text(verbatim: "\(model.aheadCount)")
            } icon: {
                Image(systemName: "arrow.up")
            }
            .help("Commits only in \(model.head ?? "")")
            Label {
                Text(verbatim: "\(model.behindCount)")
            } icon: {
                Image(systemName: "arrow.down")
            }
            .help("Commits only in \(model.base ?? "")")
            Text(verbatim: "\(model.files.count) file\(model.files.count == 1 ? "" : "s")").foregroundStyle(theme.dimText)
            Text(verbatim: "+\(model.added)").foregroundStyle(DiffColors.added)
            Text(verbatim: "−\(model.removed)").foregroundStyle(DiffColors.removed)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(theme.text2)
    }

    private func commitList(_ title: String?, _ commits: [Commit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2).padding(.bottom, 2)
            }
            ForEach(commits) { commit in
                CommitRowView(commit: commit, row: nil, lanes: 0, isSelected: false, theme: theme, onOpen: { onCommit(commit) })
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.35)))
    }

    private func note(_ text: String) -> some View {
        VStack {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.dimText).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }
}

/// "Compare" in a branch's, tag's or commit's menu: with the checkout's
/// branch, or — one picked first — with that one.
struct CompareMenuItems: View {
    let ref: String
    @ObservedObject var model: OvergitModel
    let actions: OvergitActions

    var body: some View {
        Divider()
        Button("Compare with Current Branch") { actions.compare("HEAD", ref) }
        if let picked = model.compareBase, picked != ref {
            Button("Compare with “\(picked)”") {
                actions.compare(picked, ref)
                model.compareBase = nil
            }
        }
        Button("Select for Compare") { model.compareBase = ref }
    }
}

/// A commit's review items: it alone, or the run from a commit picked
/// before to it.
struct ReviewMenuItems: View {
    let commit: Commit
    @ObservedObject var model: OvergitModel
    let actions: OvergitActions

    var body: some View {
        Divider()
        Button("Review Commit") { actions.reviewCommits(commit.sha, commit.sha) }
        if let start = model.reviewStart, start.sha != commit.sha {
            Button("Review Commits \(start.shortSHA)…\(commit.shortSHA)") {
                actions.reviewCommits(start.sha, commit.sha)
                model.reviewStart = nil
            }
        }
        Button("Select as Start of Review") { model.reviewStart = commit }
    }
}
