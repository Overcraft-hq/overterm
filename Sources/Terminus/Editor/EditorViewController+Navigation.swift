import AppKit

/// Where you were before a jump, for ⌃- and ⌃⇧- (Zed's Go Back/Forward).
struct NavigationHistory {
    struct Entry: Equatable {
        let url: URL
        let location: Int
    }

    private(set) var back: [Entry] = []
    private(set) var forward: [Entry] = []

    /// A jump is about to leave `entry`.
    mutating func record(_ entry: Entry) {
        if back.last == entry { return }
        back.append(entry)
        if back.count > 100 { back.removeFirst() }
        forward = []
    }

    mutating func goBack(from current: Entry?) -> Entry? {
        guard let entry = back.popLast() else { return nil }
        if let current { forward.append(current) }
        return entry
    }

    mutating func goForward(from current: Entry?) -> Entry? {
        guard let entry = forward.popLast() else { return nil }
        if let current { back.append(current) }
        return entry
    }
}

/// A definition in the open file: the language server's outline, or the
/// grammar's tags where there is no server.
struct EditorSymbol {
    let name: String
    let kind: String
    /// The whole declaration (the name alone, from tags).
    let range: NSRange
    let selection: NSRange
    let depth: Int
}

extension EditorViewController {
    // MARK: History

    private var currentEntry: NavigationHistory.Entry? {
        active?.url.map { NavigationHistory.Entry(url: $0, location: textView.selectedRange().location) }
    }

    func recordPosition() {
        if let entry = currentEntry { history.record(entry) }
    }

    func goBack() {
        if let entry = history.goBack(from: currentEntry) { jump(to: entry) }
    }

    func goForward() {
        if let entry = history.goForward(from: currentEntry) { jump(to: entry) }
    }

    private func jump(to entry: NavigationHistory.Entry) {
        open(entry.url) { [weak self] opened in
            guard opened, let self else { return }
            let location = min(entry.location, (self.textView.string as NSString).length)
            self.reveal(NSRange(location: location, length: 0), flash: false)
        }
    }

    /// Opens `url` (if it isn't the file showing) and selects `range` in it,
    /// remembering where you were.
    func show(_ url: URL, selecting range: @escaping () -> NSRange?) {
        recordPosition()
        open(url) { [weak self] opened in
            guard opened, let self, let target = range() else { return }
            self.reveal(target)
            self.focus()
        }
    }

    // MARK: Pickers

    private func showPicker(_ picker: EditorPicker) {
        self.picker?.dismiss()
        picker.onDismiss = { [weak self, weak picker] in
            guard let self, self.picker === picker else { return }
            self.picker = nil
            self.focus()
        }
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            picker.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        self.picker = picker
        view.layoutSubtreeIfNeeded()
        picker.focus()
    }

    func goToLine() {
        let lines = gutter.lineStarts.count
        let picker = EditorPicker(
            placeholder: "Line number, or line:column", hint: "Current line \(selectedLine) of \(lines)", theme: theme, showsList: false,
            provider: { _ in [] },
            choose: { [weak self] _, text in
                let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard let self, let line = parts.first else { return }
                self.recordPosition()
                self.go(toLine: min(max(1, line), lines), column: parts.count > 1 ? parts[1] : 1)
            })
        picker.identifier = NSUserInterfaceItemIdentifier("goToLine")
        showPicker(picker)
    }

    func goToSymbol() {
        guard let buffer = active else { return }
        var symbols: [EditorSymbol] = []
        let picker = EditorPicker(
            placeholder: "Go to symbol in \(buffer.name)", theme: theme, showsList: true,
            provider: { query in
                Self.rankSymbols(symbols, query: query).map { symbol, matched in
                    EditorListItem(
                        title: symbol.name, detail: symbol.kind, badge: Self.symbolBadge(symbol.kind),
                        badgeColor: self.theme.style(for: symbol.kind.contains("class") || symbol.kind.contains("struct") ? "type" : "function")?.color
                            ?? self.theme.text,
                        matched: matched)
                }
            },
            choose: { [weak self] row, text in
                guard let self, row >= 0 else { return }
                let ranked = Self.rankSymbols(symbols, query: text)
                guard ranked.indices.contains(row) else { return }
                self.recordPosition()
                self.reveal(ranked[row].0.selection)
            })
        picker.identifier = NSUserInterfaceItemIdentifier("goToSymbol")
        showPicker(picker)
        loadSymbols(buffer) { [weak picker] found in
            symbols = found
            picker?.reload()
        }
    }

