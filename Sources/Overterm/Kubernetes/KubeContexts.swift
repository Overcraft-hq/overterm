import Foundation

/// Which kubeconfig files are read, in kubectl's order — and, in an
/// isolated run or a unit test, the guard that none of them is the user's.
///
/// This Mac's current context is production: a scenario or a test that
/// read `~/.kube/config` would reach it. `AppEnvironment.kubeconfigs` is
/// the one place the list is built, and it goes through `paths` below.
enum KubeconfigSources {
    /// The files, first wins:
    /// - `overterm` (`OVERTERM_KUBECONFIG`, a scenario's fake clusters): its
    ///   files and nothing else. Guarded, never one under `~/.kube`.
    /// - guarded without it: none — no contexts, so no proxy can start.
    /// - else `kubeconfig` (the shell's `KUBECONFIG`, colon-separated, empty
    ///   entries and repeats passed over), or `~/.kube/config` when it names
    ///   none; then the setting's `extra` files, a folder giving every file
    ///   in it.
    static func paths(
        overterm: String?, guarded: Bool, kubeconfig: String?, extra: [String], home: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        if let overterm, !overterm.trimmingCharacters(in: .whitespaces).isEmpty {
            let files = list(overterm, home: home)
            return guarded ? files.filter { !isUsersOwn($0, home: home) } : files
        }
        if guarded { return [] }
        var files = list(kubeconfig ?? "", home: home)
        if files.isEmpty { files = [home.appendingPathComponent(".kube/config")] }
        for item in extra {
            let url = expand(item.trimmingCharacters(in: .whitespaces), home: home)
            guard let url else { continue }
            var folder: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue {
                let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
                for name in names.sorted() where !name.hasPrefix(".") {
                    let file = url.appendingPathComponent(name)
                    var isFolder: ObjCBool = false
                    if fileManager.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue { files.append(file) }
                }
            } else {
                files.append(url)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// A colon-separated list, as KUBECONFIG has it.
    static func list(_ value: String, home: URL, relativeTo folder: URL? = nil) -> [URL] {
        var seen = Set<String>()
        return value.split(separator: ":").compactMap { expand(String($0).trimmingCharacters(in: .whitespaces), home: home, relativeTo: folder) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `~`, `$HOME` and `${HOME}` (and what follows them) against `home`; a
    /// relative path against `folder` — a command's own folder, for a
    /// `--kubeconfig ./prod.yaml` a pane ran — and without one passed over:
    /// an app has nothing to be relative to.
    static func expand(_ path: String, home: URL, relativeTo folder: URL? = nil) -> URL? {
        if path.isEmpty { return nil }
        for prefix in ["~", "$HOME", "${HOME}"] {
            if path == prefix { return home }
            if path.hasPrefix(prefix + "/") { return home.appendingPathComponent(String(path.dropFirst(prefix.count + 1))) }
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let folder else { return nil }
        return folder.appendingPathComponent(path).standardizedFileURL
    }

    /// Whether `url` is in the user's own `~/.kube` (its config, its other
    /// files), symlinks followed.
    static func isUsersOwn(_ url: URL, home: URL) -> Bool {
        let kube = home.appendingPathComponent(".kube", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == kube || path.hasPrefix(kube + "/")
    }
}

/// A context, its cluster and user resolved, as the pickers and the page show it.
struct KubeContext: Identifiable, Equatable, Sendable {
    let name: String
    let cluster: String
    /// The cluster's server; nil when the kubeconfig has no such cluster.
    let server: String?
    let namespace: String?
    let user: String
    /// Nil when the kubeconfig has no such user.
    let auth: KubeAuth?
    /// The file that named it first.
    let file: URL?
    let contextClass: KubeContextClass
    let settings: KubeContextSettings

    var id: String { name }
    var displayName: String { settings.displayName ?? name }
    var isProduction: Bool { contextClass == .production }
    /// Whether Overterm may change objects here: its `writable` flag, yes
    /// unless it says no, whatever the class. Nothing else decides it.
    var isWritable: Bool { KubeClassifier.isWritable(contextClass, flag: settings.writable) }
}

/// Every context of the kubeconfig files, merged in kubectl's order.
struct KubeContextList: Equatable, Sendable {
    var contexts: [KubeContext] = []
    /// kubectl's current context; Overterm never changes it.
    var current: String?
    /// The files that were read.
    var files: [URL] = []
    /// What couldn't be read, by file — never a value from one.
    var problems: [String] = []

    func context(named name: String) -> KubeContext? { contexts.first { $0.name == name } }

    /// The contexts of `configs` (already read, first file first), each
    /// with its class and settings.
    static func resolve(_ configs: [Kubeconfig], settings: [String: KubeContextSettings]) -> KubeContextList {
        let merged = Kubeconfig.merged(configs)
        let clusters = Dictionary(merged.clusters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let users = Dictionary(merged.users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var list = KubeContextList(current: merged.currentContext)
        for context in merged.contexts {
            let own = settings[context.name] ?? KubeContextSettings()
            list.contexts.append(
                KubeContext(
                    name: context.name, cluster: context.cluster, server: clusters[context.cluster]?.server,
                    namespace: context.namespace, user: context.user, auth: users[context.user]?.auth, file: context.file,
                    contextClass: KubeClassifier.classify(context: context.name, cluster: context.cluster, set: own.contextClass),
                    settings: own))
        }
        return list
    }

    /// Reads `files` (missing ones passed over, as kubectl does). Blocking:
    /// off the main thread. `guarded` refuses any file under `~/.kube` a
    /// second time, whoever built the list.
    static func load(
        files: [URL], settings: [String: KubeContextSettings], guarded: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> KubeContextList {
        var configs: [Kubeconfig] = []
        var read: [URL] = []
        var problems: [String] = []
        for file in files {
            if guarded, KubeconfigSources.isUsersOwn(file, home: home) {
                problems.append("\(file.path) is the user's own kubeconfig; an isolated run never reads it.")
                continue
            }
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
                let data = try? Data(contentsOf: file)
            else {
                problems.append("\(file.path) couldn't be read.")
                continue
            }
            guard let config = Kubeconfig.parse(String(decoding: data, as: UTF8.self), file: file) else {
                problems.append("\(file.path) isn't a kubeconfig Overterm can read.")
                continue
            }
            configs.append(config)
            read.append(file)
        }
        var list = resolve(configs, settings: settings)
        list.files = read
        list.problems = problems
        return list
    }

    /// The contexts this run may see: `AppEnvironment.kubeconfigs`' files,
    /// with the setting's extras. Blocking: off the main thread.
    static func fromEnvironment(extra: [String], settings: [String: KubeContextSettings]) -> KubeContextList {
        load(files: AppEnvironment.kubeconfigs(extra: extra), settings: settings, guarded: AppEnvironment.guardsKubeconfig)
    }

    /// Larger than any kubeconfig: a file past it isn't one.
    static let maxFileSize = 16 << 20
}
