import AppKit

/// Every editor hears every server's diagnostics: one registry, any number
/// of windows. Each takes the ones for files it has open.
extension Notification.Name {
    static let editorDiagnostics = Notification.Name("OvertermEditorDiagnostics")
}

extension EditorViewController {
    // MARK: Servers

    /// The language server for the buffer's file — nil when Settings turns
    /// them off, or the language has none on this machine.
    func server(for buffer: EditorBuffer) -> LanguageServer? {
        guard Settings.shared.editorLanguageServers, let url = buffer.url, buffer.document.unavailable == nil else { return nil }
        Self.routeDiagnostics()
        return LanguageServers.shared.server(for: url)
    }

    func serverName(for buffer: EditorBuffer) -> String? {
        guard buffer.serverOpen, let server = server(for: buffer) else { return nil }
        let name = server.command.executable.lastPathComponent.replacingOccurrences(of: ".js", with: "")
        // node runs the JavaScript servers: name the script, not node.
        if name == "node", let script = server.command.arguments.first {
            return (script as NSString).lastPathComponent.replacingOccurrences(of: ".js", with: "")
        }
        return name
    }

    private static var routing = false

    /// Once per run: the registry's diagnostics become a notification.
    private static func routeDiagnostics() {
        guard !routing else { return }
        routing = true
        LanguageServers.shared.onDiagnostics = { url, diagnostics in
            NotificationCenter.default.post(name: .editorDiagnostics, object: nil, userInfo: ["url": url, "diagnostics": diagnostics])
        }
    }

    func observeDiagnostics() {
        NotificationCenter.default.addObserver(forName: .editorDiagnostics, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL, let diagnostics = note.userInfo?["diagnostics"] as? [LSP.Diagnostic] else { return }
            MainActor.assumeIsolated { self?.receive(diagnostics, for: url) }
        }
    }

    private func receive(_ diagnostics: [LSP.Diagnostic], for url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let buffer = buffers.first(where: { $0.url?.standardizedFileURL.resolvingSymlinksInPath() == key }) else { return }
        let starts = LineIndex.starts(of: buffer.storage.string as NSString)
        let length = buffer.storage.length
        buffer.diagnostics = diagnostics.map { diagnostic in
            let start = Self.offset(of: diagnostic.range.start, starts: starts, length: length)
            let end = max(start, Self.offset(of: diagnostic.range.end, starts: starts, length: length))
            let severity = EditorDiagnostic.Severity(rawValue: diagnostic.level.rawValue) ?? .error
            return EditorDiagnostic(
                range: NSRange(location: start, length: end - start), severity: severity, message: diagnostic.message,
                source: diagnostic.source)
        }
        guard buffer === active else { return }
        textView.diagnostics = buffer.diagnostics
        updateProblemLines()
        updateStatus()
    }

    func bufferDidOpen(_ buffer: EditorBuffer) {
        refreshGitBase(buffer)
        openOnServer(buffer)
    }

    private func openOnServer(_ buffer: EditorBuffer) {
        guard let server = server(for: buffer), let url = buffer.url, let language = LanguageServers.languageID(for: url) else { return }
        buffer.serverVersion = buffer.version
        buffer.serverOpen = true
        server.didOpen(url, languageID: language, version: buffer.serverVersion, text: buffer.storage.string)
        updateStatus()
        // The outline, for the breadcrumb (and a warm ⇧⌘O).
        loadSymbols(buffer) { [weak self] _ in self?.updateBreadcrumb() }
    }

    func bufferWillClose(_ buffer: EditorBuffer) {
        guard buffer.serverOpen, let url = buffer.url else { return }
        buffer.serverOpen = false
        server(for: buffer)?.didClose(url)
    }

    func bufferDidReload(_ buffer: EditorBuffer) {
        sendChange(buffer)
        refreshGitBase(buffer)
        if buffer === active { refreshChrome() }
    }

    /// An edit: the server hears it once typing pauses (or before any request).
    func bufferDidChange(_ buffer: EditorBuffer) {
        guard buffer.serverOpen else { return }
        pendingServerChange?.cancel()
        let work = DispatchWorkItem { [weak self, weak buffer] in
            MainActor.assumeIsolated {
                guard let self, let buffer else { return }
                self.sendChange(buffer)
                if buffer === self.active { self.loadSymbols(buffer) { [weak self] _ in self?.updateBreadcrumb() } }
            }
        }
        pendingServerChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Before a request: the server must have the text the position is in.
    func flushServerChange(_ buffer: EditorBuffer) {
        pendingServerChange?.cancel()
        pendingServerChange = nil
        sendChange(buffer)
    }

    private func sendChange(_ buffer: EditorBuffer) {
        guard buffer.serverOpen, buffer.serverVersion != buffer.version, let url = buffer.url, let server = server(for: buffer) else { return }
        buffer.serverVersion = buffer.version
        server.didChange(url, version: buffer.serverVersion, text: buffer.storage.string)
    }

    func bufferDidSave(_ buffer: EditorBuffer) {
        guard buffer.serverOpen, let url = buffer.url else { return }
        flushServerChange(buffer)
        server(for: buffer)?.didSave(url, text: buffer.storage.string)
    }

    func languageServersSettingChanged() {
        for buffer in buffers {
            if Settings.shared.editorLanguageServers {
                if !buffer.serverOpen { openOnServer(buffer) }
            } else {
                buffer.serverOpen = false
                buffer.diagnostics = []
            }
        }
        if let buffer = active {
            textView.diagnostics = buffer.diagnostics
            updateProblemLines()
        }
        updateStatus()
    }

    // MARK: Positions

    /// LSP positions are UTF-16 offsets within a line, as NSString counts.
    func lspPosition(of offset: Int) -> LSP.Position {
        let starts = gutter.lineStarts
        let line = LineIndex.line(of: offset, in: starts) - 1
        return LSP.Position(line: line, character: offset - starts[line])
    }

    func offset(of position: LSP.Position) -> Int {
        Self.offset(of: position, starts: gutter.lineStarts, length: (textView.string as NSString).length)
    }

    func range(of range: LSP.Range) -> NSRange {
        let start = offset(of: range.start)
        return NSRange(location: start, length: max(0, offset(of: range.end) - start))
    }

    static func offset(of position: LSP.Position, starts: [Int], length: Int) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < starts.count else { return length }
        let lineEnd = position.line + 1 < starts.count ? starts[position.line + 1] - 1 : length
        return min(starts[position.line] + max(0, position.character), max(starts[position.line], lineEnd))
    }
}