    static func rankSymbols(_ symbols: [EditorSymbol], query: String) -> [(EditorSymbol, [Int])] {
        guard !query.isEmpty else { return symbols.map { ($0, []) } }
        return symbols.compactMap { symbol in CompletionMatch.score(candidate: symbol.name, query: query).map { (symbol, $0.score, $0.matched) } }
            .sorted { $0.1 > $1.1 }
            .map { ($0.0, $0.2) }
    }

    static func symbolBadge(_ kind: String) -> String {
        switch kind {
        case "function", "method", "constructor": "fn"
        case "class", "struct", "interface", "enum", "type", "protocol": "T"
        case "module", "namespace", "package": "mod"
        case "field", "property": "fld"
        case "constant": "K"
        default: "•"
        }
    }

    /// The file's symbols: the language server's outline, else the
    /// grammar's tags.
    func loadSymbols(_ buffer: EditorBuffer, _ done: @escaping ([EditorSymbol]) -> Void) {
        if let server = server(for: buffer), let url = buffer.url, server.capabilities?.documentSymbol != false {
            flushServerChange(buffer)
            Task { [weak self] in
                let found = (try? await server.documentSymbols(url)) ?? []
                guard let self else { return }
                if found.isEmpty {
                    self.loadTags(buffer, done)
                } else {
                    let symbols = found.map {
                        EditorSymbol(
                            name: $0.name, kind: Self.symbolKindName($0.kind), range: self.range(of: $0.range), selection: self.range(of: $0.selectionRange),
                            depth: $0.depth)
                    }
                    if buffer === self.active { self.currentSymbols = symbols }
                    done(symbols)
                }
            }
        } else {
            loadTags(buffer, done)
        }
    }

    private func loadTags(_ buffer: EditorBuffer, _ done: @escaping ([EditorSymbol]) -> Void) {
        guard let syntax = buffer.syntax else { return done([]) }
        // Called back on the main queue (SyntaxDocument.symbols).
        nonisolated(unsafe) let done = done
        syntax.symbols { found in
            MainActor.assumeIsolated {
                done(found.map { EditorSymbol(name: $0.name, kind: $0.kind, range: $0.range, selection: $0.range, depth: 0) })
            }
        }
    }

    static func symbolKindName(_ kind: Int) -> String {
        switch kind {
        case 1: "file"
        case 2: "module"
        case 3: "namespace"
        case 4: "package"
        case 5: "class"
        case 6: "method"
        case 7: "property"
        case 8: "field"
        case 9: "constructor"
        case 10: "enum"
        case 11: "interface"
        case 12: "function"
        case 13: "variable"
        case 14: "constant"
        case 22: "case"
        case 23: "struct"
        case 26: "type"
        default: "symbol"
        }
    }

    /// The innermost declaration around the caret, for the breadcrumb.
    func symbolAtCaret() -> EditorSymbol? {
        let caret = textView.selectedRange().location
        return currentSymbols.filter { NSLocationInRange(caret, $0.range) || NSMaxRange($0.range) == caret }.max { $0.depth < $1.depth }
    }

    private static var fileListCache: [URL: [String]] = [:]

    /// ⌘P: every file of the checkout, by fuzzy name.
    func goToFile() {
        guard let root = workspaceRoot?() ?? active?.url.flatMap(Self.gitRoot(of:)) ?? active?.url?.deletingLastPathComponent() else { return }
        var files = Self.fileListCache[root] ?? []
        let picker = EditorPicker(
            placeholder: "Go to file", theme: theme, showsList: true,
            provider: { query in
                Self.rankFiles(files, query: query).map { path, matched in
                    let name = (path as NSString).lastPathComponent
                    let offset = (path as NSString).length - (name as NSString).length
                    return EditorListItem(
                        title: name, detail: (path as NSString).deletingLastPathComponent,
                        matched: matched.compactMap { $0 >= offset ? $0 - offset : nil })
                }
            },
            choose: { [weak self] row, text in
                let ranked = Self.rankFiles(files, query: text)
                guard let self, ranked.indices.contains(row) else { return }
                self.show(root.appendingPathComponent(ranked[row].0), selecting: { nil })
            })
        picker.identifier = NSUserInterfaceItemIdentifier("goToFile")
        showPicker(picker)
        Task { [weak picker] in
            guard
                let output = try? await Git.run(
                    ["ls-files", "--cached", "--others", "--exclude-standard"], in: root, outputLimit: 32 * 1024 * 1024)
            else { return }
            files = output.split(separator: "\n").map(String.init)
            Self.fileListCache[root] = files
            picker?.reload()
        }
    }

