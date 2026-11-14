import Foundation

/// A root's `terraform test` files (analysis 2.9, stage 2d, D-19), read
/// without running anything: each file's `run` blocks and their lines,
/// the providers it mocks (`mock_provider`) and configures for real
/// (`provider`), the modules its runs load (`run { module { source } }`).
/// From those and the root's own configuration — followed into every
/// local module it calls, bounded — whether every provider a run would
/// start is mocked and nothing in its code runs a command: only then is a
/// test a read — nothing reaches a cloud, it runs without credentials, on
/// any class. Anything not read (a file past a bound, JSON configuration,
/// a module from outside the checkout, nesting past the bound) counts as
/// real, never as mocked. A test with a real provider creates real
/// infrastructure with the root's credentials: a write, asked
/// (`TerraformVerb.testRealProviders`). Pure, but `list` and `read`,
/// which read the root's folder (bounded).
enum TerraformTestFiles {
    /// The most test files read, and each file's bound.
    static let maxFiles = 200
    static let maxBytes = 256 << 10
    /// The most local module folders read, every level together, and how deep they nest.
    static let maxModules = 16
    static let maxDepth = 4
    /// Terraform's own provider (`terraform_data`, `terraform_remote_state`):
    /// built in, nothing to mock.
    static let builtin: Set<String> = ["terraform"]
    /// `terraform test`'s default test directory, beside the root's own files.
    static let directory = "tests"
    /// What in a configuration runs on this Mac whatever is mocked: a
    /// provisioner (`local-exec` on a `terraform_data`), a data source
    /// that runs a command or fetches, an action (5.1, 5.5).
    static let riskKinds: Set<TerraformRunRisk.Kind> = [.command, .fetch, .provisioner, .action]

    struct Run: Equatable, Sendable {
        var name: String
        /// 1-based, the `run` block's first line.
        var line: Int
    }

    /// What one test file says.
    struct Facts: Equatable, Sendable {
        /// Relative to the root: `tests/acme.tftest.hcl`.
        var path: String
        var runs: [Run] = []
        /// `mock_provider "<name>"`'s names, without an `alias`: those mock
        /// the default configuration every run starts.
        var mocked: Set<String> = []
        /// `provider "<name>"` blocks: configured for real.
        var providers: Set<String> = []
        /// What its runs load: `run { module { source = "…" } }`.
        var moduleSources: [String] = []
        /// `mock_provider "<name>" { alias = … }`: only runs that map it
        /// (`providers = { aws = aws.fake }`) use it — every other run
        /// starts the real default, so it mocks nothing here.
        var aliasedMocks: Set<String> = []
    }

    enum Mocking: Equatable, Sendable {
        /// Every provider a run would start is mocked, or built in.
        case mocked
        /// Why not: the providers left real, what its code runs, or what can't be told.
        case real(String)

        var isMocked: Bool { self == .mocked }
    }

    /// Something that couldn't be read: counted real.
    struct Unread: Error, Equatable, Sendable {
        var why: String
    }

    /// What a folder and the local modules it calls say: the providers
    /// they name, what their code runs.
    struct Reach: Equatable, Sendable {
        var providers: Set<String> = []
        var risks: [TerraformRunRisk] = []
    }

    static func isTestFileName(_ name: String) -> Bool {
        name.hasSuffix(".tftest.hcl") || name.hasSuffix(".tftest.json")
    }

