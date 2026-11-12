import Foundation

/// A kubectl-family command a pane runs, as its title says it
/// (`CommandLedger`): `kubectl`, `helm`, `k9s` or `stern` — nothing else
/// is looked at (analysis 3.11) — and the flags that say where it goes.
/// Pure: the line is read as a shell would split it, never run.
struct KubeCommandLine: Equatable, Sendable {
    static let tools: Set<String> = ["kubectl", "helm", "k9s", "stern"]

    var tool: String
    /// `--context` (helm: `--kube-context`).
    var context: String?
    /// `--kubeconfig`, else a `KUBECONFIG=…` before the command: the files
    /// it reads instead of the pane's.
    var kubeconfig: String?

    /// The first kubectl-family command of the line — in a pipeline, after
    /// `&&` or `;`, behind `sudo`, `env`, `time`, `watch` or assignments
    /// (`ShellCommandLine`).
    static func parse(_ line: String) -> KubeCommandLine? {
        for command in ShellCommandLine.commands(in: line) where tools.contains(command.tool) {
            return make(command)
        }
        return nil
    }

    private static func make(_ command: ShellCommandLine.Command) -> KubeCommandLine {
        let assigned = command.assigned("KUBECONFIG")
        var line = KubeCommandLine(tool: command.tool, context: nil, kubeconfig: assigned.flatMap { $0.isEmpty ? nil : $0 })
        let contextFlag = command.tool == "helm" ? "--kube-context" : "--context"
        var rest = command.arguments.makeIterator()
        while let word = rest.next() {
            if word == "--" { break }
            for (flag, set) in [(contextFlag, true), ("--kubeconfig", false)] {
                let value: String?
                if word == flag {
                    value = rest.next()
                } else if word.hasPrefix(flag + "=") {
                    value = String(word.dropFirst(flag.count + 1))
                } else {
                    continue
                }
                guard let value, !value.isEmpty else { continue }
                if set { line.context = value } else { line.kubeconfig = value }
            }
        }
        return line
    }
}

