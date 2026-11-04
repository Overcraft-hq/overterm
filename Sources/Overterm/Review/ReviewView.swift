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
                    ReviewFileTable(
                        rows: model.listRows, selected: model.selected, viewed: model.viewed, theme: theme,
                        select: { model.select($0) }, toggleViewed: { model.toggleViewed($0) }
                    )
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
                    fraction: $model.splitFraction
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
        let palette = palette
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a file at the cap is twenty thousand lines.
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch layout {
                    case .unified:
                        ForEach(diff.lines) { line in
                            DiffLineView(line: line, style: diff.style(of: line), palette: palette, theme: theme).equatable().id(line.id)
                        }
                    case .split:
                        let colors = ReviewRowColors(theme)
                        ForEach(rows) { row in
                            SplitRowView(
                                row: row, left: row.left.map(diff.style(of:)) ?? DiffLineStyle(),
                                right: row.right.map(diff.style(of:)) ?? DiffLineStyle(), palette: palette, colors: colors,
                                leftWidth: left
                            )
                            .equatable()
                            .id(row.id)
                        }
                    }
                    if diff.truncated {
                        Text("Diff truncated.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(8)
                    }
                }
                .padding(.vertical, 4)
                .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                // No .textSelection: it cost 40% of every scroll step (a
                // 3,000-line file side by side, 17 ms a step → 10.5 ms).
                // Open in Editor is where a line is copied from.
            }
            .onChange(of: target) { target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.2))
            }
        }
    }
}

/// The colours a diff row is drawn in, read once from the chrome — rows
/// hold these, not the theme: a row observing the theme was one more
/// thing to check on every row for every step of a scroll.
struct ReviewRowColors: Equatable {
    var text: Color
    var dim: Color
    var border: Color
    var empty: Color
    var hunk: Color

    @MainActor init(_ theme: ChromeTheme) {
        text = theme.text
        dim = theme.dimText
        border = theme.border
        empty = theme.selected.opacity(0.25)
        hunk = theme.selected.opacity(0.6)
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

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.left == b.left && a.right == b.right && a.colors == b.colors && a.leftWidth == b.leftWidth
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
                half(row.left, style: left, number: row.left?.oldNumber, side: .removed)
                    .frame(width: leftWidth.map { max(0, $0 - 0.5) })
                colors.border.frame(width: 1)
                half(row.right, style: right, number: row.right?.newNumber, side: .added)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func half(_ line: DiffLine?, style: DiffLineStyle, number: Int?, side: DiffLine.Kind) -> some View {
        let changed = line?.kind == side
        let tint = side == .added ? DiffColors.added : DiffColors.removed
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundStyle(colors.dim.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)
            text(line, style)
                .foregroundStyle(colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: .infinity, alignment: .topLeading)
        .background(line == nil ? colors.empty : (changed ? tint.opacity(0.14) : .clear))
        .overlay(alignment: .leading) {
            if changed { tint.frame(width: 3) }
        }
    }

    private func text(_ line: DiffLine?, _ style: DiffLineStyle) -> Text {
        guard let line, !line.text.isEmpty else { return Text(verbatim: " ") }
        if style.isEmpty { return Text(verbatim: line.text) }
        return Text(palette.text(line, style))
    }
}

/// The review page's host: the page's keys, when nothing in it took them.
final class ReviewHostingView: NSHostingView<ReviewPageView> {
    var review: () -> ReviewModel? = { nil }

    override var acceptsFirstResponder: Bool { true }
    /// A press in a window not in front acts at once — the divider between
    /// the sides drags on the first one, as the terminal's dividers do.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
