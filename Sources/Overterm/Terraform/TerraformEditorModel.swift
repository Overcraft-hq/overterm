import Combine
import Foundation

extension Notification.Name {
    /// A folder's `terraform validate` answered: its editors lay the
    /// diagnostics over their buffers. The object is the `TerraformFolder`.
    static let terraformDiagnostics = Notification.Name("overterm.terraformDiagnostics")
}

/// The editor's Terraform, stage 1a (analysis 4.14): a module folder's
/// validate, `terraform fmt` over a buffer, and whether a checkout already
/// passes `fmt -check` (format on save is on only where it does). One for
/// the app. Nothing runs by itself but what a person did: opening a file
/// asks `fmt -check` of its checkout once, saving one validates its folder
/// where terraform-ls isn't running, and the bar's buttons. No init, ever.
@MainActor
final class TerraformEditorModel: ObservableObject {
    static let shared = TerraformEditorModel()

    private var folders: [String: TerraformFolder] = [:]
    /// A checkout's `fmt -check`: true passes, false doesn't, absent while
    /// asked or never.
    @Published private var formatChecks: [String: Bool] = [:]
    private var formatChecking: Set<String> = []

    /// The folder `file` is in: its module, the root terraform runs in.
    /// Its checkout is found once, here, never on a redraw or a save.
    func folder(for file: URL) -> TerraformFolder {
        let url = file.standardizedFileURL.deletingLastPathComponent()
        if let folder = folders[url.path] { return folder }
        let gitRoot = EditorViewController.gitRoot(of: file)
        let folder = TerraformFolder(
            url: url, checkout: gitRoot?.standardizedFileURL ?? url, formatScope: Self.formatScope(of: file, gitRoot: gitRoot, home: NSHomeDirectory()))
        folders[url.path] = folder
        return folder
    }