/// The pane header's warning (3.11): the context a kubectl-family command
/// in the pane reaches, from what Overterm can know — in this order, the
/// command's `--context` (`--kube-context` for helm) and `--kubeconfig`;
/// else the tab's pinned context; else the `current-context` of the files
/// a plain kubectl reads (the captured `KUBECONFIG`, else `~/.kube/config`).
/// Overterm can't see a pane's own environment — a `KUBECONFIG` exported in
/// that shell — so when only the files settle it, the warning says
/// "probably". Pure: the files are read elsewhere (`KubeAmbientContexts`).
struct KubePaneWarning: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `--context` / `--kube-context` on the line.
        case flag
        /// `--kubeconfig`, or a `KUBECONFIG=` before the command: that file's `current-context`.
        case kubeconfigFlag
        /// The pane's pin (Terminal in this context).
        case pinned
        /// The files a plain kubectl reads; the shell may have its own `KUBECONFIG`.
        case files
    }

    var tool: String
    var context: String
    var displayName: String
    var isProduction: Bool
    var source: Source

    var probably: Bool { source == .files }

    /// `⎈ acme-prod`, `⎈ probably acme-prod`.
    var label: String { "⎈ " + (probably ? "probably " : "") + displayName }

    var help: String {
        let reaches = "\(tool) here \(probably ? "probably " : "")reaches \(context)\(isProduction ? " — PRODUCTION" : "")"
        switch source {
        case .flag: return reaches + ": the command names it."
        case .kubeconfigFlag: return reaches + ": the kubeconfig the command names says so."
        case .pinned: return reaches + ": the pane is pinned to it."
        case .files:
            return reaches
                + ": it is the current context of your kubeconfig. A KUBECONFIG exported in this shell would change that, and Overterm can't see it — "
                + "Terminal in this context pins a tab for certain."
        }
    }

    /// Whether the header shows it: production only, and not a pin's own —
    /// the pin's label says that already, in the same red.
    var shown: Bool { isProduction && source != .pinned }

    /// What `command` reaches. `ambient` is the plain kubectl's files read;
    /// `kubeconfig` reads a file a command names (nil while unread);
    /// `paneFiles`, the files the pane's own `KUBECONFIG` names (a pin's
    /// file, then Overterm's, `kubernetes.kubeconfigs` too) — where a
    /// `--context` in a pinned pane is looked up. `lost`: a pane whose pin
    /// couldn't be restored (`KUBECONFIG=/dev/null`) reaches nothing unless
    /// the command says otherwise. The class is the current settings' and
    /// the name's, as the page classes it.
    static func resolve(
        command: String?, pin: KubeTerminalPin?, lost: Bool, ambient: KubeContextList?, paneFiles: KubeContextList? = nil,
        kubeconfig: (String) -> KubeContextList?, settings: [String: KubeContextSettings]
    ) -> KubePaneWarning? {
        guard let command, let line = KubeCommandLine.parse(command) else { return nil }
        let named = line.kubeconfig.flatMap(kubeconfig)
        if let name = line.context {
            return make(line.tool, name, in: named ?? paneFiles ?? ambient, settings: settings, .flag)
        }
        if line.kubeconfig != nil {
            guard let named, let current = named.current else { return nil }
            return make(line.tool, current, in: named, settings: settings, .kubeconfigFlag)
        }
        if lost { return nil }
        if let pin {
            guard !pin.context.isEmpty else { return nil }
            let settled = settings[pin.context] ?? KubeContextSettings()
            let production = KubeClassifier.classify(context: pin.context, cluster: pin.cluster, set: settled.contextClass) == .production
            return KubePaneWarning(
                tool: line.tool, context: pin.context, displayName: settled.displayName ?? pin.displayName, isProduction: production || pin.isProduction,
                source: .pinned)
        }
        guard let ambient, let current = ambient.current else { return nil }
        return make(line.tool, current, in: ambient, settings: settings, .files)
    }

    /// A kubeconfig a command or a pane names, as the absolute paths it
    /// lists, `:`-joined: `~`, `$HOME` and `${HOME}` expanded, a relative
    /// path (`--kubeconfig ./prod.yaml`) against the folder the command ran
    /// in. Nil when nothing in it can be placed.
    static func kubeconfigKey(_ value: String, cwd: String?, home: URL) -> String? {
        let urls = KubeconfigSources.list(value, home: home, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
        return urls.isEmpty ? nil : urls.map(\.standardizedFileURL.path).joined(separator: ":")
    }

    private static func make(_ tool: String, _ name: String, in list: KubeContextList?, settings: [String: KubeContextSettings], _ source: Source)
        -> KubePaneWarning
    {
        let own = settings[name] ?? KubeContextSettings()
        let cluster = list?.context(named: name)?.cluster ?? ""
        return KubePaneWarning(
            tool: tool, context: name, displayName: own.displayName ?? name,
            isProduction: KubeClassifier.classify(context: name, cluster: cluster, set: own.contextClass) == .production, source: source)
    }
}


/// The files a plain kubectl in a tab reads, read for the warning — never
/// run, never written: `AppEnvironment.kubeconfigs` without the setting's
/// extras (the captured `KUBECONFIG`, else `~/.kube/config`), any file a
/// command's `--kubeconfig` names, and a pinned pane's own `KUBECONFIG`.
/// Guarded (an isolated run, a unit test), a named file is read only when
/// it is one of `OVERTERM_KUBECONFIG`'s or a pin's own file
/// (`admitted`) — never the user's. Read the first time a kubectl-family
/// command shows in a pane, then only when one of them changes (each file
/// and its folder watched, `KubeconfigFileWatcher` — a `kubectx` rewrites
/// the file, so it is seen), or when a folder that wasn't there is there
/// at the next such command (`kind create cluster` writing the first
/// `~/.kube/config`); never per command. Kubernetes off, nothing is read.
@MainActor
final class KubeAmbientContexts: ObservableObject {
    static let shared = KubeAmbientContexts()

