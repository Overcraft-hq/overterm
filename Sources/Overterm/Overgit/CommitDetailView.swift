import AppKit
import SwiftUI

/// One commit in the right-hand pane, beside Changes, Pull Request and
/// Usage: what it says, who made it, and what it changed — in the same
/// cards the changes pane draws, without the stage box or Discard.
struct CommitDetailView: View {
    @ObservedObject var model: CommitDetailModel
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    let onOpen: (String) -> Void
    /// The commit in a review tab.
    var onReview: (String) -> Void = { _ in }

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            switch model.phase {
            case .idle:
                note("Pick a commit in Overgit (⌥⌘G).")
            case .loading where model.detail == nil:
                note("Loading…")
            case .failed(let message):
                note(message)
            default:
                body(of: model.detail)
            }
        }
        .background(theme.strip)
    }

    @ViewBuilder private func body(of detail: CommitDetail?) -> some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    message(detail.commit)
                    if detail.files.isEmpty {
                        Text("This commit changed no files.").font(.system(size: 11)).foregroundStyle(theme.dimText)
                    }
                    ForEach(detail.files.prefix(CommitDetailModel.maxFiles)) { file in
                        FileCard(
                            file: file, diff: model.diffs[file.path], collapsed: model.isFolded(file.path),
                            theme: theme, palette: palette,
                            onToggle: { model.toggleFold(file.path) },
                            onOpen: { onOpen(file.path) })
                    }
                    if detail.files.count > CommitDetailModel.maxFiles {
                        Text("Diffs shown for the first \(CommitDetailModel.maxFiles) files.")
                            .font(.system(size: 11)).foregroundStyle(theme.dimText)
                    }
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: model.shortSHA ?? "Commit")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
            if let detail = model.detail {
                Text(verbatim: "+\(detail.added)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DiffColors.added)
                Text(verbatim: "−\(detail.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DiffColors.removed)
                Text(verbatim: "\(detail.files.count) file\(detail.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(theme.dimText)
            }
            Spacer(minLength: 0)
            if let sha = model.detail?.commit.sha {
                Button {
                    onReview(sha)
                } label: {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Review in a tab of its own")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Copy SHA")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close (⌥⌘D)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func message(_ commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: commit.subject)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
            if !commit.body.isEmpty {
                Text(verbatim: commit.body)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(verbatim: commit.author).font(.system(size: 11)).foregroundStyle(theme.text2)
                Text(verbatim: commit.relative).font(.system(size: 11)).foregroundStyle(theme.text3)
                if commit.isMerge {
                    Text("merge").font(.system(size: 10)).foregroundStyle(theme.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(theme.iconBg))
                }
                ForEach(commit.refs) { ref in
                    RefPill(ref: ref, theme: theme)
                }
            }
            if commit.isMerge {
                Text("Shown against its first parent — what the merge brought in.")
                    .font(.system(size: 10)).foregroundStyle(theme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
    }

    private func note(_ text: String) -> some View {
        VStack {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.dimText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }
}
