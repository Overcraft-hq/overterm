import Foundation

/// What an importer makes of an OpenAPI document, a Postman collection, a
/// `.http` file or a cURL command: a Bruno collection's worth of files, not
/// yet written — so it can be tested whole, and written as a collection of
/// its own or as a folder in the one the checkout has.
struct APIImport: Equatable {
    struct Request: Equatable {
        var file: BruFile
    }

    struct Folder: Equatable {
        var name: String
        var folders: [Folder] = []
        var requests: [Request] = []
        /// folder.bru beyond its name: headers, auth, scripts.
        var settings: BruFile?

        var allRequests: [Request] { requests + folders.flatMap(\.allRequests) }
    }

    struct Environment: Equatable {
        var name: String
        var file: BruFile
    }

    var name: String
    var root: Folder
    /// collection.bru: what every request shares (auth, headers, vars, scripts).
    var collectionFile: BruFile?
    var environments: [Environment] = []
    /// What couldn't come across as it was, said once after the import.
    var notes: [String] = []

    enum WriteError: LocalizedError {
        case exists(String)
        var errorDescription: String? {
            switch self {
            case .exists(let path): "\(path) is already there."
            }
        }
    }

    /// Writes a collection of its own at `folder` (made; it must not hold a
    /// bruno.json yet). Returns the folder.
    @discardableResult
    func writeCollection(at folder: URL) throws -> URL {
        let config = folder.appendingPathComponent(BrunoCollection.configName)
        guard !FileManager.default.fileExists(atPath: config.path) else { throw WriteError.exists(config.path) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json: [String: Any] = ["version": "1", "name": name, "type": "collection", "ignore": ["node_modules", ".git"]]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: config)
        if let collectionFile, !collectionFile.blocks.isEmpty {
            try collectionFile.text.write(to: folder.appendingPathComponent("collection.bru"), atomically: true, encoding: .utf8)
        }
        try writeEnvironments(into: folder)
        try write(root, into: folder, isRoot: true)
        return folder
    }

