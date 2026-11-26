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
package final class NoteReaderView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    package static let scheme = "overterm-note"

    /// A link clicked: the target as written, its `#heading` or `#^block`,
    /// whether it was a Markdown link (a path from the note's folder), and
    /// whether ⌘ was down.
    package var onOpenLink: ((_ target: String, _ anchor: String?, _ markdown: Bool, _ newTab: Bool) -> Void)?
    package var onOpenURL: ((URL) -> Void)?
    package var onToggleTask: ((_ line: Int) -> Void)?
    package var onTag: ((String) -> Void)?
    /// Drawn (mermaid's diagrams count when they are) — for the E2E run.
    package private(set) var renderCount = 0
    package private(set) var mermaidDrawn = 0
    /// Embedded drawings drawn as pictures — for the E2E run.
    package private(set) var drawingsDrawn = 0

    /// Settings ▸ Notes ▸ Load remote images: each fetched as the note
    /// draws, not only when its Load is pressed.
    package var loadsRemoteImages = false
    /// How a remote image is fetched: the app's own loader (`NoteRemoteImage`),
    /// a test's stand-in.
    package var fetchRemote: @Sendable (URL) async -> NoteRemoteImage? = { await NoteRemoteImage.fetch($0) }
    /// Remote images fetched and handed to the page — for the E2E run.
    package private(set) var remoteImagesShown = 0

    package let webView: WKWebView
    private let resources = NoteResources()
    private var ready = false
    private var pending: String?
    private var pendingAnchor: String?
    private var lastJSON: String?

    package init() {
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
    package required init?(coder: NSCoder) { fatalError() }

    /// The vault whose files the page may load.
    package var vaultRoot: URL? {
        get { resources.vaultRoot }
        set { resources.vaultRoot = newValue }
    }

    /// Draws `payload` — not again when nothing changed (the editor asks
    /// on every keystroke while it shows).
    package func show(_ payload: NoteRenderPayload, settings: ObsidianSettings, theme: EditorTheme, scrollTo anchor: String? = nil) {
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

    package func scrollTo(anchor: String) {
        pendingAnchor = anchor
        scrollToPendingAnchor()
    }

    private func scrollToPendingAnchor() {
        guard ready, let anchor = pendingAnchor, let quoted = Self.jsString(anchor) else { return }
        pendingAnchor = nil
        webView.evaluateJavaScript("OT.scrollToAnchor(\(quoted))")
    }

    /// Forget what was drawn: the next `show` draws, even the same note.
    package func invalidate() { lastJSON = nil }

    /// The rendered text, for checks.
    package func renderedText(_ done: @escaping @MainActor (String) -> Void) {
        webView.evaluateJavaScript("OT.text()") { value, _ in
            let text = value as? String ?? ""
            MainActor.assumeIsolated { done(text) }
        }
    }

    // MARK: The page's messages

    package func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
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
            } else if let drawings = body["drawings"] as? Int {
                drawingsDrawn = drawings
            } else {
                renderCount += 1
                scrollToPendingAnchor()
                if loadsRemoteImages { webView.evaluateJavaScript("OT.loadRemoteImages()") }
            }
            return
        }
        if let src = body["loadImage"] as? String {
            loadRemoteImage(src)
            return
        }
        if let line = body["toggleTask"] as? Int { onToggleTask?(line) }
        if let tag = body["tag"] as? String { onTag?(tag) }
        if let target = body["open"] as? String {
            onOpenLink?(target, body["anchor"] as? String, body["markdown"] as? Bool ?? false, body["newTab"] as? Bool ?? false)
        }
        if let external = body["external"] as? String, let url = URL(string: external) { onOpenURL?(url) }
    }

    /// A remote image asked for: fetched by the app, never by the page
    /// (its policy allows no remote load), and handed to it as data.
    private func loadRemoteImage(_ src: String) {
        guard let url = URL(string: src), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let fetch = fetchRemote
        Task { [weak self] in
            guard let image = await fetch(url), let self, let quotedSource = Self.jsString(src), let quotedData = Self.jsString(image.dataURL) else { return }
            self.remoteImagesShown += 1
            _ = try? await self.webView.evaluateJavaScript("OT.remoteImage(\(quotedSource), \(quotedData))")
        }
    }

    /// Nothing navigates the page away: links are the app's to follow.
    package func webView(
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

    package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        pending = lastJSON
        webView.reload()
    }

    // MARK: Colours

    /// The editor's theme as the page's CSS variables.
    package static func colors(_ theme: EditorTheme) -> [String: String] {
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

    package static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
    }

    package static func jsString(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]) else { return nil }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// `overterm-note://app/…` from the app's Resources/notes, and
/// `overterm-note://vault/…` from the vault — a path that leaves either is
/// refused.
package final class NoteResources: NSObject, WKURLSchemeHandler {
    package var vaultRoot: URL?
    /// Tasks WebKit gave up on: never answered after (it raises).
    private var stopped = Set<ObjectIdentifier>()

    /// Resources/notes inside the app.
    package static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("notes", isDirectory: true) }

    package func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // An image iCloud hasn't downloaded: asked for, answered when it
        // comes — the main thread isn't held meanwhile.
        if NoteFiles.isEvicted(file) {
            let id = ObjectIdentifier(task)
            NoteFiles.whenDownloaded(file) { [weak self] _ in
                guard let self, self.stopped.remove(id) == nil else { return }
                self.answer(task, url: url, file: file)
            }
            return
        }
        answer(task, url: url, file: file)
    }

    private func answer(_ task: WKURLSchemeTask, url: URL, file: URL) {
        guard let data = try? Data(contentsOf: file) else {
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

    package func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    package func file(for url: URL) -> URL? {
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
        return file
    }

    package static func mimeType(_ ext: String) -> String {
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

/// A remote image a note shows, fetched by the app when it is asked for:
/// no cookies, no cache, nothing of the user's sent, an image only and 20 MB
/// at most. An isolated run fetches only from this Mac.
package struct NoteRemoteImage: Sendable, Equatable {
    package let data: Data
    package let mimeType: String

    package static let limit = 20 << 20

    package var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

    /// What a response gave, as an image: refused when it isn't one, or is
    /// too large. Pure.
    package static func accept(_ data: Data, mimeType: String?, status: Int) -> NoteRemoteImage? {
        guard (200..<300).contains(status), let mimeType = mimeType?.lowercased(), mimeType.hasPrefix("image/"), data.count <= limit else { return nil }
        return NoteRemoteImage(data: data, mimeType: mimeType)
    }

    package static func fetch(_ url: URL) async -> NoteRemoteImage? {
        if AppEnvironment.isIsolated || AppEnvironment.isUnitTest {
            guard let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return accept(data, mimeType: http.mimeType, status: http.statusCode)
    }
}
