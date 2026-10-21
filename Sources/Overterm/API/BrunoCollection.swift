import Foundation

/// A Bruno collection on disk: a folder with `bruno.json`, its requests
/// (`*.bru`) in folders of their own (`folder.bru` naming and ordering
/// one), `collection.bru` for what every request shares, and
/// `environments/*.bru`.
struct BrunoCollection: Equatable, Sendable {
    let root: URL
    let name: String
    /// Folder names `bruno.json` says to skip, beside the usual ones.
    let ignore: Set<String>
    /// The collection itself as a folder: its requests and folders.
    var tree: APIItem
    var environments: [APIEnvironmentRef]
    /// `scripts.flow` in bruno.json: "sandwich" (the default) runs the
    /// collection's script around the folder's around the request's.
    var scriptFlow: String

    static let configName = "bruno.json"

    /// My Requests: Overterm's own, not the checkout's (APIWorkspace).
    var isPersonal = false

    /// Reads the collection at `root`; nil when it has no bruno.json.
    static func load(_ root: URL) -> BrunoCollection? {
        let config = root.appendingPathComponent(configName)
        guard let data = try? Data(contentsOf: config) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ignore = Set((json["ignore"] as? [String]) ?? []).union(["node_modules", ".git"])
        let name = json["name"] as? String ?? root.lastPathComponent
        let flow = ((json["scripts"] as? [String: Any])?["flow"] as? String) ?? "sandwich"
        let tree = folder(root, root: root, ignore: ignore, name: name)
        let environments = environmentFiles(root)
        return BrunoCollection(root: root, name: name, ignore: ignore, tree: tree, environments: environments, scriptFlow: flow)
    }

    /// The collections under `checkout`: bruno.json at most `depth` folders
    /// down, never inside another collection, node_modules or a dot folder.
    /// Six down: a monorepo's docs app keeps one at frontend/apps/docs/api/bruno.
    static func find(in checkout: URL, depth: Int = 6) -> [URL] {
        var found: [URL] = []
        func walk(_ folder: URL, _ level: Int) {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(configName).path) {
                found.append(folder)
                return
            }
            guard level < depth,
                let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !skipped.contains(child.lastPathComponent)
            {
                walk(child, level + 1)
                if found.count >= 20 { return }
            }
        }
        walk(checkout.standardizedFileURL, 0)
        return found
    }

    /// Dependencies, builds and caches: never a collection, often huge.
    static let skipped: Set<String> = [
        "node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData", "coverage", "out", "tmp", "venv", "__pycache__",
    ]

    // MARK: The tree

    private static func folder(_ url: URL, root: URL, ignore: Set<String>, name: String? = nil) -> APIItem {
        let isRoot = url.standardizedFileURL == root.standardizedFileURL
        let folderFile = isRoot ? "collection.bru" : "folder.bru"
        let meta = (try? String(contentsOf: url.appendingPathComponent(folderFile), encoding: .utf8)).map(BruFile.init(parsing:))
        var folders: [APIItem] = []
        var requests: [APIItem] = []
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let childName = child.lastPathComponent
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !ignore.contains(childName), !(isRoot && childName == "environments") else { continue }
                folders.append(folder(child, root: root, ignore: ignore))
            } else if child.pathExtension == "bru", childName != "folder.bru", childName != "collection.bru" {
                guard let text = try? String(contentsOf: child, encoding: .utf8) else { continue }
                let file = BruFile(parsing: text)
                guard file.isRequest else { continue }
                requests.append(
                    APIItem(
                        url: child, name: file.name.isEmpty ? child.deletingPathExtension().lastPathComponent : file.name,
                        method: file.method, seq: file.seq, children: nil))
            }
        }
        // Bruno's sidebar: folders first, each list by seq, then name.
        let ordered = sorted(folders) + sorted(requests)
        let title = meta.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? name ?? url.lastPathComponent
        return APIItem(url: url, name: title, method: nil, seq: meta?.seq, children: ordered)
    }

    private static func sorted(_ items: [APIItem]) -> [APIItem] {
        items.sorted {
            switch ($0.seq, $1.seq) {
            case let (a?, b?) where a != b: a < b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func environmentFiles(_ root: URL) -> [APIEnvironmentRef] {
        let folder = root.appendingPathComponent("environments", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return
            files
            .filter { $0.pathExtension == "bru" }
            .map { APIEnvironmentRef(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Lookups

    /// Every request, in the order the runner takes them: depth first, as listed.
    var requests: [APIItem] { tree.allRequests }

    func item(at url: URL) -> APIItem? { tree.find(url.standardizedFileURL) }

    /// The folders from the collection down to the one holding `url`,
    /// outermost first, the collection's own folder not among them.
    func folders(containing url: URL) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        var folders: [URL] = []
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        // Bounded, and stopped at the root: never a walk up past "/".
        for _ in 0..<64 {
            guard folder.path.hasPrefix(rootPath + "/"), folder.pathComponents.count > 1 else { break }
            folders.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return folders
    }

    /// `collection.bru`, if it has one.
    var collectionFile: BruFile? {
        (try? String(contentsOf: root.appendingPathComponent("collection.bru"), encoding: .utf8)).map(BruFile.init(parsing:))
    }

    static func folderFile(_ folder: URL) -> BruFile? {
        (try? String(contentsOf: folder.appendingPathComponent("folder.bru"), encoding: .utf8)).map(BruFile.init(parsing:))
    }

    /// The `.env` beside bruno.json, which `{{process.env.NAME}}` reads first.
    var dotEnv: [String: String] {
        (try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)).map(DotEnv.parse) ?? [:]
    }
}

/// A folder or a request in a collection's tree.
struct APIItem: Identifiable, Equatable, Hashable, Sendable {
    let url: URL
    var name: String
    /// A request's method, upper case; nil for a folder.
    var method: String?
    var seq: Int?
    /// A folder's contents; nil for a request.
    var children: [APIItem]?

    var id: String { url.path }
    var isFolder: Bool { children != nil }

    var allRequests: [APIItem] {
        guard let children else { return [self] }
        return children.flatMap(\.allRequests)
    }

    func find(_ target: URL) -> APIItem? {
        if url.standardizedFileURL == target { return self }
        for child in children ?? [] {
            if let found = child.find(target) { return found }
        }
        return nil
    }

    /// Requests whose name or path holds `query`, folders kept around them.
    func filtered(_ query: String) -> APIItem? {
        guard !query.isEmpty else { return self }
        guard let children else {
            return name.localizedCaseInsensitiveContains(query) || url.lastPathComponent.localizedCaseInsensitiveContains(query) ? self : nil
        }
        let kept = children.compactMap { $0.filtered(query) }
        if kept.isEmpty && !name.localizedCaseInsensitiveContains(query) { return nil }
        var copy = self
        copy.children = kept.isEmpty ? children : kept
        return copy
    }
}

struct APIEnvironmentRef: Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let url: URL
    var id: String { url.path }
}

/// `.env`: `NAME=value` lines, `export` allowed, `#` comments, quotes taken off.
enum DotEnv {
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
                if quote == "\"" { value = value.replacingOccurrences(of: "\\n", with: "\n") }
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}