    /// Writes the import as a folder of an existing collection, named after
    /// it; environments the collection lacks are added, none replaced.
    @discardableResult
    func writeFolder(in collection: URL) throws -> URL {
        let folder = Self.unique(collection.appendingPathComponent(APIWorkspace.fileName(name), isDirectory: true), isFolder: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = root.settings ?? BruFile()
        // What the collection shared — auth, headers, vars, scripts, tests,
        // docs — belongs to this folder now; folder.bru holds them all.
        if let collectionFile {
            for block in collectionFile.blocks
            where block.name.hasPrefix("auth") || block.name == "headers" || block.name.hasPrefix("vars") || block.name.hasPrefix("script:")
                || block.name == "tests" || block.name == "docs"
            {
                switch block.content {
                case .dictionary(let pairs): meta.setPairs(block.name, pairs)
                case .text(let text): meta.setText(block.name, text)
                case .list(let items): meta.setList(block.name, items)
                }
            }
        }
        meta.name = name
        try meta.text.write(to: folder.appendingPathComponent("folder.bru"), atomically: true, encoding: .utf8)
        try writeEnvironments(into: collection)
        try write(root, into: folder, isRoot: true, skipFolderFile: true)
        return folder
    }

    private func writeEnvironments(into collection: URL) throws {
        guard !environments.isEmpty else { return }
        let folder = collection.appendingPathComponent("environments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for environment in environments {
            let file = folder.appendingPathComponent(APIWorkspace.fileName(environment.name) + ".bru")
            guard let existing = (try? String(contentsOf: file, encoding: .utf8)).map(BruFile.init(parsing:)) else {
                try environment.file.text.write(to: file, atomically: true, encoding: .utf8)
                continue
            }
            // An environment of that name is there: what it lacks is added —
            // the imported requests use it — and nothing it sets is changed.
            var merged = existing
            let have = Set(existing.variables.map(\.key) + existing.secretNames)
            let added = environment.file.variables.filter { !have.contains($0.key) }
            if !added.isEmpty { merged.variables = existing.variables + added }
            let secrets = environment.file.secretNames.filter { !have.contains($0) }
            if !secrets.isEmpty { merged.secretNames = existing.secretNames + secrets }
            if merged != existing { try merged.text.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    private func write(_ folder: Folder, into url: URL, isRoot: Bool, skipFolderFile: Bool = false) throws {
        if !isRoot, !skipFolderFile {
            var meta = folder.settings ?? BruFile()
            meta.name = folder.name
            try meta.text.write(to: url.appendingPathComponent("folder.bru"), atomically: true, encoding: .utf8)
        }
        for (index, request) in folder.requests.enumerated() {
            var file = request.file
            file.seq = index + 1
            let name = file.name.isEmpty ? "Request \(index + 1)" : file.name
            let target = Self.unique(url.appendingPathComponent(APIWorkspace.fileName(name) + ".bru"), isFolder: false)
            try file.text.write(to: target, atomically: true, encoding: .utf8)
        }
        for (index, child) in folder.folders.enumerated() {
            let target = Self.unique(url.appendingPathComponent(APIWorkspace.fileName(child.name), isDirectory: true), isFolder: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var withSeq = child
            var meta = withSeq.settings ?? BruFile()
            meta.seq = index + 1
            withSeq.settings = meta
            try write(withSeq, into: target, isRoot: false)
        }
    }

    /// `name.bru`, or `name 2.bru` when that is taken.
    static func unique(_ url: URL, isFolder: Bool) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let parent = url.deletingLastPathComponent()
        let ext = isFolder ? "" : url.pathExtension
        let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for n in 2..<1000 {
            let name = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = parent.appendingPathComponent(name, isDirectory: isFolder)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: Reading a file into an import

    enum Problem: LocalizedError, Equatable {
        case unreadable(String)
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) can't be read as JSON or YAML."
            case .unknown(let name): "\(name) isn't an OpenAPI document, a Postman collection or a .http file."
            }
        }
    }

    /// What an existing environment of the same name sets differently from
    /// the import — kept as it is, said in the import's notes.
    func environmentConflicts(in collection: URL) -> [String] {
        environments.flatMap { environment -> [String] in
            let file = collection.appendingPathComponent("environments/\(APIWorkspace.fileName(environment.name)).bru")
            guard let existing = (try? String(contentsOf: file, encoding: .utf8)).map(BruFile.init(parsing:)) else { return [] }
            let theirs = APIVariables.map(existing.variables)
            return environment.file.variables.compactMap { pair in
                guard let value = theirs[pair.key], value != pair.value else { return nil }
                return "\(environment.name) already sets \(pair.key) to \(value); the imported API's is \(pair.value). It was left as it is."
            }
        }
    }

    /// Whatever `url` holds — OpenAPI (JSON or YAML), Postman, .http.
    static func read(_ url: URL) throws -> APIImport {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let ext = url.pathExtension.lowercased()
        if ext == "http" || ext == "rest" {
            return HTTPFileImporter.make(text, name: url.deletingPathExtension().lastPathComponent)
        }
        guard let document = parseDocument(data) else { throw Problem.unreadable(url.lastPathComponent) }
        if PostmanImporter.isPostman(document) { return try PostmanImporter.make(document) }
        if OpenAPIImporter.isOpenAPI(document) { return try OpenAPIImporter.make(document) }
        throw Problem.unknown(url.lastPathComponent)
    }

    /// JSON, else YAML.
    static func parseDocument(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        return YAMLReader.parse(String(decoding: data, as: UTF8.self)) as? [String: Any]
    }

    /// Pretty JSON as people write it: two spaces, `"key": value`, keys sorted.
    static func prettyJSON(_ value: Any) -> String {
        // Checked as JSONSerialization checks it — a NaN or infinity from YAML
        // (.nan, .inf) would make it raise, which try? doesn't catch.
        guard JSONSerialization.isValidJSONObject([value]),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\" : ", with: "\": ")
    }
}
