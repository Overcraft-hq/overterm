import AppKit
import SwiftUI

/// One changed file, drawn as a card: the header, what the file is, and —
/// unfolded — its diff, line by line.
///
/// It lived in the changes pane until a commit's detail wanted the same
/// thing. Nothing here knows where the diff came from: `FileDiff` takes a
/// unified diff as a string, so `git diff` and `git show` both land in the
/// same card. The pieces the changes pane alone has — a stage box, Discard,
/// the "why it changed" strip — default to absent.

package enum DiffColors {
    package static let added = Color(red: 0.36, green: 0.78, blue: 0.44)
    package static let removed = Color(red: 0.94, green: 0.36, blue: 0.34)
}

/// What a diff line's text is drawn with: the editor's syntax colours
/// (SyntaxPalette), comments in italics, and the part that changed marked
/// stronger than the line's tint.
package struct DiffPalette {
    private let comment: AttributeContainer
    private let string: AttributeContainer
    private let number: AttributeContainer
    private let keyword: AttributeContainer

    package init(text: NSColor) {
        func attributes(_ kind: SyntaxHighlighter.Kind) -> AttributeContainer {
            var attributes = AttributeContainer()
            attributes.foregroundColor = Color(nsColor: SyntaxPalette.color(kind, text: text))
            if kind == .comment { attributes.inlinePresentationIntent = .emphasized }
            return attributes
        }
        comment = attributes(.comment)
        string = attributes(.string)
        number = attributes(.number)
        keyword = attributes(.keyword)
    }

    private func attributes(_ kind: SyntaxHighlighter.Kind) -> AttributeContainer {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        }
    }

    /// The line's text with its style put on — worked out as the diff
    /// loaded (`FileDiff.style(of:)`), only applied here: a few microseconds
    /// a line (kept as ranges, not as attributed text, a capped file's lines
    /// would take megabytes).
    package func text(_ line: DiffLine, _ style: DiffLineStyle) -> AttributedString {
        var text = AttributedString(line.text)
        // Tokens don't overlap and the text has no attributes yet: set, not merged.
        for token in style.tokens {
            guard let range = Range(token.range, in: text) else { continue }
            text[range].setAttributes(attributes(token.kind))
        }
        if let changed = style.changed, let range = Range(changed, in: text) {
            text[range].backgroundColor = (line.kind == .added ? DiffColors.added : DiffColors.removed).opacity(0.32)
        }
        return text
    }
}

