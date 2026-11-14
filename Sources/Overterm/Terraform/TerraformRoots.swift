import Foundation

/// What a folder of Terraform files is (analysis 4.12).
enum TerraformFolderKind: String, Equatable, Sendable {
    /// A root module: where terraform runs, with a state.
    case root
    /// A child module: another folder's `module` calls it, or it is under `modules/`.
    case module
    /// Under `examples/` or `test(s)/`: listed, folded.
    case example
    /// A Terragrunt unit (`terragrunt.hcl` with `terraform { source }`):
    /// labelled, run with terragrunt in a terminal (units as roots: stage 3).
    case terragruntUnit
    /// Terragrunt's own configuration (`root.hcl`, a top-level `terragrunt.hcl`).
    case terragruntConfig
}

/// One folder of a checkout's Terraform, as the guess found it.
struct TerraformRootFolder: Equatable, Sendable, Identifiable {
    /// Relative to the repository's top; "" is the top.
    var path: String
    var kind: TerraformFolderKind
    /// Its file names, as `git ls-files` listed them.
    var files: [String]
    var id: String { path }

    var hasLockFile: Bool { files.contains(".terraform.lock.hcl") }
    var hasTests: Bool { files.contains { $0.hasSuffix(".tftest.hcl") } }
    /// The `.tfvars` beside it.
    var varFiles: [String] { files.filter { $0.hasSuffix(".tfvars") || $0.hasSuffix(".tfvars.json") }.sorted() }
    /// The var files every run loads without being asked: `terraform.tfvars` and `*.auto.tfvars`.
    var autoVarFiles: [String] {
        varFiles.filter { $0 == "terraform.tfvars" || $0 == "terraform.tfvars.json" || $0.hasSuffix(".auto.tfvars") || $0.hasSuffix(".auto.tfvars.json") }
    }
}

/// Which folders are roots, modules, examples or Terragrunt's (4.12 step
/// 2). Pure: the file list from `TerraformRootScan`, each folder's config
/// facts from its files (`facts`).
enum TerraformRootGuess {
    /// Bounds on what one folder's guess reads.
    static let maxFilesPerFolder = 120
    static let maxBytesPerFile = 256 << 10

    /// The patterns `git ls-files` is given (2.1).
    static let patterns = [
        "*.tf", "*.tf.json", "*.tofu", "*.tfvars", "*.tfvars.json", "*terragrunt.hcl", "*root.hcl", "*.terraform.lock.hcl", "*.tftest.hcl",
    ]

    /// Folders never Terraform's own: what `init` and Terragrunt copy, and vendored trees.
    static func isSkipped(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains { $0 == ".terraform" || $0 == ".terragrunt-cache" || $0 == "node_modules" || $0 == ".git" }
    }

    /// `paths`, relative to the top, grouped by folder.
    static func folders(of paths: [String]) -> [String: [String]] {
        var folders: [String: [String]] = [:]
        for path in paths where !isSkipped(path) {
            let folder = (path as NSString).deletingLastPathComponent
            folders[folder, default: []].append((path as NSString).lastPathComponent)
        }
        return folders
    }

    static func isConfigFile(_ name: String) -> Bool {
        name.hasSuffix(".tf") || name.hasSuffix(".tf.json") || name.hasSuffix(".tofu")
    }

