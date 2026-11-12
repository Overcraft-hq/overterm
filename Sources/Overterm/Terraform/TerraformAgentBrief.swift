import Foundation

/// Ask Why on a failed validate (analysis 5.10, stage 1c): what the
/// checkout's agent is handed — the root, its workspace, backend type and
/// class, terraform's version, and each diagnostic's summary, detail,
/// range and code (never a snippet's values, which the decoder never
/// kept), every word through `Secrets`' rules again, bounded: it is typed
/// into a terminal and read whole. Pure.
struct TerraformAgentBrief: Equatable, Sendable {
    var message: String
    var subject: String
    var text: String
    var parts: [AskAgentModel.Part]
    /// The checkout whose agent it goes to first.
    var checkout: String?
    var production: Bool

    static let maxDiagnostics = 12

    /// What the brief says of the root (`TerraformRootCard`'s, else the folder's name).
    struct Root: Equatable, Sendable {
        var name: String
        var workspace: String
        var backend: String
        var rootClass: TerraformClass?
        var version: String?
        /// The lock file's providers: `registry.terraform.io/hashicorp/random 3.6.3`.
        var providers: [String] = []
    }

    static func validate(_ diagnostics: [TerraformDiagnostic], root: Root, checkout: String?, scrub: (String) -> String = TerraformValidation.scrub)
        -> TerraformAgentBrief
    {
        let errors = diagnostics.filter { $0.severity == .error }
        let shown = (errors.isEmpty ? diagnostics : errors + diagnostics.filter { $0.severity == .warning }).prefix(maxDiagnostics)
        var about = ["Root: \(scrub(root.name))", "Workspace: \(scrub(root.workspace))", "Backend: \(scrub(root.backend))"]
        if let rootClass = root.rootClass { about.append("Class: \(rootClass.title)" + (rootClass == .production ? " — plan only; never apply, destroy or change its state" : "")) }
        if let version = root.version { about.append("Terraform \(scrub(version))") }
        if !root.providers.isEmpty { about.append("Providers (lock file): " + root.providers.prefix(20).map(scrub).joined(separator: ", ")) }
        var lines: [String] = []
        for diagnostic in shown {
            var line = "\(diagnostic.severity == .error ? "Error" : "Warning"): \(scrub(diagnostic.summary))"
            if let file = diagnostic.file {
                line += " — \(scrub(file))" + (diagnostic.start.map { ":\($0.line):\($0.column)" } ?? "")
            }
            lines.append(line)
            if !diagnostic.detail.isEmpty { lines.append("  " + TerraformPlanText.cut(scrub(diagnostic.detail).replacingOccurrences(of: "\n", with: " "), to: 600)) }
            if let code = diagnostic.code, !code.isEmpty {
                lines.append(contentsOf: code.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "  │ " + TerraformPlanText.cut(scrub(String($0)), to: 200) })
            }
        }
        if diagnostics.count > shown.count { lines.append("… and \(diagnostics.count - shown.count) more.") }
        let subject = "terraform validate in \(root.name)"
        let message =
            "terraform validate fails in \(scrub(root.name)): \(errors.count) error\(errors.count == 1 ? "" : "s"). Why, and what would fix it? "
            + "Edit the configuration; don't run init, plan or apply — the person runs those."
        let parts = [
            AskAgentModel.Part(title: "The root", text: about.joined(separator: "\n")),
            AskAgentModel.Part(title: "Validate's diagnostics", text: lines.joined(separator: "\n")),
        ]
        let text = parts.map { "\($0.title):\n\($0.text)" }.joined(separator: "\n\n")
        return TerraformAgentBrief(message: message, subject: subject, text: text, parts: parts, checkout: checkout, production: root.rootClass == .production)
    }

    static let logLines = 60

    /// Ask Why on a failed plan or init, or a held lock (5.10): the root,
    /// the operation and its diagnostics, the parsed holder and its age,
    /// the last 60 lines of its log — every word through `Secrets` again.
    static func run(
        operation: String, diagnostics: [TerraformDiagnostic], lock: TerraformLockInfo?, log: [String], root: Root, checkout: String?,
        now: Date = Date(), scrub: (String) -> String = TerraformValidation.scrub
    ) -> TerraformAgentBrief {
        var about = ["Root: \(scrub(root.name))", "Workspace: \(scrub(root.workspace))", "Backend: \(scrub(root.backend))"]
        if let rootClass = root.rootClass { about.append("Class: \(rootClass.title)" + (rootClass == .production ? " — plan only; never apply, destroy or change its state" : "")) }
        if let version = root.version { about.append("Terraform \(scrub(version))") }
        if !root.providers.isEmpty { about.append("Providers (lock file): " + root.providers.prefix(20).map(scrub).joined(separator: ", ")) }
        var parts = [AskAgentModel.Part(title: "The root", text: about.joined(separator: "\n"))]
        if let lock {
            var lines = [scrub(lock.said(now: now))]
            if let age = lock.age(now: now) { lines.append("Held for \(age).") }
            lines.append("Lock ID \(scrub(lock.id))" + (lock.path.map { " · path \(scrub($0))" } ?? ""))
            if lock.http { lines.append("An http backend: its force-unlock removes whatever lock is there.") }
            parts.append(AskAgentModel.Part(title: "The state's lock", text: lines.joined(separator: "\n")))
        }
        var lines: [String] = []
        for diagnostic in diagnostics.prefix(maxDiagnostics) {
            var line = "\(diagnostic.severity == .error ? "Error" : "Warning"): \(scrub(diagnostic.summary))"
            if let file = diagnostic.file { line += " — \(scrub(file))" + (diagnostic.start.map { ":\($0.line):\($0.column)" } ?? "") }
            lines.append(line)
            if !diagnostic.detail.isEmpty { lines.append("  " + TerraformPlanText.cut(scrub(diagnostic.detail).replacingOccurrences(of: "\n", with: " "), to: 600)) }
        }
        if !lines.isEmpty { parts.append(AskAgentModel.Part(title: "\(operation)'s diagnostics", text: lines.joined(separator: "\n"))) }
        let tail = log.suffix(logLines).map { TerraformPlanText.cut(scrub($0), to: 300) }
        if !tail.isEmpty { parts.append(AskAgentModel.Part(title: "The last lines of its log", text: tail.joined(separator: "\n"))) }
        let subject = "terraform \(operation) in \(root.name)"
        let message =
            lock != nil
            ? "terraform \(operation) in \(scrub(root.name)) can't take the state's lock. Who holds it, is it stale, and what should the person do? Don't run force-unlock, plan or apply — the person decides."
            : "terraform \(operation) fails in \(scrub(root.name)). Why, and what would fix it? Edit the configuration; don't run init, plan or apply — the person runs those."
        let text = parts.map { "\($0.title):\n\($0.text)" }.joined(separator: "\n\n")
        return TerraformAgentBrief(message: message, subject: subject, text: text, parts: parts, checkout: checkout, production: root.rootClass == .production)
    }
}
