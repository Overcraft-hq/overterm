import AppKit
import SwiftUI

/// What the review page asks the window to do.
struct ReviewActions {
    /// The file as it is in the checkout, in the editor.
    var openFile: (ReviewModel, ChangedFile) -> Void = { _, _ in }
    var openOnGitHub: (URL) -> Void = { _ in }
}

/// A review's page — a tab of its own, the whole window under the strip:
/// the files on the left, the one picked on the right, side by side or as
/// one column. Keys: j/k file, n/p change, v viewed (`ReviewHostingView`).
struct ReviewPageView: View {
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let actions: ReviewActions

    var body: some View {
        if let review = store.reviews.first(where: { $0.id == store.reviewShowing }) {
            ReviewView(model: review, theme: theme, actions: actions).id(review.id)
        } else {
            Color.clear
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var theme: ChromeTheme
    let actions: ReviewActions

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model, theme: theme, actions: actions)
            Rectangle().fill(theme.border).frame(height: 1)
            switch model.phase {
            case .loading:
                note("Loading…")
            case .failed(let message):
                note(message)
            case .loaded where model.files.isEmpty:
                note("Nothing changed.")
            case .loaded:
                HStack(spacing: 0) {
                    ReviewFileList(model: model, theme: theme)
                        .frame(width: 290)
                    Rectangle().fill(theme.border).frame(width: 1)
                    ReviewFilePane(model: model, theme: theme, actions: actions)
                }
            }
        }
        .background(theme.card)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
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
            Image(systemName: model.source.symbol).font(.system(size: 14)).foregroundStyle(theme.dimText)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dimText)
                    .lineLimit(1)
            }
            if let url = model.pullRequest?.summary.url {
                Button {
                    actions.openOnGitHub(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Open on GitHub")
            }
            Spacer(minLength: 8)
            if model.phase == .loaded, !model.files.isEmpty {
                Text(verbatim: "\(model.viewed.count)/\(model.files.count) viewed")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dimText)
                HStack(spacing: 3) {
                    Text(verbatim: "+\(model.added)").foregroundStyle(DiffColors.added)
                    Text(verbatim: "−\(model.removed)").foregroundStyle(DiffColors.removed)
                }
                .font(.system(size: 11, design: .monospaced))
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
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
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

/// The files, by folder, each with how it changed and whether it is read.
private struct ReviewFileList: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var theme: ChromeTheme

    private var groups: [(folder: String, files: [ChangedFile])] {
        var result: [(String, [ChangedFile])] = []
        for file in model.files {
            let folder = (file.path as NSString).deletingLastPathComponent
            if result.last?.0 == folder {
                result[result.count - 1].1.append(file)
            } else {
                result.append((folder, [file]))
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.folder) { group in
                        if !group.folder.isEmpty {
                            Text(verbatim: group.folder)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.dimText)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.files) { file in
                            ReviewFileRow(
                                file: file, selected: model.selected == file.path, viewed: model.viewed.contains(file.path),
                                indented: !group.folder.isEmpty, theme: theme, select: { model.select(file.path) },
                                toggleViewed: { model.toggleViewed(file.path) }
                            )
                            .id(file.path)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selected) { selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selected) }
            }
        }
    }
}

