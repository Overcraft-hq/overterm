import AppKit
import UniformTypeIdentifiers

/// Where apps are looked up and files opened: LaunchServices, or in an
/// isolated run a stand-in that launches nothing (see ExternalOpener.catalog).
@MainActor
protocol AppCatalog: AnyObject {
    /// The installed app with this bundle id (LaunchServices' pick when
    /// there are several copies).
    func app(bundleID: String) -> ExternalApp?
    /// The apps that say they can open `file`.
    func apps(toOpen file: URL) -> [ExternalApp]
    /// What Finder would open `file` with.
    func defaultApp(toOpen file: URL) -> ExternalApp?
    func open(_ file: URL, with app: ExternalApp) async throws
}

/// LaunchServices, through NSWorkspace.
@MainActor
final class SystemApps: AppCatalog {
    /// Files handed to a real app. An isolated run never gets here — its
    /// E2E scenario checks this stays 0.
    private(set) static var launched = 0

    func app(bundleID: String) -> ExternalApp? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(ExternalApp.init(appAt:))
    }

    func apps(toOpen file: URL) -> [ExternalApp] {
        NSWorkspace.shared.urlsForApplications(toOpen: file).compactMap(ExternalApp.init(appAt:))
    }

    func defaultApp(toOpen file: URL) -> ExternalApp? {
        NSWorkspace.shared.urlForApplication(toOpen: file).flatMap(ExternalApp.init(appAt:))
    }

    func open(_ file: URL, with app: ExternalApp) async throws {
        Self.launched += 1
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// An isolated run's apps (AppEnvironment): the ones its scenario installs,
/// and a log of what would have been opened. An E2E run must never launch a
/// real app — as it never touches the real clipboard.
@MainActor
final class IsolatedApps: AppCatalog {
    struct Opened: Equatable {
        let file: URL
        let bundleID: String
    }

    var installed: [ExternalApp] = []
    /// Finder's default among them.
    var defaultBundleID: String?
    private(set) var opened: [Opened] = []

    func app(bundleID: String) -> ExternalApp? { installed.first { $0.bundleID == bundleID } }
    func apps(toOpen file: URL) -> [ExternalApp] { installed }
    func defaultApp(toOpen file: URL) -> ExternalApp? { defaultBundleID.flatMap(app(bundleID:)) }
    func open(_ file: URL, with app: ExternalApp) async throws { opened.append(Opened(file: file, bundleID: app.bundleID)) }
}

extension ExternalApp {
    /// The app bundle at `url`; nil without a bundle id to remember it by.
    init?(appAt url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        self.init(bundleID: bundleID, name: OpenWith.appName(displayName: FileManager.default.displayName(atPath: url.path)), url: url)
    }
}

/// Opens files outside Terminus in the app the user picked (OpenWith): the
/// file tree's double-click and file menu, and the editor's ↗, come here.
/// The first time — or when that app is gone — a sheet asks which app; the
/// answer is remembered (AppEnvironment.defaults) until another is picked
/// from Open With.
@MainActor
final class ExternalOpener: ObservableObject {
    /// LaunchServices — or, in an isolated run, a stand-in whose apps the
    /// scenario installs and which only records what it would open (as an
    /// isolated run gets its own clipboard, GhosttyRuntime.pasteboard).
    static let catalog: AppCatalog = AppEnvironment.isIsolated ? IsolatedApps() : SystemApps()

    let apps: AppCatalog
    private let defaults: UserDefaults
    /// Where the question and errors are shown.
    weak var window: NSWindow?
    /// The remembered app, while it is installed: what "Open in …" and ↗ name.
    @Published private(set) var current: ExternalApp?

    init(apps: AppCatalog = ExternalOpener.catalog, defaults: UserDefaults = AppEnvironment.defaults) {
        self.apps = apps
        self.defaults = defaults
        current = remembered
    }

    /// The remembered app if it is still installed; nil: ask.
    private var remembered: ExternalApp? {
        switch OpenWith.resolve(remembered: defaults.string(forKey: OpenWith.rememberedKey), installed: apps.app(bundleID:)) {
        case .open(let app): app
        case .ask: nil
        }
    }

    /// A double-click, "Open in …", ↗: the remembered app, or — nothing
    /// remembered, or it is gone — a sheet asking which. Nil when it asks.
    @discardableResult
    func open(_ file: URL) -> Task<Void, Never>? {
        let app = remembered
        if current != app { current = app }
        guard let app else {
            ask(for: file)
            return nil
        }
        return launch(file, with: app)
    }

    /// A pick from Open With or the sheet: open it there, and from now on.
    @discardableResult
    func open(_ file: URL, with app: ExternalApp) -> Task<Void, Never> {
        defaults.set(app.bundleID, forKey: OpenWith.rememberedKey)
        if current != app { current = app }
        return launch(file, with: app)
    }

    /// Open With for `file`: its candidate apps, then Other….
    func entries(for file: URL) -> [OpenWith.Entry] {
        let systemDefault = apps.defaultApp(toOpen: file)
        // Looked up again rather than `current`, which is not refreshed
        // here: this runs while a menu is built (in SwiftUI, during a view
        // update), where publishing is not allowed.
        let current = remembered
        let candidates = OpenWith.candidates(
            editors: OpenWith.editors.compactMap(apps.app(bundleID:)), current: current, systemDefault: systemDefault,
            canOpen: apps.apps(toOpen: file), excluding: Bundle.main.bundleIdentifier)
        return OpenWith.entries(candidates: candidates, systemDefault: systemDefault?.bundleID, current: current?.bundleID)
    }

    /// Open With as a menu (right-click on the editor's ↗).
    func menu(for file: URL) -> NSMenu {
        let menu = NSMenu()
        for entry in entries(for: file) {
            switch entry {
            case .app(let app, let title, let isCurrent):
                let item = ClosureMenuItem(title, state: isCurrent ? .on : .off) { [weak self] in self?.open(file, with: app) }
                item.image = icon(for: app)
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            case .other:
                menu.addItem(ClosureMenuItem(OpenWith.otherTitle) { [weak self] in self?.chooseApp(for: file) })
            }
        }
        return menu
    }

    /// Other…: any application, from a panel.
    func chooseApp(for file: URL) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Open"
        panel.message = "Open “\(file.lastPathComponent)” — and files after it — with:"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let app = ExternalApp(appAt: url) else { return }
            self?.open(file, with: app)
        }
    }

    func icon(for app: ExternalApp) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// The question: a sheet with the candidates in a pop-up, the first
    /// preselected (an editor, if one is installed).
    private func ask(for file: URL) {
        guard let window else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for entry in entries(for: file) {
            switch entry {
            case .app(let app, let title, _):
                // Added as items, not by title: addItem(withTitle:) drops an
                // earlier item with the same title.
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = icon(for: app)
                item.representedObject = app
                popup.menu?.addItem(item)
            case .divider:
                popup.menu?.addItem(.separator())
            case .other:
                popup.menu?.addItem(NSMenuItem(title: OpenWith.otherTitle, action: nil, keyEquivalent: ""))
            }
        }
        popup.selectItem(at: 0)
        let alert = NSAlert()
        alert.messageText = OpenWith.question
        alert.informativeText = "“\(file.lastPathComponent)” and every file after it open there. Change it any time under Open With."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let app = popup.selectedItem?.representedObject as? ExternalApp {
                self.open(file, with: app)
            } else {
                self.chooseApp(for: file)
            }
        }
    }

    private func launch(_ file: URL, with app: ExternalApp) -> Task<Void, Never> {
        Task { [apps, weak self] in
            do {
                try await apps.open(file, with: app)
            } catch {
                guard let window = self?.window else { return }
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
