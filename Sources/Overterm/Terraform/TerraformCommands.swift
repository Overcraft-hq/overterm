import Foundation

/// Every terraform command line Overterm builds (analysis 4.3), and the
/// forms it can never express (5.13 rule 1). Pure. Stage 1a has only the
/// editor's: format and validate, which change no state and take no lock;
/// stage 1b `version -json`, the version pill's.
///
/// Every run's cwd is the root (or the checkout for `formatCheck`), never
/// `-chdir`, so a diagnostic's `range.filename` is relative to it.
enum TerraformCommands {
    /// `terraform fmt -` over the buffer: the formatted text on stdout, a
    /// syntax error on stderr with exit 2. Writes no file.
    static let formatStandardInput = ["fmt", "-no-color", "-"]
    /// Whether a checkout already passes `fmt` (format on save is on only
    /// where it does, 4.14): exit 0 when it does, 3 listing the files when
    /// not. Writes no file; hidden folders (`.terraform`) are skipped.
    static let formatCheck = ["fmt", "-check", "-list=true", "-recursive", "-no-color"]
    /// The same over one folder, not below it: where the checkout is no
    /// git top, or one too wide to walk (`/`, a volume, the home folder —
    /// `TerraformEditorModel.formatScope`).
    static let formatCheckFolder = ["fmt", "-check", "-list=true", "-no-color"]
    /// Diagnostics as JSON. Starts the providers (so its environment has no
    /// credential, `TerraformEnvironment.validate`); writes no file and
    /// takes no lock. Never an `init` before it here.
    static let validate = ["validate", "-json", "-no-color"]

    /// The binary's version, as JSON (4.2): the version pill's, once per
    /// binary and root. Run with `CHECKPOINT_DISABLE=1` (its
    /// `terraform_outdated` is a call home), no credential; reads no state.
    static let version = ["version", "-json"]

    /// Everything this file builds.
    static let all: [[String]] = [formatStandardInput, formatCheck, formatCheckFolder, validate, version]

    /// Subcommands the editor never runs: the ones that change state,
    /// infrastructure, the checkout's providers or its workspaces (the
    /// writes that come later go only through a shown plan), and the reads
    /// that print secrets or run the configuration, which later stages
    /// build with their own guards.
    static let refusedSubcommands: Set<String> = [
        "apply", "destroy", "import", "taint", "untaint", "force-unlock", "init", "refresh", "state", "workspace", "login", "logout", "test",
        "console", "plan", "get", "providers", "output", "show",
    ]

    /// Flags never built, for anything (4.3).
    static let forbiddenFlags = ["-auto-approve", "-lock=false", "-refresh=false", "-minimal-refresh", "-upgrade", "-reconfigure", "-migrate-state", "-force-copy", "-backup", "-var="]

    /// Why `arguments` may not run, or nil. `TerraformRun` asks before it
    /// starts anything: a line no builder made is refused there too.
    static func refusal(_ arguments: [String]) -> String? {
        guard let subcommand = arguments.first(where: { !$0.hasPrefix("-") }) else { return "no subcommand" }
        if arguments.contains(where: { $0.hasPrefix("-chdir") }) { return "-chdir is never passed: the run's folder is its root" }
        if refusedSubcommands.contains(subcommand) { return "terraform \(subcommand) is not run by Overterm's editor" }
        for argument in arguments {
            let forbidden = forbiddenFlags.first { flag in
                flag.hasSuffix("=") ? argument.hasPrefix(flag) : argument == flag || argument.hasPrefix(flag + "=")
            }
            if let flag = forbidden {
                return "\(flag) is never passed"
            }
            if argument == "-var" { return "-var is never passed" }
        }
        guard all.contains(arguments) else { return "not a command Overterm builds" }
        return nil
    }
}