    /// The plain kubectl's files, merged as kubectl merges them; nil until read.
    @Published private(set) var list: KubeContextList?
    /// Files commands named with `--kubeconfig`, and pinned panes'
    /// `KUBECONFIG`s, by their absolute paths (`KubePaneWarning.kubeconfigKey`).
    @Published private(set) var named: [String: KubeContextList] = [:]
    private var started = false
    private var asked: Set<String> = []
    private var watcher: KubeconfigFileWatcher?
    private var reading: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// The warning for what a pane runs (or ran last): `cwd`, the folder it
    /// ran in; `kubeconfig`, the pane's own `KUBECONFIG` (a pinned one's).
    func warning(command: String?, cwd: String? = nil, kubeconfig: String? = nil, pin: KubeTerminalPin?, lost: Bool) -> KubePaneWarning? {
        guard Settings.shared.kubernetesEnabled else { return nil }
        let home = home
        let paneFiles = lost ? nil : kubeconfig.flatMap { KubePaneWarning.kubeconfigKey($0, cwd: nil, home: home) }.flatMap { named[$0] }
        return KubePaneWarning.resolve(
            command: command, pin: pin, lost: lost, ambient: list, paneFiles: paneFiles,
            kubeconfig: { [named] in KubePaneWarning.kubeconfigKey($0, cwd: cwd, home: home).flatMap { named[$0] } },
            settings: Settings.shared.kubernetesContexts)
    }

    /// A command began in a pane: the files read, the first time one is
    /// kubectl's, a new file named, or a folder that wasn't there is.
    func noticed(_ command: String, cwd: String? = nil, kubeconfig: String? = nil) {
        guard Settings.shared.kubernetesEnabled, let line = KubeCommandLine.parse(command) else { return }
        var again = !started
        started = true
        if let path = line.kubeconfig, let key = KubePaneWarning.kubeconfigKey(path, cwd: cwd, home: home), asked.insert(key).inserted { again = true }
        if let kubeconfig, kubeconfig != "/dev/null", let key = KubePaneWarning.kubeconfigKey(kubeconfig, cwd: nil, home: home),
            asked.insert(key).inserted
        {
            again = true
        }
        if let watcher, watcher.missing.contains(where: { FileManager.default.fileExists(atPath: $0) }) { again = true }
        if again { read() }
    }

    /// Everything read again, off the main thread.
    func read() {
        reading?.cancel()
        let keys = Array(asked)
        let settings = Settings.shared.kubernetesContexts
        let guarded = AppEnvironment.guardsKubeconfig
        let home = home
        reading = Task { [weak self] in
            let (files, list, named) = await KubeBlocking.run {
                let files = AppEnvironment.kubeconfigs(extra: [])
                let list = KubeContextList.load(files: files, settings: settings, guarded: guarded)
                var named: [String: KubeContextList] = [:]
                var read = files
                for key in keys {
                    let urls = Self.admitted(
                        KubeconfigSources.list(key, home: home), guarded: guarded, permitted: files, pinFolder: KubeTerminalFiles.defaultFolder)
                    guard !urls.isEmpty else { continue }
                    named[key] = KubeContextList.load(files: urls, settings: settings, guarded: guarded)
                    // Watched only when it is a file (or not there yet): a
                    // FIFO or a device named in a pane's title is never opened.
                    read += urls.filter { !KubeconfigFileWatcher.isSpecial($0.path) }
                }
                return (read, list, named)
            }
            guard let self, !Task.isCancelled else { return }
            if self.list != list { self.list = list }
            if self.named != named { self.named = named }
            // Watched again each time: a file replaced is a new one.
            self.watcher?.stop()
            self.watcher = KubeconfigFileWatcher(files: files) { [weak self] in self?.changed() }
        }
    }