    /// One file's facts. `.tftest.json` isn't scanned: its blocks aren't
    /// read here, so it counts as not mocked (`mocking`).
    static func scan(_ text: String, path: String) -> Facts {
        var facts = Facts(path: path)
        guard path.hasSuffix(".hcl") else {
            facts.providers.insert("(a .tftest.json file Overterm doesn't read)")
            return facts
        }
        let nsText = text as NSString
        let scanned = TerraformBlocks.scan(text)
        for block in scanned.blocks {
            switch block.type {
            case "run":
                guard let name = block.labels.first else { continue }
                facts.runs.append(Run(name: name, line: line(of: block.range.location, in: nsText)))
                for nested in TerraformBlocks.nested(in: block, of: text).blocks where nested.type == "module" {
                    if let source = nested.attributes.first(where: { $0.name == "source" })?.value {
                        facts.moduleSources.append(source)
                    } else {
                        // A module whose source isn't one plain string: where it is can't be told.
                        facts.moduleSources.append("(a module source Overterm can't read)")
                    }
                }
            case "mock_provider":
                guard let name = block.labels.first else { continue }
                if block.attributes.contains(where: { $0.name == "alias" }) {
                    facts.aliasedMocks.insert(name)
                } else {
                    facts.mocked.insert(name)
                }
            case "provider":
                if let name = block.labels.first { facts.providers.insert(name) }
            default:
                continue
            }
        }
        return facts
    }

    /// The 1-based line of `offset` in `text`.
    static func line(of offset: Int, in text: NSString) -> Int {
        var line = 1
        let end = min(max(0, offset), text.length)
        var index = 0
        while index < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }

    /// Whether every provider `facts`' runs would start is mocked.
    /// `providers`: the root's (and its local modules'), nil when they
    /// can't be told — a module from outside the checkout.
    static func mocking(_ facts: Facts, providers: Set<String>?) -> Mocking {
        guard let providers else {
            return .real("a module it loads comes from outside the checkout: its providers can't be told")
        }
        let real = providers.union(facts.providers).union(facts.aliasedMocks).subtracting(builtin).subtracting(facts.mocked)
        guard real.isEmpty else { return .real("not mocked: " + real.sorted().joined(separator: ", ")) }
        return .mocked
    }

    /// Several files at once: mocked only when each is.
    static func mocking(_ files: [Facts], providers: (Facts) -> Set<String>?) -> Mocking {
        for file in files {
            if case .real(let why) = mocking(file, providers: providers(file)) { return .real("\(file.path): \(why)") }
        }
        return .mocked
    }

    /// A module source inside the checkout: `./x`, `../x`.
    static func isLocalSource(_ source: String) -> Bool { source.hasPrefix("./") || source.hasPrefix("../") }

    // MARK: Reading the root's folder