/// One changed file: a header row and, unfolded, its diff.
package struct FileCard: View {
    package let file: ChangedFile
    package let diff: DiffModel.FileDiff?
    package let collapsed: Bool
    /// Stage and Discard: only for uncommitted changes. A commit's card
    /// has neither — what it shows already happened.
    package var editable: Bool = false
    @ObservedObject package var theme: ChromeTheme
    package let palette: DiffPalette
    /// The changes pane's alone: why the file changed.
    package var why: FileWhy = .none
    package var onToggleWhy: () -> Void = {}
    package let onToggle: () -> Void
    package var onStage: () -> Void = {}
    package var onDiscard: () -> Void = {}
    package let onOpen: () -> Void
    /// A hunk's Stage, Unstage or Discard; nil, no buttons (a branch's
    /// diff, a commit's).
    package var onHunk: ((DiffModel.DiffHunk, DiffModel.HunkAction) -> Void)?

    package init(
        file: ChangedFile, diff: DiffModel.FileDiff?, collapsed: Bool, editable: Bool = false, theme: ChromeTheme, palette: DiffPalette, why: FileWhy = .none, onToggleWhy: @escaping () -> Void = {},
        onToggle: @escaping () -> Void, onStage: @escaping () -> Void = {}, onDiscard: @escaping () -> Void = {}, onOpen: @escaping () -> Void,
        onHunk: ((DiffModel.DiffHunk, DiffModel.HunkAction) -> Void)? = nil
    ) {
        self.onHunk = onHunk
        self.file = file
        self.diff = diff
        self.collapsed = collapsed
        self.editable = editable
        self._theme = ObservedObject(wrappedValue: theme)
        self.palette = palette
        self.why = why
        self.onToggleWhy = onToggleWhy
        self.onToggle = onToggle
        self.onStage = onStage
        self.onDiscard = onDiscard
        self.onOpen = onOpen
    }

    private var emptyDiff: String {
        if file.kind == .renamed, let original = file.originalPath { return "Renamed from \(original), content unchanged." }
        return "No textual diff (binary or empty)."
    }

    private var stageSymbol: String {
        switch file.stageState {
        case .full: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        case .none: "square"
        }
    }

    package var body: some View {
        VStack(spacing: 0) {
            header
            if !why.isEmpty {
                Divider().opacity(0.3)
                WhyStrip(why: why, theme: theme, onToggle: onToggleWhy)
            }
            if !collapsed {
                Divider().opacity(0.3)
                if let diff, !diff.lines.isEmpty {
                    // Lazy: a file at the cap (DiffModel.maxDiffLines) built
                    // every line's view at once and froze the window ~9 s.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if diff.unstagedFrom != nil, diff.startsStaged { sectionLabel("Staged") }
                        ForEach(diff.lines) { line in
                            if line.id == diff.unstagedFrom { sectionLabel("Not staged") }
                            if let hunk = diff.hunks[line.id], let onHunk {
                                HunkHeader(line: line, hunk: hunk, theme: theme, onHunk: onHunk)
                            } else {
                                DiffLineView(line: line, style: diff.style(of: line), palette: palette, theme: theme).equatable()
                            }
                        }
                        if diff.truncated {
                            Text("Diff truncated.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(8)
                        }
                    }
                    .padding(.vertical, 4)
                    .font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                    .textSelection(.enabled)
                } else {
                    Text(verbatim: diff == nil ? "Loading…" : emptyDiff)
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Above a part of an uncommitted file's diff: whether it is staged.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ChromeMetrics.text(10), weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.dimText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityIdentifier("diff.section.\(text == "Staged" ? "staged" : "unstaged")")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: ChromeMetrics.text(10), weight: .semibold)).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            if editable {
                Button(action: onStage) {
                    Image(systemName: stageSymbol).font(.system(size: ChromeMetrics.text(12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(file.stageState == .none ? theme.dimText : theme.text)
                .help(file.stageState == .full ? "Unstage" : "Stage")
            }
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: ChromeMetrics.text(13)))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            let dir = (file.path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.head)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: ChromeMetrics.text(10)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Copy Path")
            counts
            Spacer(minLength: 4)
            if editable {
                Button(action: onDiscard) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: ChromeMetrics.text(11)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Discard Changes…")
            }
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square").font(.system(size: ChromeMetrics.text(11)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Editor")
            .disabled(file.kind == .deleted)
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeMetrics.row(34))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    @ViewBuilder private var counts: some View {
        if let added = file.added, let removed = file.removed {
            HStack(spacing: 3) {
                Text(verbatim: "+\(added)").foregroundStyle(DiffColors.added)
                Text("·").foregroundStyle(theme.dimText)
                Text(verbatim: "−\(removed)").foregroundStyle(DiffColors.removed)
            }
            .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.dimText.opacity(0.3)))
        }
    }
}

package struct DiffLineView: View, Equatable {
    package let line: DiffLine
    package let style: DiffLineStyle
    package let palette: DiffPalette
    @ObservedObject package var theme: ChromeTheme
    /// Picked in a review (its lines' numbers clicked).
    package let picked: Bool
    /// A click on its numbers, with whether ⇧ was down — a review's; the
    /// changes pane's lines have none.
    package let onNumber: ((Bool) -> Void)?

    package init(
        line: DiffLine, style: DiffLineStyle, palette: DiffPalette, theme: ChromeTheme, picked: Bool = false, onNumber: ((Bool) -> Void)? = nil
    ) {
        self.line = line
        self.style = style
        self.palette = palette
        self._theme = ObservedObject(wrappedValue: theme)
        self.picked = picked
        self.onNumber = onNumber
    }

    /// The palette and theme are the app's for its life: a line is drawn
    /// again only when its text, style or pick changes, not on every refresh.
    package nonisolated static func == (a: Self, b: Self) -> Bool { a.line == b.line && a.style == b.style && a.picked == b.picked }

    /// A long line wraps within the pane, under its own text: kept on one
    /// row it grew wider than the pane, was centred, and lost its start.
    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            numbers
            text
                .foregroundStyle(line.kind == .hunk || line.kind == .meta ? theme.dimText : theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 3)
        .padding(.vertical, 1)
        .frame(minHeight: 18)
        .background(picked ? Color.accentColor.opacity(0.28) : background)
        .overlay(alignment: .leading) { Rectangle().fill(picked ? Color.accentColor : edge).frame(width: 3) }
    }

    /// Both numbers; in a review, what a click picks the line by.
    private var numbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
        }
        .onTapGesture { onNumber?(NSEvent.modifierFlags.contains(.shift)) }
    }

    /// Syntax colours over the line's colour; the changed part marked.
    private var text: Text {
        if line.text.isEmpty { return Text(verbatim: " ") }
        if style.isEmpty { return Text(verbatim: line.text) }
        return Text(palette.text(line, style))
    }

    private var edge: Color {
        switch line.kind {
        case .added: DiffColors.added
        case .removed: DiffColors.removed
        default: .clear
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: DiffColors.added.opacity(0.14)
        case .removed: DiffColors.removed.opacity(0.14)
        case .hunk: theme.selected.opacity(0.6)
        default: .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .foregroundStyle(theme.dimText.opacity(0.7))
            .frame(width: 32, alignment: .trailing)
            .padding(.trailing, 5)
    }
}

/// A hunk's `@@` line, and what can be done to that hunk alone: a staged
/// one unstaged; one not staged staged, or discarded (asked first).
private struct HunkHeader: View {
    let line: DiffLine
    let hunk: DiffModel.DiffHunk
    @ObservedObject var theme: ChromeTheme
    let onHunk: (DiffModel.DiffHunk, DiffModel.HunkAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: line.text).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            switch hunk.side {
            case .staged:
                button("Unstage", .unstage, help: "Out of the index; the file keeps it")
            case .unstaged:
                button("Discard…", .discard, help: "Out of the file — asked first")
                button("Stage", .stage, help: "This hunk alone into the index")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .frame(minHeight: 22)
        .background(theme.selected.opacity(0.6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff.hunk")
    }

    private func button(_ title: String, _ action: DiffModel.HunkAction, help: String) -> some View {
        Button(title) { onHunk(hunk, action) }
            .buttonStyle(.borderless)
            .font(.system(size: ChromeMetrics.text(11), weight: .medium, design: .default))
            .help(help)
    }
}
