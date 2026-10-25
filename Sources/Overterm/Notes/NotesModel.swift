import Foundation

/// The vault the app has open — one, whichever window shows it: its tree,
/// its index, and the things done to it (a new note, today's note, a
/// folder). Shared, because the vault is the app's and not a checkout's:
/// two windows on it would read it twice.
///
/// It reads the disk only while a window shows the Notes panel (CLAUDE.md:
/// a panel reads nothing while it is not on screen) — or when something
/// needs the index now: a note open in the editor, an agent asking.
@MainActor
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published private(set) var vault: NotesVault
    @Published private(set) var tree: NoteItem?
    @Published private(set) var index = NotesIndex()
    @Published private(set) var isLoading = false
    /// Counts the index's reloads: what draws from it (the graph) redraws
    /// on a change of links, not only of names.
    @Published private(set) var revision = 0
    /// The name filter over the tree.
    @Published var query = ""
    /// Open folders, by path.
    @Published var expanded: Set<String> = []
    /// The note the editor shows, highlighted in the tree.
    @Published var current: URL?
    /// What the panel's lower half shows; nil when it is folded away.
    @Published var detail: NotesDetail? = NotesDetail(stored: AppEnvironment.defaults.string(forKey: NotesDetail.key)) {
        didSet { AppEnvironment.defaults.set(detail?.rawValue ?? "none", forKey: NotesDetail.key) }
    }
    /// A tag picked in the Tags pane: the tree lists its notes.
    @Published var tagFilter: String?
    /// The Tasks pane over the whole vault rather than the note open.
    @Published var tasksInVault = AppEnvironment.defaults.bool(forKey: "notesTasksInVault") {
        didSet { AppEnvironment.defaults.set(tasksInVault, forKey: "notesTasksInVault") }
    }
    /// Notes whose tasks are folded in the vault's list.
    @Published var foldedTaskNotes: Set<String> = []

    private var showing: Set<ObjectIdentifier> = []
    private var watcher: DirectoryWatcher?
    private var generation = 0
    private var reloadPending = false
    private var waiting: [() -> Void] = []
    private var loadedOnce = false
    private var loadedAt = Date.distantPast

    init(vault: NotesVault? = nil) {
        self.vault = vault ?? NotesVault(root: NotesVault.root(fromSetting: Settings.shared.notesVaultPath))
    }

    /// Whether some window shows the panel.
    var visible: Bool { !showing.isEmpty }

    /// The index has been read at least once.
    var isLoaded: Bool { loadedOnce }

    /// A window says whether its Notes panel is on screen.
    func setVisible(_ visible: Bool, for owner: AnyObject) {
        let was = self.visible
        if visible { showing.insert(ObjectIdentifier(owner)) } else { showing.remove(ObjectIdentifier(owner)) }
        guard self.visible != was else { return }
        if self.visible {
            watch()
            reload()
        } else {
            watcher?.stop()
            watcher = nil
        }
    }

    /// Settings ▸ Notes changed: another vault, read from the start.
    func settingsChanged() {
        let root = NotesVault.root(fromSetting: Settings.shared.notesVaultPath)
        guard root.standardizedFileURL != vault.root else { return }
        vault = NotesVault(root: root)
        generation += 1
        tree = nil
        index = NotesIndex()
        expanded = []
        query = ""
        tagFilter = nil
        loadedOnce = false
        if visible {
            watch()
            reload()
        }
    }

    /// The index, read now if it never was — for a note opened while the
    /// panel isn't showing, and for agents.
    ///
    /// With no panel showing there is no watcher: an index older than a few
    /// seconds is read again first — Obsidian may have written since.
    func whenLoaded(_ body: @escaping () -> Void) {
        let fresh = visible || Date().timeIntervalSince(loadedAt) < 5
        if loadedOnce, !isLoading, fresh {
            body()
            return
        }
        waiting.append(body)
        if !isLoading { reload() }
    }

    /// Reads the tree and the index again, off the main thread; only the
    /// notes whose date changed are parsed.
    func reload() {
        guard !isLoading else {
            reloadPending = true
            return
        }
        isLoading = true
        generation += 1
        let token = generation
        Self.read(vault, previous: index) { [weak self] vault, tree, index in
            guard let self else { return }
            self.isLoading = false
            guard token == self.generation else {
                // The vault changed underneath: read the new one.
                self.reloadPending = false
                self.reload()
                return
            }
            // Obsidian's settings, edited in Obsidian while this runs.
            if vault.settings != self.vault.settings { self.vault = vault }
            self.tree = tree
            self.index = index
            self.revision += 1
            self.loadedOnce = true
            self.loadedAt = Date()
            let waiting = self.waiting
            self.waiting = []
            waiting.forEach { $0() }
            if self.reloadPending {
                self.reloadPending = false
                self.reload()
            }
        }
    }

    /// Built outside the main actor: the queue runs it (CLAUDE.md).
    private nonisolated static func read(
        _ vault: NotesVault, previous: NotesIndex, done: @escaping @MainActor @Sendable (NotesVault, NoteItem, NotesIndex) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { @Sendable in
            let vault = NotesVault(root: vault.root)
            let tree = NoteFiles.tree(of: vault)
            let index = NotesIndex.build(vault, tree: tree, previous: previous)
            DispatchQueue.main.async { @Sendable in
                MainActor.assumeIsolated { done(vault, tree, index) }
            }
        }
    }

    private func watch() {
        watcher?.stop()
        try? FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(root: vault.root, latency: 0.5) { [weak self] paths in
            // Obsidian rewrites its workspace file on nearly every click;
            // its settings are read again with the next reload anyway.
            guard paths.contains(where: { !$0.contains("/.obsidian") && !$0.contains("/.trash") }) else { return }
            self?.reload()
        }
    }

    // MARK: What the lower half shows

    /// The links into the current note, each with the line it sits on —
    /// the index's, read when the note was: drawing the pane reads nothing.
    func backlinkLines(of path: String) -> [(source: String, line: Int, text: String)] {
        index.backlinks(of: path).map { ($0.source, $0.link.line, $0.link.context) }
    }

    // MARK: The vault on this Mac

    /// The vaults to switch between: this one, Obsidian's, and the default.
    var knownVaults: [URL] {
        var seen = Set<String>()
        return ([vault.root] + ObsidianVaults.known() + [NotesVault.defaultRoot]).filter {
            seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    /// Makes `root` the vault, through the setting — Settings is where it is
    /// kept, so every window follows.
    func switchVault(to root: URL) {
        let home = NSHomeDirectory()
        var path = root.standardizedFileURL.path
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        Settings.shared.set("notes.vaultPath", root.standardizedFileURL == NotesVault.defaultRoot.standardizedFileURL ? nil : .string(path))
        settingsChanged()
    }

    // MARK: Making things

    /// A new, empty note — in `folder`, else where Obsidian's settings put
    /// new notes.
    func newNote(in folder: URL?, beside current: URL? = nil) throws -> URL {
        let folder = folder ?? vault.folderForNewNote(beside: current)
        let url = NotesVault.freeName("Untitled", extension: "md", in: folder)
        try NoteFiles.write("", to: url)
        expandFolders(of: url)
        reload()
        return url
    }

    func newFolder(in folder: URL?) throws -> URL {
        let url = NotesVault.freeName("Untitled", extension: "", in: folder ?? vault.root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        expandFolders(of: url.appendingPathComponent("x"))
        reload()
        return url
    }

    /// Today's note (or `date`'s), written from the daily template when it
    /// isn't there yet.
    func dailyNote(for date: Date = Date()) throws -> URL {
        let url = vault.dailyNote(for: date)
        if !FileManager.default.fileExists(atPath: url.path) && !NoteFiles.isEvicted(url) {
            var text = ""
            if let template = vault.template(vault.settings.dailyTemplate), let body = try? NoteFiles.read(template) {
                text = NoteTemplate.apply(body, title: url.deletingPathExtension().lastPathComponent, date: date, settings: vault.settings)
            }
            try NoteFiles.write(text, to: url)
            reload()
        }
        expandFolders(of: url)
        return url
    }

    /// Opens every folder down to `url`, so the tree shows it.
    func expandFolders(of url: URL) {
        var folder = url.deletingLastPathComponent().standardizedFileURL
        // Bounded, and stopping at the root (CLAUDE.md: never walk up to "/").
        for _ in 0..<64 {
            guard vault.contains(folder), folder.path != vault.root.path, folder.pathComponents.count > 1 else { break }
            expanded.insert(folder.path)
            folder = folder.deletingLastPathComponent()
        }
    }

    func collapseAll() { expanded = [] }

    /// A note's path in the vault (`.md` kept), as the index keys it.
    func path(of url: URL) -> String { vault.relativePath(of: url) }

    func url(of path: String) -> URL { vault.root.appendingPathComponent(path) }
}

/// The Notes panel's lower half: Obsidian's side panes.
enum NotesDetail: String, CaseIterable, Identifiable {
    case backlinks, outline, tags, tasks

    static let key = "notesDetail"

    var id: String { rawValue }

    init?(stored: String?) {
        if stored == "none" { return nil }
        self = stored.flatMap(NotesDetail.init(rawValue:)) ?? .backlinks
    }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .backlinks: "arrow.uturn.backward"
        case .outline: "list.bullet.indent"
        case .tags: "number"
        case .tasks: "checklist"
        }
    }
}