    /// The root's test files, relative to it: beside its `.tf` files and
    /// in `tests/`, sorted, at most `limit`. Blocking.
    static func list(root: URL, limit: Int = maxFiles) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        for folder in ["", directory] {
            let url = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            let names = ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            for name in names where isTestFileName(name) {
                found.append(folder.isEmpty ? name : folder + "/" + name)
            }
        }
        return Array(found.prefix(limit))
    }

    /// What the root's tests need known before one runs, read off the main
    /// thread: each file's facts, and the providers its runs would start.
    struct Read: Sendable {
        var files: [Facts]
        /// Test files that would run but weren't read: too many, too
        /// large, not a file. Any makes the test real.
        var unread: [String] = []
        /// Test files (or a file given) that resolve outside the checkout: refused.
        var outside: [String] = []
        /// Every provider anything names — the root, every module it or
        /// a run loads, each file's mocks and providers: what starts for
        /// its schema even when mocked.
        var providerNames: Set<String> = []
        /// What its code runs on this Mac whatever is mocked.
        var risks: [TerraformRunRisk] = []
        /// Everything that would run was read.
        var complete = true
        var mocking: Mocking
    }

    /// Reads `files` (relative to `root`; all of them when nil) and the
    /// configuration their runs load — the root's own and each run
    /// module's, every local module followed, inside `checkout`.
    /// Blocking, bounded.
    static func read(root: URL, checkout: URL, files given: [String]?) -> Read {
        let paths = given ?? list(root: root, limit: maxFiles + 1)
        var read = Read(files: [], mocking: .mocked)
        if paths.count > maxFiles { read.unread.append("more than \(maxFiles) test files") }
        for path in paths.prefix(maxFiles) where TerraformCommands.isTestFile(path) {
            // A test file that is a link out of the checkout isn't read, nor run.
            guard let url = inside(root.appendingPathComponent(path), checkout: checkout) else {
                read.outside.append(path)
                continue
            }
            // Not there: terraform finds nothing to run either.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = TerraformRootFacts.smallFile(url, limit: maxBytes), let text = String(data: data, encoding: .utf8) else {
                read.unread.append(path)
                continue
            }
            read.files.append(scan(text, path: path))
        }
        var why: String?
        func real(_ said: String) { if why == nil { why = said } }
        if !read.unread.isEmpty { real("\(read.unread.joined(separator: ", ")) couldn't be read: what it starts can't be told") }
        let rootReach = reach(root, checkout: checkout)
        switch rootReach {
        case .success(let found):
            read.providerNames.formUnion(found.providers)
            read.risks.append(contentsOf: found.risks)
        case .failure(let unread):
            read.complete = false
            real(unread.why)
        }
        for file in read.files {
            read.providerNames.formUnion(file.mocked.union(file.aliasedMocks).union(file.providers))
            var providers: Set<String>? = try? rootReach.get().providers
            for source in file.moduleSources {
                // A run's module source is relative to the root.
                guard isLocalSource(source) else {
                    read.complete = false
                    providers = nil
                    break
                }
                switch reach(root.appendingPathComponent(source), checkout: checkout) {
                case .success(let found):
                    providers?.formUnion(found.providers)
                    read.providerNames.formUnion(found.providers)
                    read.risks.append(contentsOf: found.risks.filter { !read.risks.contains($0) })
                case .failure(let unread):
                    read.complete = false
                    real("\(file.path): \(unread.why)")
                    providers = nil
                }
                if providers == nil { break }
            }
            if case .real(let said) = mocking(file, providers: providers) { real("\(file.path): \(said)") }
        }
        if !read.risks.isEmpty {
            real("its code runs on this Mac whatever is mocked: " + read.risks.prefix(5).map(\.said).joined(separator: "; "))
        }
        if !read.unread.isEmpty { read.complete = false }
        read.mocking = why.map(Mocking.real) ?? .mocked
        return read
    }

    /// What `folder`'s configuration and every local module it calls say,
    /// followed breadth first: at most `maxModules` folders, `maxDepth`
    /// levels. A module from outside the checkout, one past the bounds,
    /// or configuration that couldn't be read: `Unread` — real, never mocked.
    static func reach(_ folder: URL, checkout: URL) -> Result<Reach, Unread> {
        var found = Reach()
        var visited: Set<String> = []
        guard let start = inside(folder, checkout: checkout) else {
            return .failure(Unread(why: "a module it loads comes from outside the checkout: its providers can't be told"))
        }
        var queue: [(folder: URL, depth: Int)] = [(start, 0)]
        while !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            guard visited.insert(url.path).inserted else { continue }
            guard visited.count <= maxModules + 1 else { return .failure(Unread(why: "more than \(maxModules) local modules: not all read")) }
            let config: TerraformConfigFacts
            switch configuration(in: url) {
            case .success(let read): config = read
            case .failure(let unread): return .failure(unread)
            }
            found.providers.formUnion(config.providerNames)
            for risk in TerraformRunRisks.risks(config: config, lockProviders: nil) where riskKinds.contains(risk.kind) && !found.risks.contains(risk) {
                found.risks.append(risk)
            }
            for source in config.moduleSources {
                guard isLocalSource(source) else {
                    return .failure(Unread(why: "a module it loads comes from outside the checkout (\(source)): its providers can't be told"))
                }
                guard let next = inside(url.appendingPathComponent(source), checkout: checkout) else {
                    return .failure(Unread(why: "a module it loads comes from outside the checkout: its providers can't be told"))
                }
                guard depth < maxDepth else { return .failure(Unread(why: "its local modules nest deeper than \(maxDepth) levels: not all read")) }
                queue.append((next, depth + 1))
            }
        }
        return .success(found)
    }

    /// A folder's configuration, every file of it read, or why not: JSON
    /// configuration (`.tf.json`, not read here), a file past the bound
    /// or not UTF-8, more files than the bound — each would leave a
    /// provider unseen. Blocking.
    static func configuration(in folder: URL) -> Result<TerraformConfigFacts, Unread> {
        let place = folder.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return .failure(Unread(why: "\(place) couldn't be listed: what it starts can't be told"))
        }
        let config = names.filter { $0.hasSuffix(".tf") || $0.hasSuffix(".tofu") || $0.hasSuffix(".tf.json") || $0.hasSuffix(".tofu.json") }.sorted()
        guard config.count <= TerraformRootGuess.maxFilesPerFolder else {
            return .failure(Unread(why: "\(place) has more than \(TerraformRootGuess.maxFilesPerFolder) configuration files: not all read"))
        }
        var texts: [String] = []
        for name in config {
            if name.hasSuffix(".json") { return .failure(Unread(why: "\(place)/\(name) is JSON configuration, which Overterm doesn't read: its providers can't be told")) }
            guard let data = TerraformRootFacts.smallFile(folder.appendingPathComponent(name)), let text = String(data: data, encoding: .utf8) else {
                return .failure(Unread(why: "\(place)/\(name) couldn't be read (past 256 KB, or not a file): its providers can't be told"))
            }
            texts.append(text)
        }
        return .success(TerraformConfigFacts.read(texts))
    }

    /// `url` with symlinks resolved, when it is inside `checkout`.
    static func inside(_ url: URL, checkout: URL) -> URL? {
        let top = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path == top || resolved.path.hasPrefix(top + "/") ? resolved : nil
    }
}