private struct ReviewFileRow: View {
    let file: ChangedFile
    let selected: Bool
    let viewed: Bool
    let indented: Bool
    @ObservedObject var theme: ChromeTheme
    let select: () -> Void
    let toggleViewed: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleViewed) {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(viewed ? DiffColors.added : theme.dimText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(viewed ? "Viewed — v" : "Mark as Viewed — v")
            Text(verbatim: file.letter)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 10)
            Text(verbatim: (file.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(viewed ? theme.dimText : theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let added = file.added, let removed = file.removed {
                HStack(spacing: 3) {
                    if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(DiffColors.added) }
                    if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(DiffColors.removed) }
                }
                .font(.system(size: 10, design: .monospaced))
                .opacity(viewed ? 0.6 : 1)
            }
        }
        .padding(.leading, indented ? 18 : 12)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.selected : (hovering ? theme.hover : .clear)).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    private var color: Color {
        switch file.kind {
        case .added, .untracked: DiffColors.added
        case .deleted: DiffColors.removed
        case .renamed: .blue
        default: .orange
        }
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
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                model.toggleViewed(file.path)
            } label: {
                Label("Viewed", systemImage: model.viewed.contains(file.path) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.viewed.contains(file.path) ? theme.text : theme.dimText)
            .help("Mark as Viewed — v")
            Button {
                actions.openFile(model, file)
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Editor")
            .disabled(file.kind == .deleted)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    @ViewBuilder private func content(_ file: ChangedFile) -> some View {
        if let diff = model.diffs[file.path] {
            if diff.lines.isEmpty {
                note(file.kind == .renamed ? "Renamed, content unchanged." : "No textual diff (binary or empty).")
            } else {
                ReviewDiffView(diff: diff, layout: model.layout, target: model.scrollTarget, rows: model.rows[file.path] ?? [], theme: theme)
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
            .font(.system(size: 12))
            .foregroundStyle(theme.dimText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        let palette = palette
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a file at the cap is twenty thousand lines.
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch layout {
                    case .unified:
                        ForEach(diff.lines) { line in
                            DiffLineView(line: line, style: diff.style(of: line), palette: palette, theme: theme).equatable().id(line.id)
                        }
                    case .split:
                        ForEach(rows) { row in
                            SplitRowView(row: row, diff: diff, palette: palette, theme: theme).id(row.id)
                        }
                    }
                    if diff.truncated {
                        Text("Diff truncated.").font(.system(size: 11)).foregroundStyle(theme.dimText).padding(8)
                    }
                }
                .padding(.vertical, 4)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
            .onChange(of: target) { target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.2))
            }
        }
    }
}

/// One row side by side: the old line on the left, the new on the right,
/// each half its own colour; a hunk's header across both.
private struct SplitRowView: View {
    let row: SplitDiff.Row
    let diff: DiffModel.FileDiff
    let palette: DiffPalette
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let full = row.full {
            Text(verbatim: full.text)
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .background(full.kind == .hunk ? theme.selected.opacity(0.6) : .clear)
        } else {
            HStack(alignment: .top, spacing: 0) {
                half(row.left, number: row.left?.oldNumber, side: .removed)
                Rectangle().fill(theme.border).frame(width: 1)
                half(row.right, number: row.right?.newNumber, side: .added)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func half(_ line: DiffLine?, number: Int?, side: DiffLine.Kind) -> some View {
        let changed = line?.kind == side
        let tint = side == .added ? DiffColors.added : DiffColors.removed
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundStyle(theme.dimText.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)
            text(line)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: .infinity, alignment: .topLeading)
        .background(line == nil ? theme.selected.opacity(0.25) : (changed ? tint.opacity(0.14) : .clear))
        .overlay(alignment: .leading) { Rectangle().fill(changed ? tint : .clear).frame(width: 3) }
    }

    private func text(_ line: DiffLine?) -> Text {
        guard let line, !line.text.isEmpty else { return Text(verbatim: " ") }
        let style = diff.style(of: line)
        if style.isEmpty { return Text(verbatim: line.text) }
        return Text(palette.text(line, style))
    }
}

/// The review page's host: the page's keys, when nothing in it took them.
final class ReviewHostingView: NSHostingView<ReviewPageView> {
    var review: () -> ReviewModel? = { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, let review = review(), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.keyDown(with: event)
        }
        switch key {
        case "j": review.selectFile(by: 1)
        case "k": review.selectFile(by: -1)
        case "n": review.moveToChange(by: 1)
        case "p": review.moveToChange(by: -1)
        case "v": review.toggleViewed()
        default: super.keyDown(with: event)
        }
    }
}