    /// A change, read once when they stop coming.
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }

    /// What of `urls` may be read: all of them, unless guarded — then only
    /// `permitted` (`OVERTERM_KUBECONFIG`'s files) and a pin's own file in
    /// `pinFolder`, symlinks followed: a `--kubeconfig ~/work/prod.yaml` in
    /// an isolated run reads nothing of the user's.
    nonisolated static func admitted(_ urls: [URL], guarded: Bool, permitted: [URL], pinFolder: URL) -> [URL] {
        guard guarded else { return urls }
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let allowed = Set(permitted.map(real))
        let pins = real(pinFolder)
        return urls.filter { url in
            let path = real(url)
            return allowed.contains(path) || (path as NSString).deletingLastPathComponent == pins
        }
    }
}

/// A few files watched without recursion: each file (written in place, as
/// `kubectl config use-context` writes it) and the folder it is in (a file
/// created, replaced or removed — an editor's save, a `kubectx`), a
/// symlink's folder and its target's. One `DispatchSource` each and nothing
/// below them: a kubeconfig in the home folder or `$TMPDIR` must not watch
/// that whole tree (FSEvents would, thousands of paths a second). Told on
/// the main queue. A folder that isn't there can't be watched: `missing`
/// says which, for the next command to look at again.
@MainActor
final class KubeconfigFileWatcher {
    /// nonisolated(unsafe) so deinit can cancel them; only touched on the main queue.
    private nonisolated(unsafe) var sources: [DispatchSourceFileSystemObject] = []
    private(set) var missing: [String] = []

    init(files: [URL], onChange: @escaping @MainActor @Sendable () -> Void) {
        var folders: [String] = []
        var watched: [String] = []
        for file in files {
            let target = file.resolvingSymlinksInPath()
            for folder in [file.deletingLastPathComponent().path, target.deletingLastPathComponent().path] where !folders.contains(folder) {
                folders.append(folder)
            }
            for path in [file.path, target.path] where !watched.contains(path) { watched.append(path) }
        }
        let handler = Self.handler(onChange)
        for folder in folders {
            if let source = Self.source(folder, mask: [.write, .delete, .rename], handler) {
                sources.append(source)
            } else {
                missing.append(folder)
            }
        }
        for file in watched {
            if let source = Self.source(file, mask: [.write, .extend, .delete, .rename, .attrib], handler) { sources.append(source) }
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources = []
    }

    deinit {
        for source in sources { source.cancel() }
    }

    /// Built outside the actor: dispatch calls it on the main queue.
    private nonisolated static func handler(_ onChange: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
        { MainActor.assumeIsolated { onChange() } }
    }

    /// Whether `path` is there and neither a file nor a folder: a FIFO, a
    /// device, a socket. Opening one runs its open routine even for
    /// O_EVTONLY — a FIFO with no writer, a serial port waiting for
    /// carrier blocked the main thread, and a pane's title (any program's
    /// output) can name one.
    nonisolated static func isSpecial(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return !watchable(info.st_mode)
    }

    private nonisolated static func watchable(_ mode: mode_t) -> Bool {
        let type = mode & S_IFMT
        return type == S_IFREG || type == S_IFDIR
    }

    /// A source for a file or a folder, nil for anything else: checked
    /// before it is opened, opened without blocking (`O_NONBLOCK`, should
    /// it be swapped in between), and checked again once open.
    nonisolated static func source(
        _ path: String, mask: DispatchSource.FileSystemEvent, _ handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject? {
        var info = stat()
        guard stat(path, &info) == 0, watchable(info.st_mode) else { return nil }
        let fd = open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard fstat(fd, &info) == 0, watchable(info.st_mode) else {
            close(fd)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler(handler: Self.closing(fd))
        source.resume()
        return source
    }

    private nonisolated static func closing(_ fd: Int32) -> @Sendable () -> Void {
        { close(fd) }
    }
}