/// One line of `terraform test -json` (1.6+; analysis 2.9): the files and
/// runs found, a file's and a run's progress and status, the summary, and
/// a diagnostic with the file and run it is about. Only these are kept:
/// `test_plan` and `test_state` (which `-verbose` would print, values and
/// all — never passed) and anything else are dropped, by type alone. A
/// diagnostic goes through `TerraformValidation`'s allow-list: never a
/// snippet's values, nor `test_assertion_expr`'s two sides. Pure.
enum TerraformTestMessage: Equatable, Sendable {
    /// `test_abstract`: each file and its runs, before any starts.
    case abstract([String: [String]])
    /// `test_file`: `progress` starting, teardown, complete; `status` once complete.
    case file(path: String, progress: String, status: String?)
    /// `test_run`.
    case run(path: String, run: String, progress: String, status: String?)
    /// `test_summary`.
    case summary(status: String, passed: Int, failed: Int, errored: Int, skipped: Int)
    /// A `diagnostic` with `@testfile` (and `@testrun`).
    case diagnostic(file: String?, run: String?, TerraformDiagnostic)
    /// Any other `test_*` line, by type only.
    case other(String)

    static let maxNames = 2_000

    static func decode(type: String, object: [String: Any], scrub: (String) -> String) -> TerraformTestMessage {
        func short(_ value: Any?) -> String? { (value as? String).map { scrub(String($0.prefix(1_024))) } }
        switch type {
        case "test_abstract":
            var files: [String: [String]] = [:]
            for (path, runs) in (object["test_abstract"] as? [String: Any] ?? [:]).prefix(TerraformTestFiles.maxFiles) {
                files[scrub(String(path.prefix(1_024)))] = ((runs as? [Any]) ?? []).prefix(maxNames).compactMap(short)
            }
            return .abstract(files)
        case "test_file":
            let file = object["test_file"] as? [String: Any] ?? [:]
            return .file(path: short(file["path"]) ?? "?", progress: short(file["progress"]) ?? "?", status: short(file["status"]))
        case "test_run":
            let run = object["test_run"] as? [String: Any] ?? [:]
            return .run(path: short(run["path"]) ?? "?", run: short(run["run"]) ?? "?", progress: short(run["progress"]) ?? "?", status: short(run["status"]))
        case "test_summary":
            let summary = object["test_summary"] as? [String: Any] ?? [:]
            func count(_ key: String) -> Int { (summary[key] as? NSNumber)?.intValue ?? 0 }
            return .summary(
                status: short(summary["status"]) ?? "?", passed: count("passed"), failed: count("failed"), errored: count("errored"), skipped: count("skipped"))
        case "diagnostic":
            let diagnostic = TerraformValidation.decodeDiagnostic(object["diagnostic"] as? [String: Any] ?? [:], scrub: scrub)
            return .diagnostic(file: short(object["@testfile"]), run: short(object["@testrun"]), diagnostic)
        default:
            return .other(scrub(String(type.prefix(64))))
        }
    }

