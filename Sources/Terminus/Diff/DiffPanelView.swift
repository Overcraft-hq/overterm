import SwiftUI

/// The diff panel above the terminal: changed files on the left, the
/// selected file's diff on the right.
struct DiffPanelView: View {
    @ObservedObject var model: DiffModel
    let theme: ChromeTheme
    let onClose: () -> Void
    /// The file whose Discard is awaiting confirmation.
    @State private var discarding: ChangedFile?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if let error = model.error {
                placeholder(error)
            } else if model.files.isEmpty {
                placeholder(model.root == nil ? "" : "No changes")
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        fileList
                        Divider().opacity(0.4)
                        CommitBox(model: model, theme: theme)
                    }
                    .frame(width: 280)
                    Divider().opacity(0.4)
                    DiffTextView(lines: model.lines, truncated: model.truncated, theme: theme)
                }
            }
        }
        .background(theme.strip)
        .alert(
            "Discard changes to \((discarding?.path as NSString?)?.lastPathComponent ?? "")?",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            presenting: discarding
        ) { file in
            Button("Discard", role: .destructive) { Task { await model.discard(file) } }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text(
                file.kind == .untracked
                    ? "The file is moved to the Trash."
                    : "Staged and unstaged changes are lost; the file goes back to HEAD. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(model.branch ?? model.root?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if !model.files.isEmpty {
                Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s")").foregroundStyle(theme.dimText)
                Text("+\(model.totals.added)").foregroundStyle(DiffColors.added)
                Text("−\(model.totals.removed)").foregroundStyle(DiffColors.removed)
            }
            Spacer()
            iconButton("arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            iconButton("xmark", help: "Hide Diff (⌥⌘D)", action: onClose)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.files) { file in
                    ChangedFileRow(
                        file: file, isSelected: file.path == model.selectedPath, theme: theme,
                        onToggleStaged: { Task { await model.toggleStaged(file) } }
                    )
                    .onTapGesture { model.select(file.path) }
                    .contextMenu {
                        Button("Stage") { Task { await model.stage(file) } }.disabled(file.stageState == .full)
                        Button("Unstage") { Task { await model.unstage(file) } }.disabled(file.stageState == .none)
                        Divider()
                        Button("Discard Changes…") { discarding = file }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.dimText).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

enum DiffColors {
    static let added = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let removed = Color(red: 0.94, green: 0.36, blue: 0.34)
}

private struct ChangedFileRow: View {
    let file: ChangedFile
    let isSelected: Bool
    let theme: ChromeTheme
    let onToggleStaged: () -> Void
    @State private var hovering = false

    private var stageSymbol: String {
        switch file.stageState {
        case .full: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        case .none: "square"
        }
    }

    private var letterColor: Color {
        switch file.kind {
        case .added, .untracked: DiffColors.added
        case .deleted, .conflicted: DiffColors.removed
        default: Color(red: 0.98, green: 0.72, blue: 0.3)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleStaged) {
                Image(systemName: stageSymbol).font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(file.stageState == .none ? theme.dimText : theme.text)
            .help(file.stageState == .full ? "Unstage" : "Stage")
            Text(file.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(letterColor)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                let dir = (file.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.system(size: 10)).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let added = file.added, let removed = file.removed {
                Text("+\(added)").foregroundStyle(DiffColors.added)
                Text("−\(removed)").foregroundStyle(DiffColors.removed)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? theme.text : theme.dimText)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

private struct DiffTextView: View {
    let lines: [DiffLine]
    let truncated: Bool
    let theme: ChromeTheme

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineView(line: line, theme: theme)
                }
                if truncated {
                    Text("Diff truncated — too large to show in full.")
                        .foregroundStyle(theme.dimText)
                        .padding(8)
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let theme: ChromeTheme

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker).foregroundStyle(markerColor).frame(width: 14)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .meta || line.kind == .hunk ? theme.dimText : theme.text)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.trailing, 12)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        default: " "
        }
    }

    private var markerColor: Color { line.kind == .added ? DiffColors.added : DiffColors.removed }

    private var background: Color {
        switch line.kind {
        case .added: DiffColors.added.opacity(0.14)
        case .removed: DiffColors.removed.opacity(0.14)
        case .hunk: theme.selected.opacity(0.6)
        default: .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(theme.dimText.opacity(0.7))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// Commit message and button under the file list; commits what is staged.
private struct CommitBox: View {
    @ObservedObject var model: DiffModel
    let theme: ChromeTheme
    @State private var message = ""
    @State private var committing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.selected))
            if let error = model.actionError {
                Text(error).font(.system(size: 11)).foregroundStyle(DiffColors.removed).lineLimit(3)
            }
            HStack {
                Button("Stage All") { Task { await model.stageAll() } }
                    .disabled(model.files.allSatisfy { $0.stageState == .full })
                Spacer()
                Button(committing ? "Committing…" : "Commit \(model.stagedCount)") { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.stagedCount == 0 || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || committing)
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    private func commit() {
        committing = true
        Task { @MainActor in
            if await model.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines)) { message = "" }
            committing = false
        }
    }
}