    /// A module source that is a folder of this repository, resolved
    /// against `folder`: `../../modules/net` → `modules/net`. Nil for a
    /// registry, git or http source, or one that climbs out.
    static func localSource(_ source: String, from folder: String) -> String? {
        guard source.hasPrefix("./") || source.hasPrefix("../") else { return nil }
        var parts = folder.split(separator: "/").map(String.init)
        for part in source.split(separator: "/") {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else if part != "." && !part.isEmpty {
                parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    /// Every folder's kind. `facts[folder]` is its config, `terragrunt[folder]`
    /// its `terragrunt.hcl`'s text when it has one.
    static func classify(
        folders: [String: [String]], facts: [String: TerraformConfigFacts], terragrunt: [String: String] = [:], modulesJSON: [String: [String]] = [:]
    ) -> [TerraformRootFolder] {
        // Who calls whom: local sources, and what init installed.
        var called: Set<String> = []
        for (folder, config) in facts {
            for source in config.moduleSources { if let target = localSource(source, from: folder) { called.insert(target) } }
            for dir in modulesJSON[folder] ?? [] { if let target = localSource(dir.hasPrefix(".") ? dir : "./" + dir, from: folder) { called.insert(target) } }
        }
        var result: [TerraformRootFolder] = []
        for (folder, files) in folders {
            let parts = folder.split(separator: "/").map(String.init)
            if files.contains("root.hcl") || (files.contains("terragrunt.hcl") && folder.isEmpty) {
                result.append(TerraformRootFolder(path: folder, kind: .terragruntConfig, files: files.sorted()))
                continue
            }
            if files.contains("terragrunt.hcl") {
                let text = terragrunt[folder] ?? ""
                let isUnit = text.contains("terraform") && text.contains("source")
                result.append(TerraformRootFolder(path: folder, kind: isUnit ? .terragruntUnit : .terragruntConfig, files: files.sorted()))
                continue
            }
            guard files.contains(where: isConfigFile) else { continue }
            let config = facts[folder] ?? TerraformConfigFacts()
            let kind: TerraformFolderKind
            if config.backend != nil {
                kind = .root
            } else if called.contains(folder) || parts.contains("modules") {
                kind = .module
            } else if parts.contains(where: { ["examples", "example", "test", "tests"].contains($0) }) {
                kind = .example
            } else {
                // A lock file, var files, a provider configured — or nothing
                // calling it: where terraform is run.
                kind = .root
            }
            result.append(TerraformRootFolder(path: folder, kind: kind, files: files.sorted()))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// The roots that call each module, through other modules too
    /// ("modules/network: 5 roots"). `calls[folder]` are the folders it
    /// calls (local sources, resolved). Bounded by the folders there are.
    static func callers(of modules: [String], roots: [String], calls: [String: Set<String>]) -> [String: [String]] {
        var reached: [String: Set<String>] = [:]
        for root in roots {
            var seen: Set<String> = []
            var stack = Array(calls[root] ?? [])
            while let next = stack.popLast(), seen.count < 10_000 {
                guard seen.insert(next).inserted else { continue }
                stack += calls[next] ?? []
            }
            for module in seen { reached[module, default: []].insert(root) }
        }
        var result: [String: [String]] = [:]
        for module in modules { result[module] = (reached[module] ?? []).sorted() }
        return result
    }

    /// Whether a file's name is one of `patterns`' (what `ls-files` and the
    /// walk list).
    static func isTerraformName(_ name: String) -> Bool {
        isConfigFile(name) || name.hasSuffix(".tfvars") || name.hasSuffix(".tfvars.json") || name.hasSuffix("terragrunt.hcl")
            || name.hasSuffix("root.hcl") || name.hasSuffix(".terraform.lock.hcl") || name.hasSuffix(".tftest.hcl")
    }

    /// The nearest root at or above `folder` (4.12 step 5): a template or a
    /// policy the root reads with `file("${path.module}/…")` is the
    /// root's. Bounded; "" is the top, and the walk stops there.
    static func nearestRoot(of folder: String, roots: Set<String>) -> String? {
        var current = folder
        for _ in 0..<64 {
            if roots.contains(current) { return current }
            guard !current.isEmpty else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The roots a set of changed files touches: a file in the root's
    /// folder or below it (the nearest root above the file), or in a
    /// module it calls, at any depth. `changed` are paths relative to the top.
    static func touched(roots: [String], changed: [String], moduleCallers: [String: [String]]) -> Set<String> {
        var touched: Set<String> = []
        let rootSet = Set(roots)
        for file in changed {
            let folder = (file as NSString).deletingLastPathComponent
            if let root = nearestRoot(of: folder, roots: rootSet) { touched.insert(root) }
            for (module, callers) in moduleCallers where folder == module || folder.hasPrefix(module + "/") {
                touched.formUnion(callers)
            }
        }
        return touched
    }
}

/// A root's facts, read only while shown (4.12 step 3): its config, the
/// workspace `.terraform/environment` selects, the backend `init` recorded
/// (allow-listed), the modules it installed, its lock file's providers, a
/// local backend's workspaces and whether this workspace's state file is
/// here, and the version pins. Blocking file reads, bounded: a GCD thread's.
struct TerraformRootFacts: Equatable, Sendable {
    var config = TerraformConfigFacts()
    /// What `.terraform/environment` says, else `default`.
    var workspace = "default"
    /// `.terraform/environment` names it (not the default by absence).
    var workspaceFromFile = false
    var initRecord: TerraformConfigFacts.Backend?
    var modulesJSON: [String] = []
    /// Nil: no lock file.
    var lockProviders: [TerraformLockFile.Provider]?
    /// A local backend's other workspaces: `terraform.tfstate.d`'s folders.
    var localWorkspaces: [String] = []
    /// A local backend's state file for `workspace` is here.
    var localStateExists = false
    var pins = TerraformVersionPins()
    /// `required_providers` with no lock entry: "needs init" (4.12 step 4).
    var needsInit = false

    var backend: TerraformConfigFacts.Backend { TerraformStateIdentity.effective(config: config.backend, record: initRecord) }

    /// The root's config files' texts, bounded.
    static func configTexts(in root: URL, names: [String]? = nil) -> [String] {
        let manager = FileManager.default
        let listed = names ?? ((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
        var texts: [String] = []
        for name in listed.sorted().prefix(TerraformRootGuess.maxFilesPerFolder) where name.hasSuffix(".tf") || name.hasSuffix(".tofu") {
            let url = root.appendingPathComponent(name)
            guard let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int), size <= TerraformRootGuess.maxBytesPerFile,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            texts.append(text)
        }
        return texts
    }

    /// A small file's text, or nil (never one past 256 KB, never a non-file).
    static func smallFile(_ url: URL, limit: Int = TerraformRootGuess.maxBytesPerFile) -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Reads `root`'s facts. `checkout` bounds the walk up for version
    /// files: never above it, and never past `/` (CLAUDE.md).
    static func read(root: URL, checkout: URL, config: TerraformConfigFacts? = nil) -> TerraformRootFacts {
        var facts = TerraformRootFacts()
        facts.config = config ?? TerraformConfigFacts.read(configTexts(in: root))
        let data = root.appendingPathComponent(".terraform", isDirectory: true)
        if let text = smallFile(data.appendingPathComponent("environment")).map({ String(decoding: $0, as: UTF8.self) }) {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.count <= 90, !name.contains("/") {
                facts.workspace = name
                facts.workspaceFromFile = true
            }
        }
        if let record = smallFile(data.appendingPathComponent("terraform.tfstate"), limit: 1 << 20) {
            facts.initRecord = TerraformInitRecord.backend(from: record)
        }
        if let modules = smallFile(data.appendingPathComponent("modules/modules.json"), limit: 4 << 20) {
            facts.modulesJSON = TerraformModulesManifest.directories(from: modules)
        }
        if let lock = smallFile(root.appendingPathComponent(".terraform.lock.hcl"), limit: 1 << 20) {
            facts.lockProviders = TerraformLockFile.providers(in: String(decoding: lock, as: UTF8.self))
        }
        let backend = facts.backend
        if backend.type == "local" {
            let folder = backend.settings["workspace_dir"] ?? "terraform.tfstate.d"
            let base = folder.hasPrefix("/") ? URL(fileURLWithPath: folder) : root.appendingPathComponent(folder)
            facts.localWorkspaces = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            let state = TerraformStateIdentity.localStatePath(backend: backend, workspace: facts.workspace, root: root)
            facts.localStateExists = FileManager.default.fileExists(atPath: state.path)
        }
        if !facts.config.requiredProviders.isEmpty {
            let locked = Set((facts.lockProviders ?? []).map(\.type))
            facts.needsInit = facts.config.requiredProviders.keys.contains { !locked.contains($0) && $0 != "terraform" }
        }
        facts.pins = pins(from: root, checkout: checkout, required: facts.config.requiredVersion)
        return facts
    }

    /// The nearest version file, from the root up to the checkout.
    static func pins(from root: URL, checkout: URL, required: String?) -> TerraformVersionPins {
        let unpinned = TerraformVersionPins(required: required)
        let top = checkout.standardizedFileURL.path
        var folder = root.standardizedFileURL
        for _ in 0..<32 {
            if let text = smallFile(folder.appendingPathComponent(".terraform-version"), limit: 4096).map({ String(decoding: $0, as: UTF8.self) }),
                let pin = TerraformVersionPins.terraformVersionFile(text)
            {
                return TerraformVersionPins(required: required, pin: pin, pinFile: ".terraform-version")
            }
            if let text = smallFile(folder.appendingPathComponent(".tool-versions"), limit: 65536).map({ String(decoding: $0, as: UTF8.self) }),
                let pin = TerraformVersionPins.toolVersions(text)
            {
                return TerraformVersionPins(required: required, pin: pin, pinFile: ".tool-versions")
            }
            if let text = smallFile(folder.appendingPathComponent("mise.toml"), limit: 65536).map({ String(decoding: $0, as: UTF8.self) }),
                let pin = TerraformVersionPins.miseToml(text)
            {
                return TerraformVersionPins(required: required, pin: pin, pinFile: "mise.toml")
            }
            guard folder.path != top, folder.pathComponents.count > 1, folder.path.hasPrefix(top) else { break }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return unpinned
    }

    /// What another worktree's same root says of its state, and nothing
    /// more (3.6, 3.7): the workspace, the init record, and — before init —
    /// the backend block. Kept by the files' size and modification times,
    /// so a read of the panel stats them rather than reading 120 `.tf`
    /// files a worktree. Blocking.
    static func readIdentity(root: URL) -> TerraformRootFacts {
        let manager = FileManager.default
        let data = root.appendingPathComponent(".terraform", isDirectory: true)
        let names = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".tf") || $0.hasSuffix(".tofu") }.sorted()
            .prefix(TerraformRootGuess.maxFilesPerFolder)
        var signature: [String] = []
        for name in [".terraform/environment", ".terraform/terraform.tfstate"] + names {
            var info = stat()
            if stat(root.appendingPathComponent(name).path, &info) == 0 {
                signature.append("\(name):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
            }
        }
        let key = root.standardizedFileURL.path
        if let cached = identityLock.withLock({ identityCache[key] }), cached.signature == signature { return cached.facts }
        var facts = TerraformRootFacts()
        if let text = smallFile(data.appendingPathComponent("environment")).map({ String(decoding: $0, as: UTF8.self) }) {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.count <= 90, !name.contains("/") {
                facts.workspace = name
                facts.workspaceFromFile = true
            }
        }
        if let record = smallFile(data.appendingPathComponent("terraform.tfstate"), limit: 1 << 20) {
            facts.initRecord = TerraformInitRecord.backend(from: record)
        }
        // The record is what terraform reads; the HCL only before init.
        if facts.initRecord == nil {
            facts.config.backend = TerraformConfigFacts.read(configTexts(in: root, names: Array(names))).backend
        }
        identityLock.withLock {
            if identityCache.count > 2_000 { identityCache = [:] }
            identityCache[key] = (signature, facts)
        }
        return facts
    }

    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var identityCache: [String: (signature: [String], facts: TerraformRootFacts)] = [:]

    /// Whether a version manager could pick the version here: a version
    /// file from the root up to the checkout. Then the binary is resolved
    /// and asked its version per root (4.2).
    var hasVersionFile: Bool { pins.pinFile != nil }
}

/// The checkout's Terraform files, by one git call (4.12 step 1):
/// `ls-files` of the cached and the untracked-but-not-ignored, so
/// `.terraform/`, `.terragrunt-cache/` and `node_modules` stay out.
/// Capped at 20,000 matches and 2,000 folders, said when capped. When git
/// can't list it, a repository's top folder (`KubeCheckoutScan.isRepositoryRoot`:
/// a `.git` there, never `~` or `/`) is walked instead, as Kubernetes'
/// guess walks — bounded; any other folder is not walked.
enum TerraformRootScan {
    static let maxMatches = 20_000
    static let maxFolders = 2_000

    struct Listing: Equatable, Sendable {
        var folders: [String: [String]]
        var capped: Bool
    }

    static func arguments() -> [String] {
        ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + TerraformRootGuess.patterns
    }

    /// Pure: `ls-files -z`'s output into folders, within the caps.
    static func listing(_ output: String) -> Listing {
        var paths: [String] = []
        var capped = false
        var seen: Set<String> = []
        for path in output.split(separator: "\0") {
            if paths.count >= maxMatches {
                capped = true
                break
            }
            let path = String(path)
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        var folders = TerraformRootGuess.folders(of: paths)
        if folders.count > maxFolders {
            capped = true
            let kept = folders.keys.sorted().prefix(maxFolders)
            folders = folders.filter { kept.contains($0.key) }
        }
        return Listing(folders: folders, capped: capped)
    }

    static func list(_ checkout: URL) async -> Listing? {
        if let output = try? await Git.run(arguments(), in: checkout, outputLimit: 8 << 20) { return listing(output) }
        return await TerraformPanelModel.blocking { KubeCheckoutScan.isRepositoryRoot(checkout) ? walk(checkout) : nil }
    }

    /// Bounds on the walk: Kubernetes' depth, more entries (roots nest deeper than manifests).
    static let walkDepth = 8
    static let walkEntries = 20_000

    /// The bounded walk of a repository's top folder git couldn't list:
    /// breadth first, hidden folders, symbolic links, `.terraform`,
    /// `.terragrunt-cache` and `KubeCheckoutScan.skipped` passed over; only
    /// names (no file read). Blocking.
    static func walk(_ root: URL) -> Listing {
        let manager = FileManager.default
        let base = root.standardizedFileURL
        var paths: [String] = []
        var entries = 0
        var capped = false
        var folders: [(URL, String, Int)] = [(base, "", 0)]
        var next = 0
        while next < folders.count {
            let (folder, relative, depth) = folders[next]
            next += 1
            guard
                let names = try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            else { continue }
            for url in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                entries += 1
                guard entries <= walkEntries, paths.count < maxMatches else {
                    capped = true
                    break
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                let name = url.lastPathComponent
                let path = relative.isEmpty ? name : relative + "/" + name
                if values?.isDirectory == true {
                    guard !name.hasPrefix("."), !KubeCheckoutScan.skipped.contains(name), !TerraformRootGuess.isSkipped(path) else { continue }
                    if depth + 1 <= walkDepth { folders.append((url, path, depth + 1)) }
                    continue
                }
                if TerraformRootGuess.isTerraformName(name) { paths.append(path) }
            }
            if capped { break }
        }
        var result = listing(paths.joined(separator: "\0"))
        result.capped = result.capped || capped
        return result
    }
}
