import AppKit
import OSLog
import WebKit

/// A drawing in the editor: Excalidraw (Resources/notes/draw.html, the
/// bundled Excalidraw, offline) over the file's scene. It shows what it is
/// handed and says what changed — the editor writes that into the file's
/// text (`DrawingFile`), so a drawing is saved, reloaded and diffed like
/// any file.
///
/// Like the reading view, it loads only `overterm-note://app/…`; links on
/// elements are the app's to follow.
final class DrawingView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The scene changed: its text as `encoding` has it, and the text elements.
    var onChange: ((_ scene: String, _ encoding: DrawingFile.Encoding, _ texts: [DrawingFile.Text]) -> Void)?
    /// An element's link was clicked: a URL or a note's name, as written.
    var onOpenLink: ((String) -> Void)?
    /// The scene couldn't be read: the editor shows the text instead.
    var onError: ((String) -> Void)?

    let webView: WKWebView
    private let resources = NoteResources()
    private(set) var ready = false
    /// The page's last error, for the log and the E2E run.
    private(set) var lastLog: String?
    private static let logger = Logger(subsystem: AppEnvironment.bundleIdentifier, category: "drawing")
    private var pending: String?
    private var lastLoad: String?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: NoteReaderView.scheme)
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(DrawingMessageProxy(self), name: "draw")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        webView.load(URLRequest(url: URL(string: "\(NoteReaderView.scheme)://app/draw.html")!))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `file`'s scene; a change is written back as `saveAs`.
    func load(_ file: DrawingFile, saveAs: DrawingFile.Encoding, dark: Bool) {
        let call = Self.call(
            "OT.load", ["scene": file.scene, "encoding": file.encoding.rawValue, "saveAs": saveAs.rawValue, "dark": dark])
        lastLoad = call
        guard ready else {
            pending = call
            return
        }
        webView.evaluateJavaScript(call)
    }

    func setDark(_ dark: Bool) {
        guard ready else { return }
        webView.evaluateJavaScript("OT.theme(\(dark))")
    }

    /// Sends what the page is holding back (it waits a moment after a change).
    func flush() {
        guard ready else { return }
        webView.evaluateJavaScript("OT.flush()")
    }

    /// Runs `OT.<function>(argument)` and hands back its answer — for an
    /// agent's elements and the E2E run.
    /// `spread`: `argument` is the list of arguments, not the one argument.
    func call(_ function: String, _ argument: Any, spread: Bool = false, done: @escaping @MainActor (Any?) -> Void) {
        webView.evaluateJavaScript(Self.call("OT." + function, argument, spread: spread)) { [weak self] value, error in
            MainActor.assumeIsolated {
                if let error { self?.lastLog = "\(function): \(error)" }
                done(value)
            }
        }
    }

    /// What is on the canvas — for checks.
    struct State: Sendable {
        var ready = false
        var count = 0
        var texts: [String] = []
        /// The page's width, Excalidraw's box in it, and the width Excalidraw thinks it has.
        var page = 0
        var width = 0
        var appWidth = 0
    }

    func state() async -> State {
        await withCheckedContinuation { continuation in
            call("state", NSNull()) { value in
                let body = value as? [String: Any] ?? [:]
                let texts = (body["texts"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                continuation.resume(
                    returning: State(
                        ready: body["ready"] as? Bool ?? false, count: body["count"] as? Int ?? 0, texts: texts,
                        page: body["page"] as? Int ?? 0, width: body["width"] as? Int ?? 0, appWidth: body["appWidth"] as? Int ?? 0))
            }
        }
    }

    static func call(_ function: String, _ argument: Any, spread: Bool = false) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: spread ? argument : [argument])) ?? Data("[null]".utf8)
        return function + "(" + String(String(decoding: data, as: UTF8.self).dropFirst().dropLast()) + ")"
    }

    // MARK: The page's messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] != nil {
            ready = true
            if let pending {
                self.pending = nil
                webView.evaluateJavaScript(pending)
            }
            return
        }
        if let change = body["change"] as? [String: Any], let scene = change["scene"] as? String,
            let encoding = (change["encoding"] as? String).flatMap(DrawingFile.Encoding.init(rawValue:))
        {
            let texts = (change["texts"] as? [[String: Any]] ?? []).compactMap { entry -> DrawingFile.Text? in
                guard let id = entry["id"] as? String, let text = entry["text"] as? String else { return nil }
                return DrawingFile.Text(id: id, text: text)
            }
            onChange?(scene, encoding, texts)
        }
        if let link = body["link"] as? String { onOpenLink?(link) }
        if let log = body["log"] as? String {
            lastLog = log
            Self.logger.error("drawing page: \(log, privacy: .public)")
        }
        if let error = body["error"] as? String { onError?(error) }
    }

    /// Nothing navigates the page away, and nothing opens a window.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = action.request.url
        let allowed = url?.scheme == NoteReaderView.scheme && action.navigationType != .linkActivated && action.targetFrame?.isMainFrame != false
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url?.absoluteString { onOpenLink?(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        pending = lastLoad
        webView.reload()
    }
}

/// Turns an agent's element skeletons into a scene, with Excalidraw itself
/// (its `convertToExcalidrawElements` lays out labels and binds arrows) —
/// on a page no window shows.
@MainActor
final class DrawingConverter {
    static let shared = DrawingConverter()
    /// Opens a drawing an agent made — the front window's editor.
    static var open: ((URL) -> Void)?

    private var view: DrawingView?

    func convert(_ skeletons: [[String: Any]], saveAs: DrawingFile.Encoding) async throws -> (scene: String, texts: [DrawingFile.Text]) {
        let view = self.view ?? DrawingView()
        self.view = view
        for _ in 0..<100 where !view.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        guard view.ready else { throw BrowserMCP.ToolError(message: "The drawing page didn't load.") }
        let drawn: (scene: String, texts: [DrawingFile.Text])? = await withCheckedContinuation { continuation in
            view.call("convert", [skeletons, saveAs.rawValue] as [Any], spread: true) { value in
                guard let answer = value as? [String: Any], let scene = answer["scene"] as? String else {
                    return continuation.resume(returning: nil)
                }
                let texts = (answer["texts"] as? [[String: Any]] ?? []).compactMap { entry -> DrawingFile.Text? in
                    guard let id = entry["id"] as? String, let text = entry["text"] as? String else { return nil }
                    return DrawingFile.Text(id: id, text: text)
                }
                continuation.resume(returning: (scene, texts))
            }
        }
        guard let drawn else {
            throw BrowserMCP.ToolError(message: "Excalidraw couldn't read those elements: \(view.lastLog ?? "check their types and fields").")
        }
        return drawn
    }
}

/// The content controller holds its handlers strongly: this keeps it from
/// holding the view.
private final class DrawingMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