    static func rankFiles(_ files: [String], query: String) -> [(String, [Int])] {
        let query = query.replacingOccurrences(of: " ", with: "")
        guard !query.isEmpty else { return files.prefix(100).map { ($0, []) } }
        var ranked: [(String, Int, [Int])] = []
        for path in files {
            guard let match = CompletionMatch.score(candidate: path, query: query) else { continue }
            // The name matching counts most, as it does in Zed.
            let name = (path as NSString).lastPathComponent
            let bonus = CompletionMatch.score(candidate: name, query: query).map { $0.score + 50 } ?? 0
            ranked.append((path, match.score + bonus - path.count / 8, match.matched))
        }
        ranked.sort { $0.1 > $1.1 }
        return ranked.prefix(100).map { ($0.0, $0.2) }
    }

    static func gitRoot(of url: URL) -> URL? {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        // Bounded and stopping at "/" (whose parent is "/../", not "/").
        for _ in 0..<256 where dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    // MARK: Definitions and references

    func goToDefinition(at index: Int) {
        guard let buffer = active, let server = server(for: buffer), let url = buffer.url else { return NSSound.beep() }
        flushServerChange(buffer)
        let position = lspPosition(of: index)
        Task { [weak self] in
            let locations = (try? await server.definition(url, at: position)) ?? []
            guard let self else { return }
            if locations.count == 1 {
                self.show(locations[0])
            } else if locations.count > 1 {
                self.showLocations(locations, title: "Definitions")
            } else {
                NSSound.beep()
            }
        }
    }

    func findReferences() {
        guard let buffer = active, let server = server(for: buffer), let url = buffer.url else { return NSSound.beep() }
        flushServerChange(buffer)
        let position = lspPosition(of: textView.selectedRange().location)
        Task { [weak self] in
            let locations = (try? await server.references(url, at: position)) ?? []
            guard let self else { return }
            locations.isEmpty ? NSSound.beep() : self.showLocations(locations, title: "References")
        }
    }

    private func show(_ location: LSP.Location) {
        let range = location.range
        show(location.url, selecting: { [weak self] in self?.range(of: range) })
    }

    private func showLocations(_ locations: [LSP.Location], title: String) {
        let root = workspaceRoot?() ?? active?.url.flatMap(Self.gitRoot(of:))
        let rows = locations.map { location -> EditorListItem in
            var path = location.url.path
            if let root, path.hasPrefix(root.path + "/") { path = String(path.dropFirst(root.path.count + 1)) }
            return EditorListItem(title: "\(path):\(location.range.start.line + 1)", detail: Self.line(location.range.start.line, of: location.url))
        }
        let picker = EditorPicker(
            placeholder: "\(title) — \(locations.count)", theme: theme, showsList: true,
            provider: { query in
                query.isEmpty ? rows : rows.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
            },
            choose: { [weak self] row, text in
                let shown =
                    text.isEmpty
                    ? Array(locations.indices) : locations.indices.filter { rows[$0].title.localizedCaseInsensitiveContains(text) || rows[$0].detail.localizedCaseInsensitiveContains(text) }
                guard let self, shown.indices.contains(row) else { return }
                self.show(locations[shown[row]])
            })
        picker.identifier = NSUserInterfaceItemIdentifier("locations")
        showPicker(picker)
    }

    /// One line of a file, trimmed, for a reference's row.
    private static func line(_ index: Int, of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var current = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == index { return line.trimmingCharacters(in: .whitespaces) }
            current += 1
        }
        return ""
    }

    // MARK: Problems

    func goToProblem(forward: Bool) {
        guard let buffer = active, !buffer.diagnostics.isEmpty else { return NSSound.beep() }
        let caret = textView.selectedRange().location
        let sorted = buffer.diagnostics.sorted { $0.range.location < $1.range.location }
        let target =
            forward
            ? sorted.first { $0.range.location > caret } ?? sorted.first
            : sorted.last { $0.range.location < caret } ?? sorted.last
        guard let target else { return }
        recordPosition()
        reveal(NSRange(location: target.range.location, length: 0), flash: false)
        showHover(at: target.range.location, fromKeyboard: true)
    }