    /// The line the raw log shows for it.
    var logLine: String {
        switch self {
        case .abstract(let files):
            let runs = files.values.reduce(0) { $0 + $1.count }
            return "Found \(files.count) file\(files.count == 1 ? "" : "s") and \(runs) run block\(runs == 1 ? "" : "s")"
        case .file(let path, let progress, let status): return "\(path)… \(status ?? progress)"
        case .run(let path, let run, let progress, let status): return "\(path): run \"\(run)\"… \(status ?? progress)"
        case .summary(let status, let passed, let failed, let errored, let skipped):
            return "\(status == "pass" ? "Success" : "Failure")! \(passed) passed, \(failed) failed"
                + (errored > 0 ? ", \(errored) errored" : "") + (skipped > 0 ? ", \(skipped) skipped" : "") + "."
        case .diagnostic(let file, let run, let diagnostic):
            let place = [file, run.map { "run \"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            return "\(diagnostic.severity == .error ? "Error" : "Warning"): \(diagnostic.summary)" + (diagnostic.detail.isEmpty ? "" : " — " + diagnostic.detail)
                + (place.isEmpty ? "" : " (\(place))")
        case .other(let type): return type
        }
    }
}

/// A test run's files and runs as its stream says them (2.9): each run
/// listed before it starts (from the files read, then `test_abstract`),
/// then its status; its failures by file and run, at their lines. Pure.
struct TerraformTestReport: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case pending, running, pass, fail, error, skip

        init(terraform: String?) {
            self = terraform.flatMap(Status.init(rawValue:)) ?? .error
        }

        var symbol: String {
            switch self {
            case .pending: "·"
            case .running: "…"
            case .pass: "✓"
            case .fail: "✗"
            case .error: "!"
            case .skip: "–"
            }
        }

        var isFailure: Bool { self == .fail || self == .error }
    }

    struct RunRow: Equatable, Sendable, Identifiable {
        var file: String
        var name: String
        var line: Int?
        var status: Status = .pending
        var diagnostics: [TerraformDiagnostic] = []
        var id: String { file + "\u{0}" + name }
    }

    struct FileRow: Equatable, Sendable, Identifiable {
        var path: String
        var status: Status = .pending
        var runs: [RunRow] = []
        /// A file's own diagnostics: one that doesn't parse, a provider it can't start.
        var diagnostics: [TerraformDiagnostic] = []
        var id: String { path }
    }

    struct Summary: Equatable, Sendable {
        var status: String
        var passed = 0, failed = 0, errored = 0, skipped = 0

        var said: String {
            var parts = ["\(passed) passed", "\(failed) failed"]
            if errored > 0 { parts.append("\(errored) errored") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: ", ")
        }
    }

    static let maxDiagnostics = 200

    var files: [FileRow] = []
    var summary: Summary?
    /// Diagnostics of no file: a filter that names none, the root's own.
    var diagnostics: [TerraformDiagnostic] = []
    private var kept = 0

    init(planned: [TerraformTestFiles.Facts] = []) {
        files = planned.map { file in
            FileRow(path: file.path, runs: file.runs.map { RunRow(file: file.path, name: $0.name, line: $0.line) })
        }
    }

    private mutating func fileIndex(_ path: String) -> Int {
        if let index = files.firstIndex(where: { $0.path == path }) { return index }
        files.append(FileRow(path: path))
        return files.count - 1
    }

    private mutating func runIndex(_ name: String, in file: Int) -> Int {
        if let index = files[file].runs.firstIndex(where: { $0.name == name }) { return index }
        files[file].runs.append(RunRow(file: files[file].path, name: name))
        return files[file].runs.count - 1
    }

