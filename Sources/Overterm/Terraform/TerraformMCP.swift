import Darwin
import Foundation

/// Terraform's MCP tools (analysis 5.10, stage 1c), beside the browser's,
/// the databases', Docker's and Kubernetes' on the same server
/// (BrowserBridge), turned on by `terraform.agentAccess`: an agent lists
/// its checkout's roots, checks their format, validates them, and reads a
/// plan it saved itself as a masked summary.
///
/// **Reads, and none that writes.** No tool runs `init`, `plan`, `apply`,
/// or anything of `state`: `tf_apply`, `tf_destroy`, `tf_state_*` and the
/// rest don't exist (an agent writes `removed`, `moved` and `import` blocks,
/// which a person plans and applies). The terraform a tool starts is only a
/// line `TerraformCommands` builds — `fmt -check -diff`, `validate -json`,
/// `show -json /dev/fd/3` — in the stripped environment
/// (`TerraformEnvironment.Purpose.agentRead`: no credential, a scratch
/// HOME), because a tool runs outside the agent's sandbox and its
/// providers start with whatever environment Overterm gives them.
///
/// **Where.** The calling pane's checkout (`paneCheckout`, its tab's), and
/// nothing outside it: every path argument is resolved with `realpath` and
/// must stay inside — no `..`, no absolute path, no link out
/// (`TerraformMCPPath`). With no pane, no tool works.
///
/// **Masked.** `tf_plan_summary` decodes the plan through `TerraformPlan`'s
/// allow-list, masked at decode, and says only the summary text — never a
/// value Terraform marks sensitive, a variable's value, or anything
/// `Secrets` matches; strings cut at 200 characters. Every answer goes
/// through `Secrets` once more.
@MainActor
enum TerraformMCP {
    static let prefix = "tf_"
    static let names = ["tf_roots", "tf_fmt_check", "tf_validate", "tf_plan_summary"]

    /// The checkout a pane's tab works in — the window answers (nil
    /// outside any window's tabs, and in tests that set none).
    static var paneCheckout: ((String) -> URL?)?

    /// A plan's JSON is read up to this (`terraform.maxPlanBytes`, 4.1), the plan file too.
    static let maxPlanBytes = 64 << 20
    static let maxAnswer = 48 << 10

    static let instructions =
        "Terraform in your checkout (Overterm's Terraform panel): tf_roots lists its roots with their workspace, backend and class (production is plan-only), tf_fmt_check and tf_validate check a root without credentials, tf_plan_summary reads a plan you saved (terraform plan -out=FILE) as a masked summary — counts, what is destroyed or replaced and why, the attributes that change. Never run terraform apply, destroy, import or state commands yourself: the person does, after reading the plan."

