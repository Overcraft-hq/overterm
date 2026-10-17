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

enum DiffColors {
    static let added = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let removed = Color(red: 0.94, green: 0.36, blue: 0.34)
}

/// What a diff line's text is drawn with: the editor's syntax colours
/// (SyntaxPalette), comments in italics, and the part that changed marked
/// stronger than the line's tint.
struct DiffPalette {
    private let comment: AttributeContainer
    private let string: AttributeContainer
    private let number: AttributeContainer
    private let keyword: AttributeContainer

    init(text: NSColor) {
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
    func text(_ line: DiffLine, _ style: DiffLineStyle) -> AttributedString {
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
struct FileCard: View {
    let file: ChangedFile
    let diff: DiffModel.FileDiff?
    let collapsed: Bool
    /// Stage and Discard: only for uncommitted changes. A commit's card
    /// has neither — what it shows already happened.
    var editable: Bool = false
    @ObservedObject var theme: ChromeTheme
    let palette: DiffPalette
    /// The changes pane's alone: why the file changed.
    var why: FileWhy = .none
    var onToggleWhy: () -> Void = {}
    let onToggle: () -> Void
    var onStage: () -> Void = {}
    var onDiscard: () -> Void = {}
    let onOpen: () -> Void

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

    var body: some View {
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
                        ForEach(diff.lines) { line in
                            DiffLineView(line: line, style: diff.style(of: line), palette: palette, theme: theme).equatable()
                        }
                        if diff.truncated {
                            Text("Diff truncated.").font(.system(size: 11)).foregroundStyle(theme.dimText).padding(8)
                        }
                    }
                    .padding(.vertical, 4)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                } else {
                    Text(verbatim: diff == nil ? "Loading…" : emptyDiff)
                        .font(.system(size: 11)).foregroundStyle(theme.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            if editable {
                Button(action: onStage) {
                    Image(systemName: stageSymbol).font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(file.stageState == .none ? theme.dimText : theme.text)
                .help(file.stageState == .full ? "Unstage" : "Stage")
            }
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            let dir = (file.path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).font(.system(size: 11)).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.head)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Copy Path")
            counts
            Spacer(minLength: 4)
            if editable {
                Button(action: onDiscard) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Discard Changes…")
            }
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Editor")
            .disabled(file.kind == .deleted)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
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
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.dimText.opacity(0.3)))
        }
    }
}

struct DiffLineView: View, Equatable {
    let line: DiffLine
    let style: DiffLineStyle
    let palette: DiffPalette
    @ObservedObject var theme: ChromeTheme

    /// The palette and theme are the app's for its life: a line is drawn
    /// again only when its text or style changes, not on every refresh.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.line == b.line && a.style == b.style }

    /// A long line wraps within the pane, under its own text: kept on one
    /// row it grew wider than the pane, was centred, and lost its start.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            text
                .foregroundStyle(line.kind == .hunk || line.kind == .meta ? theme.dimText : theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 3)
        .padding(.vertical, 1)
        .frame(minHeight: 18)
        .background(background)
        .overlay(alignment: .leading) { Rectangle().fill(edge).frame(width: 3) }
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