    mutating func absorb(_ message: TerraformTestMessage) {
        switch message {
        case .abstract(let found):
            for path in found.keys.sorted() {
                let file = fileIndex(path)
                for name in found[path] ?? [] { _ = runIndex(name, in: file) }
            }
        case .file(let path, let progress, let status):
            let file = fileIndex(path)
            files[file].status = progress == "complete" ? Status(terraform: status) : .running
        case .run(let path, let name, let progress, let status):
            let file = fileIndex(path)
            let run = runIndex(name, in: file)
            if progress == "complete" {
                files[file].runs[run].status = Status(terraform: status)
            } else if progress == "starting" {
                files[file].runs[run].status = .running
            }
        case .summary(let status, let passed, let failed, let errored, let skipped):
            summary = Summary(status: status, passed: passed, failed: failed, errored: errored, skipped: skipped)
        case .diagnostic(let path, let name, let diagnostic):
            guard kept < Self.maxDiagnostics else { return }
            kept += 1
            guard let path else { return diagnostics.append(diagnostic) }
            let file = fileIndex(path)
            if let name {
                files[file].runs[runIndex(name, in: file)].diagnostics.append(diagnostic)
            } else {
                files[file].diagnostics.append(diagnostic)
            }
        case .other:
            break
        }
    }

    var runs: [RunRow] { files.flatMap(\.runs) }

    /// The failed runs (and files that errored), in order.
    var failures: [(file: String, run: String?, diagnostics: [TerraformDiagnostic])] {
        var found: [(file: String, run: String?, diagnostics: [TerraformDiagnostic])] = []
        for file in files {
            if file.status == .error || !file.diagnostics.isEmpty, file.runs.allSatisfy({ !$0.status.isFailure }) {
                found.append((file.path, nil, file.diagnostics))
            }
            for run in file.runs where run.status.isFailure { found.append((file.path, run.name, run.diagnostics)) }
        }
        return found
    }

    /// Every diagnostic with a place, by the file it names (relative to
    /// the root): what the editor marks.
    var placed: [String: [TerraformDiagnostic]] {
        var found: [String: [TerraformDiagnostic]] = [:]
        for diagnostic in diagnostics + files.flatMap({ $0.diagnostics + $0.runs.flatMap(\.diagnostics) }) {
            guard let file = diagnostic.file, diagnostic.start != nil else { continue }
            found[file, default: []].append(diagnostic)
        }
        return found
    }

    /// As an agent reads it (`tf_test`): the summary, each run's status,
    /// each failure with its file and line. Masked already (the stream's
    /// decode); strings cut.
    func text(root: String, mocked: Bool) -> String {
        var lines: [String] = []
        let total = runs.count
        lines.append("terraform test in \(root)" + (mocked ? " (every provider mocked)" : " (real providers)") + ": " + (summary?.said ?? "\(total) runs"))
        for file in files {
            lines.append("\(file.path): \(file.status.rawValue)")
            for diagnostic in file.diagnostics.prefix(10) { lines.append("  " + Self.said(diagnostic)) }
            for run in file.runs {
                lines.append("  run \"\(run.name)\"" + (run.line.map { " (line \($0))" } ?? "") + ": \(run.status.rawValue)")
                for diagnostic in run.diagnostics.prefix(10) { lines.append("    " + Self.said(diagnostic)) }
            }
        }
        for diagnostic in diagnostics.prefix(10) { lines.append(Self.said(diagnostic)) }
        return lines.joined(separator: "\n")
    }

    static func said(_ diagnostic: TerraformDiagnostic) -> String {
        var line = "\(diagnostic.severity.rawValue): \(diagnostic.summary)"
        if let file = diagnostic.file { line += " — \(file)" + (diagnostic.start.map { ":\($0.line)" } ?? "") }
        if !diagnostic.detail.isEmpty { line += ": " + TerraformPlanText.cut(diagnostic.detail.replacingOccurrences(of: "\n", with: " "), to: 400) }
        return line
    }
}
