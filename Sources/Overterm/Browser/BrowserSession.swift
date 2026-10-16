import AppKit
import Combine
import WebKit

/// One tab's browser: a WKWebView (the system's WebKit — nothing bundled),
/// what it shows, what its page logged, and what an agent can do with it.
/// It lives as long as the tab, shown in the browser column while its tab
/// is selected and parked off screen otherwise — so its page keeps running
/// and an agent in a background tab can still use it.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    struct ConsoleEntry: Equatable, Identifiable {
        let id: Int
        let level: String
        let message: String
        let time: Date
    }

    /// Cookies and storage, shared by every page of every tab (a popup
    /// shares its opener's, which is this one too). An isolated run (E2E, a
    /// layout dump) keeps none of the user's.
    static let dataStore: WKWebsiteDataStore = AppEnvironment.isIsolated ? .nonPersistent() : .default()

    let webView: WKWebView
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var console: [ConsoleEntry] = []
    @Published private(set) var errorCount = 0
    /// A link opening another window, or a download — handed to the window.
    var onOpenExternally: ((URL) -> Void)?
    /// target=_blank, window.open: a new page in the same browser (its tab
    /// strip), made with WebKit's configuration so the opener can talk to it.
    var onOpenPage: ((WKWebViewConfiguration, URL?) -> WKWebView?)?

    private var watcher: KeyValueWatcher?
    private var loads: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextEntry = 0
    static let consoleLimit = 500

    /// `configuration`: WebKit's, for a page another one opened.
    init(configuration given: WKWebViewConfiguration? = nil) {
        let configuration = given ?? WKWebViewConfiguration()
        if given == nil { configuration.websiteDataStore = Self.dataStore }
        configuration.preferences.isElementFullscreenEnabled = true
        // The hammer opens the Web Inspector through WebKit's own
        // `_inspector`, which does nothing at all until developer extras
        // are on: `isInspectable` below only buys the right-click Inspect
        // Element. Measured — with this, `show` connects and the inspector
        // comes up; without it even `connect` is ignored.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // A page of its own's console: a fresh controller even for a popup,
        // whose configuration carries its opener's.
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        configuration.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), contentWorld: .page, name: "overterm")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Safari's Web Inspector, from the toolbar or a right-click.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.setAccessibilityIdentifier("browserWebView")
        watcher = KeyValueWatcher(webView, ["URL", "title", "canGoBack", "canGoForward", "loading", "estimatedProgress"]) { [weak self] in
            MainActor.assumeIsolated { self?.syncState() }
        }
        BrowserParking.shared.park(webView)
    }

    private func syncState() {
        if url != webView.url { url = webView.url }
        if title != webView.title ?? "" { title = webView.title ?? "" }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
    }

    func close() {
        watcher = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "overterm", contentWorld: .page)
        webView.removeFromSuperview()
        failLoads(CancellationError())
    }

    // MARK: Navigation

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Loads `url` and waits for it (or `timeout`): what an agent's
    /// navigate does before it reads the page.
    func navigate(_ url: URL, timeout: TimeInterval = 20) async throws {
        load(url)
        try await waitForLoad(timeout: timeout)
    }

    func waitForLoad(timeout: TimeInterval = 20) async throws {
        guard webView.isLoading else { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loads.append((id, continuation))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let index = self.loads.firstIndex(where: { $0.id == id }) else { return }
                    self.loads.remove(at: index).continuation.resume(throwing: BrowserError.timedOut)
                }
            }
        }
    }

    private func finishLoads() {
        let waiting = loads
        loads = []
        waiting.forEach { $0.continuation.resume() }
    }

    private func failLoads(_ error: Error) {
        let waiting = loads
        loads = []
        waiting.forEach { $0.continuation.resume(throwing: error) }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new page: its console is the one that matters.
        console = []
        errorCount = 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoads() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("error", "Load failed: \(error.localizedDescription)")
        finishLoads()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // A link that only started a download, or a cancelled load, isn't a failure to show.
        if nsError.code != NSURLErrorCancelled {
            log("error", "Couldn't load \(nsError.userInfo[NSURLErrorFailingURLStringErrorKey] ?? ""): \(error.localizedDescription)")
            webView.loadHTMLString(Self.errorPage(error.localizedDescription), baseURL: nil)
        }
        finishLoads()
    }

    /// target=_blank and window.open: in this browser, not a new window.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let open = onOpenPage { return open(configuration, navigationAction.request.url) }
        if let url = navigationAction.request.url { load(url) }
        return nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // mailto:, tel:, an app's own scheme: the system's.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
            !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme)
        {
            onOpenExternally?(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        log("info", "alert: \(message)")
        let alert = NSAlert()
        alert.messageText = message
        if let window = webView.window, !BrowserParking.shared.holds(webView) {
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        } else {
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        log("info", "confirm: \(message)")
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window = webView.window, !BrowserParking.shared.holds(webView) {
            alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(true)
        }
    }

    // MARK: The console

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        log(body["level"] as? String ?? "log", body["message"] as? String ?? "")
    }

    private func log(_ level: String, _ message: String) {
        nextEntry += 1
        console.append(ConsoleEntry(id: nextEntry, level: level, message: String(message.prefix(4000)), time: Date()))
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
        if level == "error" { errorCount += 1 }
    }

    func clearConsole() {
        console = []
        errorCount = 0
    }

    /// The console as text, for an agent: `[error] message`, oldest first.
    func consoleText(onlyErrors: Bool = false, limit: Int = 200) -> String {
        let entries = console.filter { !onlyErrors || $0.level == "error" || $0.level == "warn" }.suffix(limit)
        return entries.map { "[\($0.level)] \($0.message)" }.joined(separator: "\n")
    }

    // MARK: For agents

    /// The page as an agent reads it: title, address, its visible text,
    /// and each control it can act on, with a ref (`e3`) to click or type
    /// into — refs hold until the next snapshot.
    func snapshot() async throws -> String {
        let raw = try await webView.callAsyncJavaScript(Self.snapshotScript, arguments: [:], in: nil, contentWorld: .page)
        guard let json = raw as? String, let data = json.data(using: .utf8),
            let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BrowserError.script("The page didn't answer.") }
        var out = "Page: \(page["title"] as? String ?? "")\nURL: \(page["url"] as? String ?? "")\n"
        if let elements = page["elements"] as? [[String: Any]], !elements.isEmpty {
            out += "\nControls (use the ref):\n"
            for element in elements {
                var line = "- [\(element["ref"] as? String ?? "")] \(element["role"] as? String ?? "") “\(element["name"] as? String ?? "")”"
                if let value = element["value"] as? String, !value.isEmpty { line += " value=“\(value)”" }
                out += line + "\n"
            }
        }
        out += "\nText:\n\(page["text"] as? String ?? "")"
        return out
    }

    func click(ref: String) async throws {
        let answer = try await webView.callAsyncJavaScript(
            """
            const el = document.querySelector(`[data-overterm-ref="${ref}"]`);
            if (!el) return 'missing';
            el.scrollIntoView({block: 'center'});
            if (el.focus) el.focus();
            el.click();
            return 'ok';
            """, arguments: ["ref": ref], in: nil, contentWorld: .page)
        guard answer as? String == "ok" else { throw BrowserError.noElement(ref) }
    }

    /// Types `text` into a field (replacing what is there) the way a
    /// framework notices — its own value setter, then input and change.
    func type(ref: String, text: String, submit: Bool) async throws {
        let answer = try await webView.callAsyncJavaScript(
            """
            const el = document.querySelector(`[data-overterm-ref="${ref}"]`);
            if (!el) return 'missing';
            el.focus();
            if (el.isContentEditable) {
              el.textContent = text;
            } else {
              const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
                : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value');
              if (setter && setter.set) { setter.set.call(el, text); } else { el.value = text; }
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            if (submit) {
              const enter = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true};
              el.dispatchEvent(new KeyboardEvent('keydown', enter));
              el.dispatchEvent(new KeyboardEvent('keyup', enter));
              if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
            }
            return 'ok';
            """, arguments: ["ref": ref, "text": text, "submit": submit], in: nil, contentWorld: .page)
        guard answer as? String == "ok" else { throw BrowserError.noElement(ref) }
    }

    /// Runs JavaScript in the page; its value (JSON for objects) as text.
    func evaluate(_ script: String) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            """
            const value = await (async () => { return eval(source); })();
            if (value === undefined) return 'undefined';
            if (typeof value === 'string') return value;
            try { return JSON.stringify(value, null, 2); } catch (e) { return String(value); }
            """, arguments: ["source": script], in: nil, contentWorld: .page)
        return value as? String ?? String(describing: value ?? "undefined")
    }

    /// What is on screen, as a PNG.
    func screenshot() async throws -> Data {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { throw BrowserError.script("No screenshot.") }
        return png
    }

    // MARK: Scripts

    /// Every console call, uncaught error and unhandled rejection, to
    /// the app as well as to the page's own console.
    static let consoleScript = """
        (function () {
          if (window.__overtermConsole) return;
          window.__overtermConsole = true;
          const send = (level, args) => {
            try {
              const message = Array.from(args).map(a => {
                if (typeof a === 'string') return a;
                if (a instanceof Error) return a.stack || a.message;
                try { return JSON.stringify(a); } catch (e) { return String(a); }
              }).join(' ');
              window.webkit.messageHandlers.overterm.postMessage({level, message});
            } catch (e) {}
          };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            console[level] = function (...args) { send(level, args); return original.apply(this, args); };
          }
          window.addEventListener('error', e => send('error', [e.message + (e.filename ? ` (${e.filename}:${e.lineno})` : '')]));
          window.addEventListener('unhandledrejection', e => {
            const r = e.reason;
            send('error', ['Unhandled rejection: ' + (r && (r.stack || r.message) || r)]);
          });
        })();
        """

    static let snapshotScript = """
        document.querySelectorAll('[data-overterm-ref]').forEach(e => e.removeAttribute('data-overterm-ref'));
        const selector = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[role=switch],[onclick],[contenteditable=true]';
        const elements = [];
        let n = 0;
        for (const el of document.querySelectorAll(selector)) {
          const r = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          if (r.width === 0 || r.height === 0 || style.visibility === 'hidden' || style.display === 'none') continue;
          if (el.type === 'hidden') continue;
          const ref = 'e' + (++n);
          el.setAttribute('data-overterm-ref', ref);
          let role = el.getAttribute('role') || el.tagName.toLowerCase();
          if (el.type && el.tagName !== 'BUTTON') role += '[' + el.type + ']';
          const name = (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.title || el.getAttribute('href') || el.name || '')
            .trim().replace(/\\s+/g, ' ').slice(0, 80);
          const value = ('value' in el && el.tagName !== 'BUTTON' && el.type !== 'submit') ? String(el.value).slice(0, 80) : '';
          elements.push({ref, role, name, value});
          if (elements.length >= 300) break;
        }
        const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 8000);
        return JSON.stringify({title: document.title, url: location.href, text, elements});
        """

    private static func errorPage(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
            <html><body style="font: 14px -apple-system; color: #999; background: #1e1f22; display: flex; align-items: center;
            justify-content: center; height: 90vh; text-align: center"><div><div style="font-size: 32px">⚠︎</div>
            <p>\(escaped)</p><p style="font-size: 12px">Is the server running?</p></div></body></html>
            """
    }
}

enum BrowserError: LocalizedError {
    case timedOut
    case noElement(String)
    case script(String)
    case noBrowser
    case noTab(Int)

    var errorDescription: String? {
        switch self {
        case .timedOut: "The page took too long to load."
        case .noElement(let ref): "No element \(ref) — take a new snapshot; refs change with the page."
        case .script(let message): message
        case .noBrowser: "No browser for this tab — is Settings ▸ Browser on?"
        case .noTab(let index): "No tab \(index) — browser_tabs lists them."
        }
    }
}

/// KVO on the web view, outside the main actor: WebKit reports some of
/// these from its own threads, and a handler written in a @MainActor type
/// traps there (CLAUDE.md — dispatch_assert_queue: it took the app down as
/// the first page loaded). Every change asks for a read on the main queue.
final class KeyValueWatcher: NSObject, @unchecked Sendable {
    private let object: NSObject
    private let keys: [String]
    private let changed: @Sendable () -> Void

    init(_ object: NSObject, _ keys: [String], changed: @escaping @Sendable () -> Void) {
        self.object = object
        self.keys = keys
        self.changed = changed
        super.init()
        for key in keys { object.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    deinit {
        for key in keys { object.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async(execute: changed)
    }
}

/// WKUserContentController holds its handler strongly; this keeps the
/// session from living forever through it.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Where a tab's page waits while its tab isn't showing: a window off every
/// screen, so the page keeps rendering (an agent's screenshot of a
/// background tab isn't blank) and its timers keep running.
@MainActor
final class BrowserParking {
    static let shared = BrowserParking()
    private let window: NSWindow

    private init() {
        window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.orderFrontRegardless()
        window.orderBack(nil)
    }

    func park(_ view: WKWebView) {
        guard let content = window.contentView, view.superview !== content else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    func holds(_ view: WKWebView) -> Bool { view.window === window }
}
