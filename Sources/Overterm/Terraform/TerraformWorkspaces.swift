import Foundation

/// The workspace chip's list and Select (analysis 4.9, 6.2): `workspace
/// list` (a remote backend's cached by identity in the registry) and
/// `workspace select <name>`, both with `TF_WORKSPACE` removed — `select`
/// refuses an unknown name and never creates one (no `-or-create`). Select
/// writes the checkout's `.terraform/environment`, which every terminal in
/// that root then follows: the menu says so.
enum TerraformWorkspaces {
    enum Answer: Sendable, Equatable {
        case names([String])
        case failed(String)
    }

    /// A local backend's: `default` and `terraform.tfstate.d`'s folders;
    /// any other's: `workspace list`. Blocking: a GCD thread's.
    static func list(root: URL, checkout: URL, settingPath: String, hasVersionFile: Bool) -> Answer {
        let facts = TerraformRootFacts.read(root: root, checkout: checkout)
        if facts.backend.type == "local" { return .names((["default"] + facts.localWorkspaces).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }) }
        guard let binary = TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile) else {
            return .failed("No terraform found.")
        }
        guard let base = try? AppEnvironment.terraformBaseEnvironment(), let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
        else { return .failed("The environment for terraform couldn't be read.") }
        let environment = TerraformEnvironment.build(base: base, purpose: .run(workspace: nil, pluginCache: nil), root: root, scratch: scratch)
        guard let result = try? TerraformRun.runBlocking(binary, TerraformCommands.workspaceList, in: root, environment: environment, input: nil, timeout: 60)
        else { return .failed("terraform workspace list couldn't start.") }
        guard result.status == 0 else { return .failed(TerraformEditorModel.firstError(result.stderr) ?? "terraform workspace list failed (exit \(result.status)).") }
        return .names(TerraformWorkspaceCheck.parseList(String(decoding: result.stdout, as: UTF8.self)))
    }

    /// `workspace select <name>`: nil when done, else why not. Blocking.
    static func select(_ name: String, root: URL, settingPath: String, hasVersionFile: Bool) -> String? {
        guard let arguments = TerraformCommands.workspaceSelect(name) else { return "“\(name)” isn't a workspace's name." }
        guard let binary = TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile) else { return "No terraform found." }
        guard let base = try? AppEnvironment.terraformBaseEnvironment(), let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
        else { return "The environment for terraform couldn't be read." }
        let environment = TerraformEnvironment.build(base: base, purpose: .run(workspace: nil, pluginCache: nil), root: root, scratch: scratch)
        guard let result = try? TerraformRun.runBlocking(binary, arguments, in: root, environment: environment, input: nil, timeout: 60) else {
            return "terraform workspace select couldn't start."
        }
        return result.status == 0 ? nil : TerraformEditorModel.firstError(result.stderr) ?? "terraform workspace select failed (exit \(result.status))."
    }
}

extension TerraformRunRisks {
    /// The base branch's side of a root (5.4, 5.5): its `.tf` files and
    /// lock file at `base` (the diff's merge base, else `HEAD`), read with
    /// `git show`, bounded. Nil when the root isn't there.
    static func readBase(checkout: URL, rootPath: String, base: String) async -> Base? {
        let prefix = rootPath.isEmpty ? "" : rootPath + "/"
        guard let listed = try? await Git.run(["ls-tree", "-z", "--name-only", base, "--", prefix.isEmpty ? "." : prefix], in: checkout) else { return nil }
        let names = listed.split(separator: "\0").map(String.init).filter { ($0 as NSString).deletingLastPathComponent == rootPath }
        var texts: [String] = []
        var lock: [TerraformLockFile.Provider]?
        for path in names.prefix(TerraformRootGuess.maxFilesPerFolder) {
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".tf") || name == ".terraform.lock.hcl" else { continue }
            guard let text = try? await Git.run(["show", "\(base):\(path)"], in: checkout), text.utf8.count <= TerraformRootGuess.maxBytesPerFile else { continue }
            if name == ".terraform.lock.hcl" { lock = TerraformLockFile.providers(in: text) } else { texts.append(text) }
        }
        guard !texts.isEmpty || lock != nil else { return nil }
        return Base(config: TerraformConfigFacts.read(texts), lockProviders: lock)
    }
}
