import AppKit
import WebKit

/// A note as it reads: Obsidian's reading view, drawn by the bundled
/// markdown-it, KaTeX, highlight.js and mermaid (Resources/notes, offline)
/// in a web view over the editor's text. It draws what it is handed
/// (NoteRenderPayload) and says what was clicked: a link to follow, a task
/// to tick, a tag.
///
/// Everything it loads comes through `overterm-note:` — the bundled page
/// and scripts from the app, the vault's images from the vault, nothing
/// else on disk — and a note's own HTML is sanitized before it is shown.
final class NoteReaderView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    static let scheme = "overterm-note"

    /// A link clicked: the target as written, its `#heading` or `#^block`,
    /// whether it was a Markdown link (a path from the note's folder), and
    /// whether ⌘ was down.
    var onOpenLink: ((_ target: String, _ anchor: String?, _ markdown: Bool, _ newTab: Bool) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onToggleTask: ((_ line: Int) -> Void)?
    var onTag: ((String) -> Void)?
    /// Drawn (mermaid's diagrams count when they are) — for the E2E run.
    private(set) var renderCount = 0
    private(set) var mermaidDrawn = 0

    let webView: WKWebView
    private let resources = NoteResources()
    private var ready = false
    private var pending: String?
    private var pendingAnchor: String?
    private var lastJSON: String?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(NoteMessageProxy(self), name: "note")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/reader.html")!))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The vault whose files the page may load.
    var vaultRoot: URL? {
        get { resources.vaultRoot }
        set { resources.vaultRoot = newValue }
    }

    /// Draws `payload` — not again when nothing changed (the editor asks
    /// on every keystroke while it shows).
    func show(_ payload: NoteRenderPayload, settings: ObsidianSettings, theme: EditorTheme, scrollTo anchor: String? = nil) {
        let folder = (payload.path as NSString).deletingLastPathComponent
        let vaultBase = "\(Self.scheme)://vault/"
        let base = vaultBase + (folder.isEmpty ? "" : Self.encode(folder) + "/")
        let json = payload.json(
            vaultBase: vaultBase, base: base, breaks: !settings.strictLineBreaks, dark: theme.isDark, colors: Self.colors(theme))
        if anchor != nil { pendingAnchor = anchor }
        guard json != lastJSON else {
            scrollToPendingAnchor()
            return
        }
        lastJSON = json
        guard ready else {
            pending = json
            return
        }
        webView.evaluateJavaScript("OT.render(\(json))")
    }

    func scrollTo(anchor: String) {
        pendingAnchor = anchor
        scrollToPendingAnchor()
    }

    private func scrollToPendingAnchor() {
        guard ready, let anchor = pendingAnchor, let quoted = Self.jsString(anchor) else { return }
        pendingAnchor = nil
        webView.evaluateJavaScript("OT.scrollToAnchor(\(quoted))")
    }

    /// Forget what was drawn: the next `show` draws, even the same note.
    func invalidate() { lastJSON = nil }

    /// The rendered text, for checks.
    func renderedText(_ done: @escaping @MainActor (String) -> Void) {
        webView.evaluateJavaScript("OT.text()") { value, _ in
            let text = value as? String ?? ""
            MainActor.assumeIsolated { done(text) }
        }
    }

    // MARK: The page's messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] != nil {
            ready = true
            if let pending {
                self.pending = nil
                webView.evaluateJavaScript("OT.render(\(pending))")
            }
            return
        }
        if body["rendered"] != nil {
            if let mermaid = body["mermaid"] as? Int {
                mermaidDrawn = mermaid
            } else {
                renderCount += 1
                scrollToPendingAnchor()
            }
            return
        }
        if let line = body["toggleTask"] as? Int { onToggleTask?(line) }
        if let tag = body["tag"] as? String { onTag?(tag) }
        if let target = body["open"] as? String {
            onOpenLink?(target, body["anchor"] as? String, body["markdown"] as? Bool ?? false, body["newTab"] as? Bool ?? false)
        }
        if let external = body["external"] as? String, let url = URL(string: external) { onOpenURL?(url) }
    }

    /// Nothing navigates the page away: links are the app's to follow.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = action.request.url
        if url?.scheme == Self.scheme, action.navigationType != .linkActivated, action.targetFrame?.isMainFrame != false {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url, url.scheme != Self.scheme, action.navigationType == .linkActivated { onOpenURL?(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        pending = lastJSON
        webView.reload()
    }

    // MARK: Colours

    /// The editor's theme as the page's CSS variables.
    static func colors(_ theme: EditorTheme) -> [String: String] {
        func css(_ color: NSColor?) -> String {
            guard let rgb = (color ?? theme.text).usingColorSpace(.sRGB) else { return "inherit" }
            return String(
                format: "rgba(%d,%d,%d,%.3f)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255),
                rgb.alphaComponent)
        }
        func style(_ capture: String) -> String { css(theme.style(for: capture)?.color) }
        return [
            "bg": css(theme.background), "fg": css(theme.text), "muted": css(theme.lineNumber), "accent": css(theme.info),
            "border": css(theme.indentGuide), "surface": css(EditorPicker.surface(theme)), "error": css(theme.error),
            "mark": css(theme.warning.withAlphaComponent(0.3)),
            "kw": style("keyword"), "str": style("string"), "num": style("number"), "fn": style("function"), "type": style("type"),
            "comment": style("comment"), "prop": style("property"),
        ]
    }

    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
    }

    static func jsString(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]) else { return nil }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// `overterm-note://app/…` from the app's Resources/notes, and
/// `overterm-note://vault/…` from the vault — a path that leaves either is
/// refused.
final class NoteResources: NSObject, WKURLSchemeHandler {
    var vaultRoot: URL?

    /// Resources/notes inside the app.
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("notes", isDirectory: true) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.mimeType(file.pathExtension), "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func file(for url: URL) -> URL? {
        let base: URL?
        switch url.host {
        case "app": base = Self.bundled
        case "vault": base = vaultRoot
        default: base = nil
        }
        guard let base else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        let file = base.appendingPathComponent(String(path.drop { $0 == "/" })).standardizedFileURL.resolvingSymlinksInPath()
        let root = base.standardizedFileURL.resolvingSymlinksInPath().path
        guard file.path.hasPrefix(root + "/") else { return nil }
        if url.host == "vault" { try? NoteFiles.download(file, timeout: 5) }
        return file
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "woff2": "font/woff2"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "bmp": "image/bmp"
        case "heic": "image/heic"
        case "avif": "image/avif"
        case "pdf": "application/pdf"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        default: "application/octet-stream"
        }
    }
}

/// The content controller holds its handlers strongly: this keeps it from
/// holding the view.
private final class NoteMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