    // MARK: Hover

    func showHover(at index: Int, fromKeyboard: Bool) {
        guard let buffer = active, view.window?.isKeyWindow == true else { return }
        let problems = buffer.diagnostics.filter {
            NSLocationInRange(index, $0.range) || ($0.range.length == 0 && $0.range.location == index)
        }
        let anchor = Self.wordRange(at: index, in: textView.string as NSString) ?? NSRange(location: index, length: 1)
        let present: (String) -> Void = { [weak self] text in
            guard let self, !(text.isEmpty && problems.isEmpty) else { return }
            self.hover?.close()
            let popover = EditorHover.popover(text: text, problems: problems, theme: self.theme, font: self.textView.font ?? Self.font)
            guard let window = self.view.window else { return }
            let screen = self.textView.screenRect(forCharacterAt: anchor.location)
            let rect = self.textView.convert(window.convertFromScreen(screen), from: nil)
            popover.show(relativeTo: rect, of: self.textView, preferredEdge: .maxY)
            self.hover = popover
        }
        guard let server = server(for: buffer), let url = buffer.url, server.capabilities?.hover != false else {
            if !problems.isEmpty { present("") }
            return
        }
        let position = lspPosition(of: index)
        let version = buffer.version
        Task { [weak self] in
            let answer = try? await server.hover(url, at: position)
            guard let self, buffer.version == version, buffer === self.active else { return }
            // The mouse moved on while the server thought: don't show a stale one.
            if !fromKeyboard, let window = self.view.window {
                let mouse = self.textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                guard let now = self.textView.characterIndex(at: mouse), NSLocationInRange(now, anchor) || now == index else { return }
            }
            present(answer?.contents.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    // MARK: Formatting

    func formatDocument(_ done: @escaping () -> Void) {
        guard let buffer = active, let server = server(for: buffer), let url = buffer.url, server.capabilities?.formatting != false else {
            return done()
        }
        flushServerChange(buffer)
        let version = buffer.version
        Task { [weak self] in
            defer { done() }
            guard let edits = try? await server.formatting(url, tabSize: buffer.indentWidth, insertSpaces: !buffer.usesTabs),
                let self, !edits.isEmpty, buffer.version == version, buffer === self.active
            else { return }
            let caret = self.textView.selectedRange()
            self.textView.apply(edits.map { (range: self.range(of: $0.range), text: $0.newText) }, selecting: [caret])
        }
    }

    // MARK: Git

    /// What the last commit has for the file, then the gutter's marks.
    func refreshGitBase(_ buffer: EditorBuffer) {
        guard Settings.shared.editorGitGutter, let url = buffer.url else {
            buffer.gitBase = nil
            buffer.gitMarks = []
            if buffer === active { gutter.gitMarks = [] }
            return
        }
        let dir = url.deletingLastPathComponent()
        Task { [weak self] in
            let base = try? await Git.run(["show", "HEAD:./" + url.lastPathComponent], in: dir, timeout: 10, outputLimit: 16 * 1024 * 1024)
            guard let self else { return }
            buffer.gitBase = base
            self.computeGitMarks(buffer)
        }
    }

    func scheduleGitMarks(_ buffer: EditorBuffer) {
        guard buffer.gitBase != nil else { return }
        pendingGitWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak buffer] in
            MainActor.assumeIsolated {
                guard let self, let buffer else { return }
                self.computeGitMarks(buffer)
            }
        }
        pendingGitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func computeGitMarks(_ buffer: EditorBuffer) {
        guard let base = buffer.gitBase else {
            buffer.gitMarks = []
            if buffer === active { gutter.gitMarks = [] }
            return
        }
        let current = buffer.storage.string
        let version = buffer.version
        Task.detached(priority: .utility) {
            let hunks = LineDiff.hunks(base: base, current: current)
            let marks = hunks.map { hunk -> GitGutterMark in
                let kind: GitGutterMark.Kind =
                    switch hunk.kind {
                    case .added: .added
                    case .modified: .modified
                    case .deleted: .deleted
                    }
                return GitGutterMark(kind: kind, lines: hunk.lines)
            }
            await MainActor.run { [weak self] in
                guard let self, buffer.version == version else { return }
                buffer.gitMarks = marks
                if buffer === self.active { self.gutter.gitMarks = marks }
            }
        }
    }
}
