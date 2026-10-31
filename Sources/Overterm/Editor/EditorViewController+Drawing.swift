import AppKit

/// What a drawing's tab keeps: the file's parts, the canvas, and the text
/// it last wrote — to tell its own edit from somebody else's.
@MainActor
final class DrawingModel {
    var file: DrawingFile
    let view: DrawingView
    /// The buffer's text as the canvas last made it.
    var lastText: String
    /// How the scene is written back: Obsidian Excalidraw's "compress"
    /// for a `.md`, JSON for a plain `.excalidraw`.
    let saveAs: DrawingFile.Encoding
    var pendingSave: DispatchWorkItem?

    init(file: DrawingFile, text: String, saveAs: DrawingFile.Encoding) {
        self.file = file
        self.lastText = text
        self.saveAs = saveAs
        view = DrawingView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }
}

/// An Excalidraw drawing in the editor: its canvas over its text (⇧⌘V shows
/// the text), every change on the canvas written into the text and saved
/// a moment later — a drawing has no Save to forget, as in Obsidian.
extension EditorViewController {
    func attachDrawing(_ buffer: EditorBuffer) {
        guard let url = buffer.url, buffer.document.unavailable == nil else { return }
        let text = buffer.storage.string
        guard DrawingFile.isDrawing(url, text: text) else { return }
        let markdown = url.pathExtension.lowercased() == "md"
        guard let file = DrawingFile.parse(text, markdown: markdown) else { return }
        let compress = markdown && ExcalidrawSettings.read(from: notes.vault.root).compress
        let model = DrawingModel(file: file, text: text, saveAs: compress ? .compressed : .json)
        model.view.onChange = { [weak self, weak buffer] scene, encoding, texts in
            guard let self, let buffer, let model = buffer.drawing else { return }
            model.file = model.file.updated(scene: scene, encoding: encoding, texts: texts)
            model.lastText = model.file.text
            self.replaceText(of: buffer, with: model.lastText)
            self.scheduleDrawingSave(buffer)
        }
        model.view.onOpenLink = { [weak self] link in self?.openDrawingLink(link) }
        model.view.onError = { [weak self, weak buffer] _ in
            // A scene that doesn't read: its text, rather than an empty canvas.
            guard let self, let buffer else { return }
            buffer.showsPreview = false
            if buffer === self.active { self.updatePreview() }
        }
        model.view.load(file, saveAs: model.saveAs, dark: theme.isDark)
        buffer.drawing = model
        buffer.showsPreview = true
    }

    /// Puts `drawing`'s canvas over the text, or takes the one showing away.
    func showDrawing(_ drawing: DrawingModel?) {
        guard shownDrawing !== drawing?.view else {
            drawing.map { scrollView.isHidden = $0.view.superview != nil }
            return
        }
        shownDrawing?.removeFromSuperview()
        shownDrawing = drawing?.view
        guard let view = drawing?.view, let container = scrollView.superview else {
            scrollView.isHidden = active?.document.unavailable != nil && active != nil
            return
        }
        container.addSubview(view, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: scrollView.topAnchor),
            view.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        scrollView.isHidden = true
        view.window?.makeFirstResponder(view.webView)
    }

    /// The text changed under the canvas — reloaded from disk (Obsidian, an
    /// agent), or typed with the text showing: the canvas shows it.
    func drawingTextChanged(_ buffer: EditorBuffer) {
        guard let model = buffer.drawing, let url = buffer.url else { return }
        let text = buffer.storage.string
        guard text != model.lastText,
            let file = DrawingFile.parse(text, markdown: url.pathExtension.lowercased() == "md")
        else { return }
        model.file = file
        model.lastText = text
        model.view.load(file, saveAs: model.saveAs, dark: theme.isDark)
    }

    /// Saves a second after the last change.
    private func scheduleDrawingSave(_ buffer: EditorBuffer) {
        guard let model = buffer.drawing else { return }
        model.pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self, weak buffer] in
            MainActor.assumeIsolated {
                guard let self, let buffer, self.buffers.contains(where: { $0 === buffer }), buffer.document.isDirty else { return }
                self.save(buffer, overwriting: false)
            }
        }
        model.pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func closeDrawing(_ buffer: EditorBuffer) {
        guard let model = buffer.drawing else { return }
        model.pendingSave?.cancel()
        if shownDrawing === model.view { showDrawing(nil) }
    }

    /// An element's link: a web address opens in the browser, anything
    /// else is a note's name, followed as a note's link is.
    private func openDrawingLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme.lowercased()) {
            Self.openExternal(url)
            return
        }
        var target = trimmed
        if target.hasPrefix("[["), target.hasSuffix("]]") { target = String(target.dropFirst(2).dropLast(2)) }
        target = String(target.split(separator: "|", maxSplits: 1).first ?? "")
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return }
        followNoteLink(name, anchor: parts.count > 1 ? parts[1] : nil, markdown: false)
    }
}