    /// The files whose formatting is terraform's: `fmt` reads them all as
    /// HCL. Not the lock file, which `init` writes, nor Terragrunt's.
    nonisolated static func isFormattable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["tf", "tfvars", "tofu"].contains(url.pathExtension.lowercased()) || name.hasSuffix(".tftest.hcl") || name.hasSuffix(".tfmock.hcl")
    }

    /// The files validate speaks of, and F12 and ⇧⌘O read.
    nonisolated static func isTerraform(_ url: URL) -> Bool {
        isFormattable(url) && !url.lastPathComponent.lowercased().hasSuffix(".tfmock.hcl")
    }

    // MARK: Format on save

    /// Where `fmt -check` looks for a file: its checkout's top, all of it,
    /// when that is a git top narrower than the home folder; else the
    /// file's own folder alone. A dotfiles repository makes `~` a git top,
    /// and a loose `~/main.tf` or `/Volumes/x/main.tf` has none: a
    /// recursive check there would read the whole disk and bring up
    /// macOS's privacy prompts in Overterm's name — the rule the language
    /// servers' roots keep (`LSPWatchedFiles.watchable`).
    struct FormatScope: Equatable, Sendable {
        var folder: URL
        var recursive: Bool
        var arguments: [String] { recursive ? TerraformCommands.formatCheck : TerraformCommands.formatCheckFolder }
        var key: String { (recursive ? "recursive\u{0}" : "folder\u{0}") + folder.path }
    }

    nonisolated static func formatScope(of file: URL, gitRoot: URL?, home: String) -> FormatScope {
        if let top = gitRoot?.standardizedFileURL, LSPWatchedFiles.watchable(top.path, home: home) {
            return FormatScope(folder: top, recursive: true)
        }
        return FormatScope(folder: file.standardizedFileURL.deletingLastPathComponent(), recursive: false)
    }

    /// Asks `fmt -check` of `folder`'s scope: once a run when it opens,
    /// again (`again`) on a manual Format or Validate — a person who ran
    /// `terraform fmt -recursive` in a terminal sees the bar follow.
    func checkFormat(for folder: TerraformFolder, again: Bool = false) {
        guard Settings.shared.terraformFormatOnSave else { return }
        let scope = folder.formatScope
        let key = scope.key
        guard again || formatChecks[key] == nil, !formatChecking.contains(key) else { return }
        formatChecking.insert(key)
        Task { [weak self] in
            let result = await Self.run(scope.arguments, purpose: .format, in: scope.folder)
            guard let self else { return }
            self.formatChecking.remove(key)
            // 0: every file formatted; 3: some aren't (listed). Anything else says nothing.
            switch result {
            case .success(let run) where run.status == 0 && !run.timedOut: self.formatChecks[key] = true
            case .success(let run) where run.status == 3: self.formatChecks[key] = false
            default: break
            }
        }
    }

    /// Whether saving `file` formats it first.
    func formatsOnSave(_ file: URL) -> Bool {
        Settings.shared.terraformFormatOnSave && Self.isFormattable(file) && checkoutPassesFormat(folder(for: file)) == true
    }

    /// What `fmt -check` said of `folder`'s checkout, nil while unknown.
    func checkoutPassesFormat(_ folder: TerraformFolder) -> Bool? { formatChecks[folder.formatScope.key] }

    /// The same for `file`'s folder.
    func checkoutPassesFormat(_ file: URL) -> Bool? { checkoutPassesFormat(folder(for: file)) }

    enum FormatResult: Equatable {
        case formatted(String)
        case failed(String)
        case noTerraform
    }

    /// `text` as `terraform fmt -` gives it back. Writes nothing.
    func format(_ text: String, file: URL) async -> FormatResult {
        let folder = file.standardizedFileURL.deletingLastPathComponent()
        switch await Self.run(TerraformCommands.formatStandardInput, purpose: .format, in: folder, input: Data(text.utf8)) {
        case .failure(.noTerraform): return .noTerraform
        case .failure(let failure): return .failed(failure.description)
        case .success(let run):
            if run.truncated { return .failed("the file is too large to format here (its formatted text is over 1 MB)") }
            if run.timedOut { return .failed("terraform fmt took longer than \(Int(TerraformRun.timeout)) s") }
            if run.status == 0 { return .formatted(String(decoding: run.stdout, as: UTF8.self)) }
            return .failed(Self.firstError(run.stderr) ?? "terraform fmt exited \(run.status)")
        }
    }

    /// The first `Error: …` of terraform's text, and the line it names.
    nonisolated static func firstError(_ stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.firstIndex(where: { $0.hasPrefix("Error:") }) else {
            return lines.first { !$0.isEmpty }
        }
        let summary = String(lines[index].dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        if let on = lines[index...].first(where: { $0.hasPrefix("on <stdin> line ") }),
            let line = on.dropFirst("on <stdin> line ".count).split(whereSeparator: { !$0.isNumber }).first
        {
            return "line \(line): \(summary)"
        }
        return summary
    }

    // MARK: Running

    enum RunFailure: Error, Equatable, CustomStringConvertible {
        case noTerraform
        case environment(String)
        case run(String)

        var description: String {
            switch self {
            case .noTerraform: "No terraform found"
            case .environment(let why): why
            case .run(let why): why
            }
        }
    }

    /// One of `TerraformCommands`' lines in `folder`, in the stripped
    /// environment (`TerraformEnvironment`), off the main thread.
    nonisolated static func run(
        _ arguments: [String], purpose: TerraformEnvironment.Purpose, in folder: URL, input: Data? = nil
    ) async -> Result<TerraformRun.Result, RunFailure> {
        let setUp: Result<(URL, [String: String]), RunFailure> = await withCheckedContinuation { continuation in
            let work: @Sendable () -> Void = { continuation.resume(returning: prepare(purpose: purpose, root: folder)) }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        switch setUp {
        case .failure(let failure): return .failure(failure)
        case .success(let (binary, environment)):
            do {
                return .success(try await TerraformRun.short(binary, arguments, in: folder, environment: environment, input: input))
            } catch {
                return .failure(.run("\(error)"))
            }
        }
    }

    /// The binary and the environment for a run in `root`. Blocking (the
    /// login shell, the scratch folder): a GCD thread's.
    nonisolated static func prepare(purpose: TerraformEnvironment.Purpose, root: URL) -> Result<(URL, [String: String]), RunFailure> {
        guard let binary = TerraformCLI.binary() else { return .failure(.noTerraform) }
        do {
            let base = try AppEnvironment.terraformBaseEnvironment()
            let scratch = try TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
            return .success((binary, TerraformEnvironment.build(base: base, purpose: purpose, root: root, scratch: scratch)))
        } catch {
            return .failure(.environment("Terraform's scratch folder: \(error.localizedDescription)"))
        }
    }

}

/// One module folder: its last validate, and what it found per file.
@MainActor
final class TerraformFolder: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case valid(warnings: Int)
        case problems(errors: Int, warnings: Int)
        /// Validate can't say anything until the folder is initialised:
        /// said once; a save doesn't validate it again until asked.
        case needsInit(String)
        case noTerraform
        case failed(String)

        var text: String {
            switch self {
            case .idle: ""
            case .running: "Validating…"
            case .valid(let warnings): warnings == 0 ? "Valid" : "Valid · \(warnings) warning\(warnings == 1 ? "" : "s")"
            case .problems(let errors, let warnings):
                [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
            case .needsInit(let summary): "Needs init (\(summary)): run terraform init in a terminal"
            case .noTerraform: "No terraform found"
            case .failed(let why): why
            }
        }
    }

    let url: URL
    /// Its git top, else the folder itself: the bar's title starts there.
    let checkout: URL
    /// Where `fmt -check` looks for it (`TerraformEditorModel.formatScope`).
    let formatScope: TerraformEditorModel.FormatScope
    @Published private(set) var state = State.idle
    /// How the last Format went, when it didn't format.
    @Published var formatNote: String?
    /// The last validate's diagnostics, by file path.
    private(set) var diagnostics: [String: [TerraformDiagnostic]] = [:]
    /// Files the last validate spoke of: their marks are cleared on the next.
    private(set) var files: Set<String> = []
    private var again = false
    /// The buffers showing its files, and each one's version when the
    /// running validate started: a result is laid only over a buffer that
    /// still holds the text validate read (`describes`).
    private let members = NSHashTable<EditorBuffer>.weakObjects()
    private var versionsAtStart: [ObjectIdentifier: Int] = [:]

    init(url: URL, checkout: URL? = nil, formatScope: TerraformEditorModel.FormatScope? = nil) {
        self.url = url
        self.checkout = checkout ?? url
        self.formatScope = formatScope ?? TerraformEditorModel.FormatScope(folder: url, recursive: false)
    }

    /// A buffer showing one of its files.
    func attach(_ buffer: EditorBuffer) { members.add(buffer) }

    /// Whether the last validate's result describes `buffer`'s text: not
    /// edited since that validate started, nothing unsaved — the file it
    /// read is the text on screen. Else its marks would land on the wrong
    /// lines; the save after the edit validates again.
    func describes(_ buffer: EditorBuffer) -> Bool {
        versionsAtStart[ObjectIdentifier(buffer)] == buffer.version && !buffer.document.isDirty
    }

    var isRunning: Bool { state == .running }

    /// Validates the folder. On save (`manual` false) a folder that needs
    /// init isn't asked again; a run already going runs once more after.
    func validate(manual: Bool) {
        if case .needsInit = state, !manual { return }
        guard state != .running else {
            again = true
            return
        }
        state = .running
        versionsAtStart = Dictionary(members.allObjects.map { (ObjectIdentifier($0), $0.version) }, uniquingKeysWith: { first, _ in first })
        let folder = url
        Task { [weak self] in
            let result = await TerraformEditorModel.run(TerraformCommands.validate, purpose: .validate, in: folder)
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<TerraformRun.Result, TerraformEditorModel.RunFailure>) {
        let before = files
        diagnostics = [:]
        switch result {
        case .failure(.noTerraform): state = .noTerraform
        case .failure(let failure): state = .failed(failure.description)
        case .success(let run):
            // 0 valid, 1 not: either way the JSON says (an exit code decides only that it ran).
            if let validation = try? TerraformValidation.decode(run.stdout, scrub: TerraformValidation.scrub) {
                if validation.needsInit, let first = validation.diagnostics.first(where: TerraformValidation.isInitDiagnostic) {
                    state = .needsInit(first.summary)
                } else {
                    for diagnostic in validation.diagnostics {
                        let path = diagnostic.file.map { url.appendingPathComponent($0).standardizedFileURL.path } ?? ""
                        diagnostics[path, default: []].append(diagnostic)
                    }
                    state = validation.errors == 0 ? .valid(warnings: validation.warnings) : .problems(errors: validation.errors, warnings: validation.warnings)
                }
            } else {
                state = .failed(TerraformEditorModel.firstError(run.stderr).map { "Validate failed: \($0)" } ?? "Validate failed (exit \(run.status))")
            }
        }
        files = Set(diagnostics.keys).subtracting([""])
        // Every file marked before or now hears: the old marks go.
        NotificationCenter.default.post(name: .terraformDiagnostics, object: self, userInfo: ["files": Array(before.union(files))])
        if again {
            again = false
            validate(manual: true)
        }
    }

    /// The last validate's diagnostics of `file`.
    func diagnostics(for file: URL) -> [TerraformDiagnostic] {
        diagnostics[file.standardizedFileURL.path] ?? []
    }
}
