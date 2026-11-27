import AppKit
import Combine
import WebKit

/// A terminal tab's browser: its pages — the browser's own tabs, as
/// Safari's — and which one shows. An agent in the tab acts on the page
/// that shows, and can open, pick and close pages (BrowserMCP).
@MainActor
package final class BrowserWorkspace: ObservableObject {
    package init() {}

    @Published package private(set) var pages: [BrowserSession] = []
    @Published package private(set) var activeIndex = 0
    package var onOpenExternally: ((URL) -> Void)?
    /// A page, its title or its address changed: the strip redraws.
    package let changed = PassthroughSubject<Void, Never>()
    private var pageObservers: [ObjectIdentifier: AnyCancellable] = [:]

    package var active: BrowserSession? { pages.indices.contains(activeIndex) ? pages[activeIndex] : nil }

    /// A new page — after the one showing — loading `url` if given.
    @discardableResult
    package func newPage(_ url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> BrowserSession {
        let page = BrowserSession(configuration: configuration)
        page.onOpenExternally = { [weak self] in self?.onOpenExternally?($0) }
        // An agent's call holds every page of the tab, a popup it opens too.
        page.agentGuard = { [weak self] url in self?.agentGuard?(url) ?? true }
        page.onAgentBlocked = { [weak self] in self?.blocked = $0 }
        page.onOpenPage = { [weak self] configuration, url in
            // window.open hands the page its URL itself; a plain _blank link
            // has nothing to load until WebKit does.
            self?.newPage(nil, configuration: configuration).webView
        }
        let index = pages.isEmpty ? 0 : min(activeIndex + 1, pages.count)
        pages.insert(page, at: index)
        pageObservers[ObjectIdentifier(page)] = page.$title.combineLatest(page.$url, page.$isLoading)
            .sink { [weak self] _, _, _ in self?.changed.send() }
        if select { activeIndex = index }
        if let url { page.load(url) }
        changed.send()
        return page
    }

    package func select(_ index: Int) {
        guard pages.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        changed.send()
    }

    /// Closes a page; its neighbour shows. The last one closing leaves the
    /// browser empty (its ports to open, an address to type).
    package func close(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        let page = pages.remove(at: index)
        pageObservers[ObjectIdentifier(page)] = nil
        page.close()
        if activeIndex >= pages.count { activeIndex = max(0, pages.count - 1) } else if index < activeIndex { activeIndex -= 1 }
        changed.send()
    }

    package func closeAll() {
        while !pages.isEmpty { close(pages.count - 1) }
    }

    /// What the session file keeps: each page's address and which shows.
    package var savedPages: (urls: [URL], active: Int)? {
        let urls = pages.compactMap { $0.url.flatMap { $0.isFileURL || $0.scheme == "about" || $0.scheme == "data" ? nil : $0 } }
        return urls.isEmpty ? nil : (urls, min(activeIndex, urls.count - 1))
    }

    /// The page an agent's call is about: the one showing, made if none.
    private var current: BrowserSession { active ?? newPage() }

    /// Set for the length of an agent's call (`AgentBrowser.agentGuard`).
    package var agentGuard: ((URL) -> Bool)?
    /// The navigation it stopped last.
    private var blocked: BlockedNavigation?
}

extension BrowserWorkspace: AgentBrowser {
    package func navigate(_ url: URL, timeout: TimeInterval) async throws { try await current.navigate(url, timeout: timeout) }
    package func snapshot() async throws -> String { try await current.snapshot() }
    package func click(ref: String) async throws { try await current.click(ref: ref) }
    package func type(ref: String, text: String, submit: Bool) async throws { try await current.type(ref: ref, text: text, submit: submit) }
    package func evaluate(_ script: String) async throws -> String { try await current.evaluate(script) }
    package func screenshot() async throws -> Data { try await current.screenshot() }
    package func consoleText(onlyErrors: Bool, limit: Int) -> String { active?.consoleText(onlyErrors: onlyErrors, limit: limit) ?? "" }
    package func goBack() { active?.goBack() }
    package func reload() { active?.reload() }
    package func waitForLoad(timeout: TimeInterval) async throws { try await active?.waitForLoad(timeout: timeout) }

    package func tabsDescription() -> String {
        guard !pages.isEmpty else { return "No pages open." }
        return pages.enumerated().map { index, page in
            "\(index == activeIndex ? "*" : " ") [\(index)] \(page.title.isEmpty ? "(untitled)" : page.title) — \(page.url?.absoluteString ?? "about:blank")"
        }.joined(separator: "\n")
    }

    package func openTab(_ url: URL?, timeout: TimeInterval) async throws {
        let page = newPage()
        if let url { try await page.navigate(url, timeout: timeout) }
    }

    package func selectTab(_ index: Int) throws {
        guard pages.indices.contains(index) else { throw BrowserError.noTab(index) }
        select(index)
    }

    package func closeTab(_ index: Int) throws {
        guard pages.indices.contains(index) else { throw BrowserError.noTab(index) }
        close(index)
    }

    package var currentURL: URL? { active?.webView.url ?? active?.url }

    package func takeBlockedNavigation() -> BlockedNavigation? {
        defer { blocked = nil }
        return blocked
    }
}