    static let tools: [[String: Any]] = [
        tool("tf_roots", "The Terraform roots of your checkout: path, class (production, remote, local), workspace, backend, modules and who calls them.", [:]),
        tool(
            "tf_fmt_check", "Whether a root's .tf files pass terraform fmt, with the diff that would fix them. Writes nothing.",
            ["root": ["type": "string", "description": "The root's folder, relative to the checkout (envs/dev). Optional when there is one root."]]),
        tool(
            "tf_validate",
            "terraform validate of a root, with no credential: its errors and warnings with file and line. Only where the root is initialised and its lock file unchanged from HEAD; it never runs init.",
            ["root": ["type": "string", "description": "The root's folder, relative to the checkout. Optional when there is one root."]]),
        tool(
            "tf_plan_summary",
            "A plan you saved (terraform plan -out=FILE inside the checkout), read as a masked summary: counts, every destroy, replace and forget with its reason and the attribute forcing it, updates with the attribute paths that change, moves, imports, drift, outputs. Never a sensitive value.",
            [
                "path": ["type": "string", "description": "The plan file, relative to the checkout (envs/dev/acme.tfplan)."],
                "root": ["type": "string", "description": "The root it was planned in, when it isn't the folder above the file."],
            ], required: ["path"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    // MARK: Calls

    static func call(_ name: String, _ arguments: [String: Any], pane: String?) async throws -> [String: Any] {
        guard names.contains(name) else {
            throw BrowserMCP.ToolError(message: "Unknown tool: \(name). Agents read Terraform here; nothing here applies, destroys or changes state.")
        }
        guard Settings.shared.terraformEnabled else { return BrowserMCP.errorResult("Terraform is off in Overterm's settings (Settings ▸ Terraform).") }
        guard let pane, let checkout = paneCheckout?(pane) else {
            return BrowserMCP.errorResult("The tf_ tools work on the checkout of the pane you run in, and this call came from none Overterm knows.")
        }
        let text: String
        switch name {
        case "tf_roots": text = await roots(in: checkout)
        case "tf_fmt_check": text = try await formatCheck(arguments, in: checkout)
        case "tf_validate": text = try await validate(arguments, in: checkout)
        case "tf_plan_summary": text = try await planSummary(arguments, in: checkout)
        default: throw BrowserMCP.ToolError(message: "Unknown tool: \(name)")
        }
        return BrowserMCP.textResult(TerraformPlanText.cut(Self.scrubbed(text), to: maxAnswer))
    }

    /// Every answer, once more: credentials in text, URLs' passwords.
    static func scrubbed(_ text: String) -> String { TerraformValidation.scrub(text) }

    private static func argument(_ arguments: [String: Any], _ key: String) -> String? {
        (arguments[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: tf_roots

    struct Read: Sendable {
        var roots: [TerraformRootCard]
        var modules: [TerraformModuleRow]
    }

    /// The checkout's roots, as the panel reads them.
    static func read(_ checkout: URL) async -> Read? {
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        guard let listing = await TerraformRootScan.list(checkout) else { return nil }
        let assembled = await TerraformPanelModel.blocking {
            TerraformPanelModel.assemble(
                checkout: checkout, listing: listing, worktrees: [], settings: settings, identities: identities, awsProfile: nil, changed: [])
        }
        TerraformAgentGuards.shared.record(checkout, roots: assembled.roots, complete: !listing.capped, settings: settings, identities: identities)
        TerraformRootStore.shared.rememberProduction(assembled.roots.flatMap(\.rememberedIdentities))
        return Read(roots: assembled.roots, modules: assembled.modules)
    }

    static func roots(in checkout: URL) async -> String {
        guard let read = await read(checkout) else { return "\(checkout.lastPathComponent) isn't a git checkout Overterm can list." }
        guard !read.roots.isEmpty else { return "No Terraform roots in \(checkout.lastPathComponent)." }
        var lines = ["Terraform roots of \(checkout.lastPathComponent) (\(read.roots.count)):"]
        for card in read.roots {
            var line = "\(card.path.isEmpty ? "." : card.path) — \(card.rootClass.title.uppercased()) (\(card.verdict.reason)) · workspace \(card.workspace) · \(card.backendSummary)"
            if card.facts.needsInit { line += " · needs init" }
            if let elsewhere = card.stateElsewhere { line += " · no state here (it is in \(elsewhere))" }
            if !card.modules.isEmpty { line += " · calls \(card.modules.joined(separator: ", "))" }
            lines.append(line)
        }
        if !read.modules.isEmpty {
            lines.append("Modules: " + read.modules.map { "\($0.path) (called by \($0.callers.isEmpty ? "none" : $0.callers.joined(separator: ", ")))" }.joined(separator: "; "))
        }
        lines.append("Production roots are plan-only: the person plans and applies them. No tool here applies, destroys or changes state.")
        return lines.joined(separator: "\n")
    }

    // MARK: A root

    /// The root a call names, or the checkout's one root.
    static func root(_ arguments: [String: Any], in checkout: URL, tool: String) async throws -> URL {
        if let named = argument(arguments, "root") {
            let url = try TerraformMCPPath.resolve(named == "." ? "" : named, in: checkout, folder: true)
            guard TerraformProcesses.hasConfiguration(url) else { throw BrowserMCP.ToolError(message: "\(named) has no Terraform configuration.") }
            return url
        }
        guard let read = await read(checkout), !read.roots.isEmpty else { throw BrowserMCP.ToolError(message: "No Terraform roots in this checkout.") }
        guard read.roots.count == 1, let only = read.roots.first else {
            throw BrowserMCP.ToolError(message: "\(tool) needs “root”: one of " + read.roots.map { $0.path.isEmpty ? "." : $0.path }.joined(separator: ", ") + ".")
        }
        return only.folder
    }

    static func relative(_ folder: URL, to checkout: URL) -> String {
        let top = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if path == top { return "." }
        return path.hasPrefix(top + "/") ? String(path.dropFirst(top.count + 1)) : folder.lastPathComponent
    }

    // MARK: tf_fmt_check

    static func formatCheck(_ arguments: [String: Any], in checkout: URL) async throws -> String {
        let root = try await root(arguments, in: checkout, tool: "tf_fmt_check")
        let name = relative(root, to: checkout)
        switch await TerraformEditorModel.run(TerraformCommands.formatCheckDiff, purpose: .agentRead, in: root) {
        case .failure(let failure): return "\(name): \(failure.description)."
        case .success(let run):
            if run.status == 0 { return "\(name): formatted — terraform fmt changes nothing." }
            let diff = String(decoding: run.stdout, as: UTF8.self)
            if run.status == 3 || !diff.isEmpty { return "\(name): not formatted. terraform fmt would change:\n\(diff)" }
            return "\(name): terraform fmt failed: \(TerraformEditorModel.firstError(run.stderr) ?? "exit \(run.status)")"
        }
    }

    // MARK: tf_validate

    /// Why validate isn't run in `root` (5.10): it needs an initialised
    /// root whose lock file is committed and unchanged, and every module
    /// installed — Overterm never runs init for it. Nil: it may run.
    static func validateRefusal(root: URL, checkout: URL, facts: TerraformRootFacts, lockFileClean: Bool) -> String? {
        let lock = root.appendingPathComponent(".terraform.lock.hcl")
        guard FileManager.default.fileExists(atPath: lock.path) else { return "it has no .terraform.lock.hcl" }
        guard lockFileClean else { return "its .terraform.lock.hcl isn't committed, or changed since HEAD" }
        if facts.needsInit { return "a provider it requires isn't in its lock file" }
        if facts.modulesJSON.count < Set(facts.config.moduleSources).count { return "a module it calls isn't installed" }
        return nil
    }

    /// Why `root`'s providers may not be started (5.9, 5.10): what
    /// `validateRefusal` says, its lock file read against git. A tool that
    /// starts providers — validate, `show -json` of a plan — runs outside
    /// the agent's sandbox: only the providers a committed, unchanged lock
    /// file pins, never a binary an agent put in `.terraform/providers`
    /// with a lock file to match. Nil: they may start.
    static func providersRefusal(root: URL, checkout: URL) async -> String? {
        let name = relative(root, to: checkout)
        let facts = await TerraformPanelModel.blocking { TerraformRootFacts.read(root: root, checkout: checkout) }
        let lockPath = name == "." ? ".terraform.lock.hcl" : name + "/.terraform.lock.hcl"
        let tracked = ((try? await Git.run(["ls-files", "--", lockPath], in: checkout)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (try? await Git.run(["status", "--porcelain", "--", lockPath], in: checkout)) ?? "?"
        let clean = !tracked.isEmpty && status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return validateRefusal(root: root, checkout: checkout, facts: facts, lockFileClean: clean)
    }

    static func validate(_ arguments: [String: Any], in checkout: URL) async throws -> String {
        let root = try await root(arguments, in: checkout, tool: "tf_validate")
        let name = relative(root, to: checkout)
        if let why = await providersRefusal(root: root, checkout: checkout) {
            return "\(name) needs init: \(why). Ask the person to run terraform init there — no tool runs it."
        }
        switch await TerraformEditorModel.run(TerraformCommands.validate, purpose: .agentRead, in: root) {
        case .failure(let failure): return "\(name): \(failure.description)."
        case .success(let run):
            guard let validation = try? TerraformValidation.decode(run.stdout, scrub: TerraformValidation.scrub) else {
                return "\(name): validate failed: \(TerraformEditorModel.firstError(run.stderr) ?? "exit \(run.status)")"
            }
            if validation.needsInit { return "\(name) needs init: \(validation.diagnostics.first(where: TerraformValidation.isInitDiagnostic)?.summary ?? "?"). Ask the person." }
            guard !validation.diagnostics.isEmpty else { return "\(name): valid." }
            var lines = ["\(name): \(validation.errors) error(s), \(validation.warnings) warning(s)."]
            for diagnostic in validation.diagnostics.prefix(50) {
                var line = "\(diagnostic.severity.rawValue): \(diagnostic.summary)"
                if let file = diagnostic.file { line += " — \(file)" + (diagnostic.start.map { ":\($0.line):\($0.column)" } ?? "") }
                if !diagnostic.detail.isEmpty { line += "\n  " + TerraformPlanText.cut(diagnostic.detail.replacingOccurrences(of: "\n", with: " "), to: 600) }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: tf_plan_summary

    static func planSummary(_ arguments: [String: Any], in checkout: URL) async throws -> String {
        guard let path = argument(arguments, "path") else {
            throw BrowserMCP.ToolError(
                message: "tf_plan_summary needs “path”: a plan you saved with terraform plan -out=FILE inside the checkout. Overterm's own plans come later.")
        }
        let file = try TerraformMCPPath.resolve(path, in: checkout, folder: false)
        let root: URL
        if let named = argument(arguments, "root") {
            root = try TerraformMCPPath.resolve(named == "." ? "" : named, in: checkout, folder: true)
        } else {
            guard let found = TerraformMCPPath.rootAbove(file, in: checkout) else {
                throw BrowserMCP.ToolError(message: "No Terraform root above \(path): name it with “root”.")
            }
            root = found
        }
        guard let topPath = TerraformMCPPath.real(checkout.path) else { throw BrowserMCP.ToolError(message: "The checkout can't be read.") }
        let top = URL(fileURLWithPath: topPath, isDirectory: true)
        let opened = try TerraformMCPPath.openPlan(file, limit: maxPlanBytes, inside: topPath)
        defer { close(opened) }
        // `show -json` starts the root's providers for their schemas.
        if let why = await providersRefusal(root: root, checkout: top) {
            return "\(path): not read — \(relative(root, to: top)) \(why), and reading a plan starts its providers. Ask the person to run terraform init there; no tool runs it."
        }
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let warning = await TerraformPanelModel.blocking {
            TerraformPaneWarning.make(
                tool: "terraform", operation: "show", isWrite: false, folder: root, checkout: top, facts: TerraformRootFacts.read(root: root, checkout: top),
                workspaceVariable: nil, dataDirVariable: nil, awsProfile: nil, probably: false, settings: settings, identities: identities)
        }
        // The root again, by realpath, around the run: a folder swapped for
        // a link since it was resolved is refused, its answer dropped.
        guard TerraformMCPPath.stillInside(root, top: topPath) else { throw BrowserMCP.ToolError(message: "The root moved while it was read.") }
        let run = await TerraformEditorModel.run(
            TerraformCommands.showPlanDescriptor, purpose: .agentRead, in: root, file: opened, limit: maxPlanBytes, timeout: 120)
        guard TerraformMCPPath.stillInside(root, top: topPath) else { throw BrowserMCP.ToolError(message: "The root moved while it was read.") }
        switch run {
        case .failure(let failure): return "\(path): \(failure.description)."
        case .success(let result):
            guard result.status == 0, !result.truncated else {
                if result.truncated { return "\(path): the plan's JSON is over \(maxPlanBytes >> 20) MB — too large to summarise here." }
                return "\(path): terraform show couldn't read it: \(TerraformEditorModel.firstError(result.stderr) ?? "exit \(result.status)")"
            }
            let decoded = await TerraformPanelModel.blocking { () -> Result<TerraformPlan, TerraformPlan.DecodeError> in
                do { return .success(try TerraformPlan.decode(result.stdout, scrub: TerraformPlan.scrub, secretName: TerraformSecretNames.forAgents)) } catch let error as TerraformPlan.DecodeError {
                    return .failure(error)
                } catch { return .failure(.notJSON) }
            }
            switch decoded {
            case .failure(let error): return "\(path): \(error.description)."
            case .success(let plan):
                let where_ = "\(warning.root) · workspace \(warning.workspace) · \(warning.backend) · \(warning.rootClass.title.uppercased())"
                return TerraformPlanText.summary(plan, root: where_, file: path)
            }
        }
    }
}

/// An agent's path argument, inside its pane's checkout only (5.10): no
/// absolute path, no `~`, no `..`, and — `realpath` of both — no link
/// that leads out (`envs/prod -> ../../acme-live/prod`).
enum TerraformMCPPath {
    static func resolve(_ relative: String, in checkout: URL, folder: Bool) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        if relative.hasPrefix("/") || relative.hasPrefix("~") || relative.contains("\u{0}") || parts.contains("..") || relative.count > 1024 {
            throw BrowserMCP.ToolError(message: "“\(relative)” must be a path inside your checkout, relative to it, without “..”.")
        }
        guard let top = real(checkout.path) else { throw BrowserMCP.ToolError(message: "The checkout can't be read.") }
        let joined = relative.isEmpty ? checkout.path : checkout.appendingPathComponent(relative).path
        guard let resolved = real(joined) else { throw BrowserMCP.ToolError(message: "No such \(folder ? "folder" : "file") in the checkout: \(relative)") }
        guard resolved == top || resolved.hasPrefix(top + "/") else {
            throw BrowserMCP.ToolError(message: "“\(relative)” leads outside your checkout.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue == folder else {
            throw BrowserMCP.ToolError(message: "“\(relative)” isn't a \(folder ? "folder" : "file").")
        }
        return URL(fileURLWithPath: resolved, isDirectory: folder)
    }

    /// The path an open descriptor names now (`F_GETPATH`).
    static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    /// Whether `folder` (resolved earlier) still resolves to itself, inside `top`.
    static func stillInside(_ folder: URL, top: String) -> Bool {
        guard let now = real(folder.path) else { return false }
        return now == folder.path && (now == top || now.hasPrefix(top + "/"))
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The nearest folder at or above `file`'s with a configuration, up to the checkout (bounded).
    static func rootAbove(_ file: URL, in checkout: URL) -> URL? {
        guard let top = real(checkout.path) else { return nil }
        // Real paths both (never `standardizedFileURL`, which drops `/private`).
        var folder = URL(fileURLWithPath: real(file.deletingLastPathComponent().path) ?? file.deletingLastPathComponent().path, isDirectory: true)
        for _ in 0..<32 where folder.pathComponents.count > 1 {
            let path = folder.path
            guard path == top || path.hasPrefix(top + "/") else { return nil }
            if TerraformProcesses.hasConfiguration(folder) { return folder }
            if path == top { return nil }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// The plan file opened (never following a link), checked — a
    /// regular file, at most `limit`, a zip as Terraform writes one — and
    /// handed back as a descriptor terraform reads as `/dev/fd/3`: nothing
    /// can swap the path once it is checked (4.4). The caller closes it.
    static func openPlan(_ file: URL, limit: Int, inside top: String? = nil) throws -> Int32 {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserMCP.ToolError(message: "The plan file can't be opened.") }
        // What was opened, by the descriptor: a folder on the way swapped
        // for a link after `resolve` (`O_NOFOLLOW` guards the last name only)
        // shows here as a path outside the checkout.
        if let top {
            guard let opened = path(of: fd), opened == top || opened.hasPrefix(top + "/") else {
                close(fd)
                throw BrowserMCP.ToolError(message: "The plan file leads outside your checkout.")
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw BrowserMCP.ToolError(message: "The plan isn't a regular file.")
        }
        guard Int(info.st_size) <= limit else {
            close(fd)
            throw BrowserMCP.ToolError(message: "The plan file is over \(limit >> 20) MB.")
        }
        var magic = [UInt8](repeating: 0, count: 4)
        guard pread(fd, &magic, 4, 0) == 4, magic == [0x50, 0x4B, 0x03, 0x04] else {
            close(fd)
            throw BrowserMCP.ToolError(message: "That isn't a saved plan (terraform plan -out=FILE writes one).")
        }
        return fd
    }
}
