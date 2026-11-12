import Foundation

/// Every terraform command line Overterm builds (analysis 4.3), and the
/// forms it can never express (5.13 rule 1). Pure. Stage 1a has only the
/// editor's: format and validate, which change no state and take no lock;
/// stage 1b `version -json`, the version pill's; stage 1c the agents'
/// reads — `fmt -check -diff`, and `show -json` of a saved plan by its
/// descriptor; stage 1d Overterm's plan (`plan`, with its fixed flags),
/// `init` (`-lockfile=readonly`, never `-upgrade`), and the workspace
/// chip's `workspace list` and `workspace select`; stage 2a the apply —
/// one line, of a plan Overterm holds by its descriptor — and the plan's
/// modes: destroy, only some addresses (`-target`), some replaced.
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

    /// `tf_fmt_check` (analysis 5.10, stage 1c): whether a root's files
    /// pass `fmt`, and the diff that would make them — exit 0 or 3. With
    /// `-check`, `fmt` writes nothing; one folder, not below it.
    static let formatCheckDiff = ["fmt", "-check", "-diff", "-no-color"]

    /// A saved plan as JSON, read from the descriptor the run is handed as
    /// fd 3 (4.4, spike 18): `tf_plan_summary` over a plan an agent saved
    /// itself. Never `show` of a state (no file: it prints every secret in
    /// it), never a path terraform would open after the check — the file
    /// is opened, checked and handed over by Overterm. Starts the
    /// providers for their schemas, so its environment has no credential
    /// (`TerraformEnvironment.Purpose.agentRead`).
    static let showPlanDescriptor = ["show", "-json", "-no-color", "/dev/fd/3"]

    /// Init, the person's click (4.13): the lock file read, never
    /// rewritten (`-lockfile=readonly`); no `-upgrade`, `-reconfigure`,
    /// `-migrate-state`, `-force-copy`, ever. JSON (1.9+).
    static let initialize = ["init", "-input=false", "-json", "-lockfile=readonly"]

    /// The workspaces a backend has (4.9): the chip's list, and the check
    /// every run makes before it starts. Run with `TF_WORKSPACE` removed.
    static let workspaceList = ["workspace", "list"]

    /// The chip's Select (4.9): writes the checkout's
    /// `.terraform/environment`. Never `-or-create`: an unknown name is
    /// refused by terraform. Run with `TF_WORKSPACE` removed. Nil for a
    /// name that isn't a workspace's.
    static func workspaceSelect(_ name: String) -> [String]? {
        isWorkspaceName(name) ? ["workspace", "select", name] : nil
    }

    /// A workspace's name as Terraform allows it: letters, digits, `-`,
    /// `_`, `.`, at most 90, never a flag.
    static func isWorkspaceName(_ name: String) -> Bool {
        guard (1...90).contains(name.count), !name.hasPrefix("-"), name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    /// How long a plan waits for the state's lock (4.10, D-6): a person's
    /// 10 s, an agent's 0 s (a held lock is reported, never queued behind
    /// CI), "Wait for it" 5 min. `-lock=false` is never built.
    enum LockWait: String, Sendable, CaseIterable {
        case person = "10s"
        case agent = "0s"
        case wait = "5m"
    }

    /// The fixed head of every plan (4.3).
    static let planHead = ["plan", "-input=false", "-json", "-detailed-exitcode", "-lock=true"]

    /// The only apply (4.3, 5.13 rule 1): of the plan Overterm holds, handed
    /// to the run as fd 3 — never a path, never without a plan, never
    /// `-auto-approve` (a saved plan asks nothing), never `-target` or
    /// `-var` (the plan decided), the lock taken for at most 60 s.
    static let apply = ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "/dev/fd/3"]

    /// The most addresses a targeted or replacing plan names.
    static let maxAddresses = 50

    /// Overterm's plan (4.3): cwd the root; `out` the plan file in the
    /// run's own folder (`TerraformRunFolder`); `mode` its flags (2a:
    /// destroy, targets, replaces — addresses only, `isAddress`);
    /// `varFiles` relative to the root, inside it; `parallelism` 1…256.
    /// Nil when an argument is none of those. `planArgs` is never free
    /// text (4.3).
    static func plan(
        out: String, varFiles: [String] = [], lock: LockWait = .person, parallelism: Int? = nil, mode: TerraformPlanMode = .normal
    ) -> [String]? {
        guard isPlanFile(out), varFiles.allSatisfy(isVarFile), parallelism.map({ (1...256).contains($0) }) ?? true, let flags = mode.flags else {
            return nil
        }
        var arguments = planHead + ["-lock-timeout=" + lock.rawValue, "-out=" + out]
        arguments += flags
        arguments += varFiles.map { "-var-file=" + $0 }
        if let parallelism { arguments.append("-parallelism=\(parallelism)") }
        return arguments
    }

    /// A resource address a plan may name (`-target=`, `-replace=`):
    /// `module.acme["eu"].aws_instance.web["a b"]` — one argument, never a
    /// flag, no control or invisible character (a `for_each` key may hold
    /// bidi or zero-width ones), at most 512 characters, a `.` in it.
    static func isAddress(_ address: String) -> Bool {
        guard (3...512).contains(address.count), !address.hasPrefix("-"), address.contains("."), !address.hasPrefix("."), !address.hasSuffix(".")
        else { return false }
        let refused: Set<Unicode.GeneralCategory> = [.control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator]
        return address.unicodeScalars.allSatisfy { scalar in
            !refused.contains(scalar.properties.generalCategory) && (scalar == " " || !scalar.properties.isWhitespace)
        }
    }

    /// A plan's file: `<…>/ot-tf-<uid>-<pid>/<run>/plan`, an absolute path
    /// in a run folder of Overterm's (4.4), nothing that walks out.
    static func isPlanFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.hasPrefix("/"), parts.last == "plan", parts.count >= 4, !parts.contains(".."), !parts.contains("."),
            parts[parts.count - 3].hasPrefix(TerraformRunFolder.prefix), !path.contains("\u{0}")
        else { return false }
        return true
    }

    /// A var file a plan may name: relative to the root and inside it, a
    /// `.tfvars` or `.tfvars.json` (4.3: "var files inside the root").
    static func isVarFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.hasPrefix("-"), !parts.contains(".."), !parts.contains(""),
            !path.contains("\u{0}"), path.count <= 512
        else { return false }
        return path.hasSuffix(".tfvars") || path.hasSuffix(".tfvars.json")
    }

    /// Whether `arguments` is a plan `plan(…)` builds.
    static func isPlan(_ arguments: [String]) -> Bool {
        guard arguments.count >= planHead.count + 2, Array(arguments.prefix(planHead.count)) == planHead else { return false }
        let timeout = arguments[planHead.count]
        guard let wait = LockWait.allCases.first(where: { "-lock-timeout=" + $0.rawValue == timeout }) else { return false }
        let out = arguments[planHead.count + 1]
        guard out.hasPrefix("-out=") else { return false }
        var varFiles: [String] = []
        var parallelism: Int?
        var destroy = false
        var targets: [String] = []
        var replaces: [String] = []
        for (index, argument) in arguments.dropFirst(planHead.count + 2).enumerated() {
            if argument == "-destroy", varFiles.isEmpty, parallelism == nil {
                destroy = true
            } else if argument.hasPrefix("-target="), varFiles.isEmpty, parallelism == nil {
                targets.append(String(argument.dropFirst("-target=".count)))
            } else if argument.hasPrefix("-replace="), varFiles.isEmpty, parallelism == nil {
                replaces.append(String(argument.dropFirst("-replace=".count)))
            } else if argument.hasPrefix("-var-file="), parallelism == nil {
                varFiles.append(String(argument.dropFirst("-var-file=".count)))
            } else if argument.hasPrefix("-parallelism="), index == arguments.count - planHead.count - 3,
                let count = Int(argument.dropFirst("-parallelism=".count))
            {
                parallelism = count
            } else {
                return false
            }
        }
        let modes = [destroy, !targets.isEmpty, !replaces.isEmpty].filter { $0 }.count
        guard modes <= 1 else { return false }
        let mode: TerraformPlanMode = destroy ? .destroy : !targets.isEmpty ? .targets(targets) : !replaces.isEmpty ? .replace(replaces) : .normal
        return plan(out: String(out.dropFirst("-out=".count)), varFiles: varFiles, lock: wait, parallelism: parallelism, mode: mode) == arguments
    }

    /// Everything this file builds, as fixed lines (a plan's and a
    /// workspace select's are checked by `isBuilt`).
    static let all: [[String]] = [
        formatStandardInput, formatCheck, formatCheckFolder, formatCheckDiff, validate, version, showPlanDescriptor, initialize, workspaceList, apply,
    ]

    /// Whether a builder of this file made `arguments`.
    static func isBuilt(_ arguments: [String]) -> Bool {
        if all.contains(arguments) || isPlan(arguments) { return true }
        if arguments.count == 3, arguments[0] == "workspace", arguments[1] == "select" { return workspaceSelect(arguments[2]) == arguments }
        return false
    }

    /// Subcommands never run: the ones that change state or
    /// infrastructure without a shown plan, and the reads that print
    /// secrets, which later stages build with their own guards. `apply`,
    /// `show`, `plan`, `init` and `workspace` run only as this file builds
    /// them, whole: any other line is no builder's — an apply only of
    /// `/dev/fd/3`, exactly `apply`.
    static let refusedSubcommands: Set<String> = [
        "destroy", "import", "taint", "untaint", "force-unlock", "refresh", "state", "login", "logout", "test", "console", "get",
        "providers", "output",
    ]

    /// Flags never built, for anything (4.3).
    static let forbiddenFlags = ["-auto-approve", "-lock=false", "-refresh=false", "-minimal-refresh", "-upgrade", "-reconfigure", "-migrate-state", "-force-copy", "-backup", "-var="]

    /// Why `arguments` may not run, or nil. `TerraformRun` asks before it
    /// starts anything: a line no builder made is refused there too.
    static func refusal(_ arguments: [String]) -> String? {
        guard let subcommand = arguments.first(where: { !$0.hasPrefix("-") }) else { return "no subcommand" }
        if arguments.contains(where: { $0.hasPrefix("-chdir") }) { return "-chdir is never passed: the run's folder is its root" }
        if refusedSubcommands.contains(subcommand) { return "terraform \(subcommand) is not run by Overterm" }
        for argument in arguments {
            let forbidden = forbiddenFlags.first { flag in
                flag.hasSuffix("=") ? argument.hasPrefix(flag) : argument == flag || argument.hasPrefix(flag + "=")
            }
            if let flag = forbidden {
                return "\(flag) is never passed"
            }
            if argument == "-var" { return "-var is never passed" }
        }
        guard isBuilt(arguments) else { return "not a command Overterm builds" }
        return nil
    }
}

/// What a plan is asked for (2.2, stage 2a): the root's whole change; a
/// destroy of everything in it; only some addresses (`-target`, labelled
/// partial — break-glass, refused on production at apply); some objects
/// replaced though unchanged. Addresses only, checked; nothing else is
/// ever passed.
enum TerraformPlanMode: Equatable, Hashable, Sendable {
    case normal
    case destroy
    case targets([String])
    case replace([String])

    /// Its flags, or nil when an address isn't one.
    var flags: [String]? {
        switch self {
        case .normal: return []
        case .destroy: return ["-destroy"]
        case .targets(let addresses), .replace(let addresses):
            guard !addresses.isEmpty, addresses.count <= TerraformCommands.maxAddresses, addresses.allSatisfy(TerraformCommands.isAddress),
                Set(addresses).count == addresses.count
            else { return nil }
            var flag = "-replace="
            if case .targets = self { flag = "-target=" }
            return addresses.map { flag + $0 }
        }
    }

    /// How the header says it: nil for a whole plan.
    var label: String? {
        switch self {
        case .normal: nil
        case .destroy: "destroy"
        case .targets(let addresses): "partial: only \(addresses.count == 1 ? addresses[0] : "\(addresses.count) addresses")"
        case .replace(let addresses): "replacing \(addresses.count == 1 ? addresses[0] : "\(addresses.count) addresses")"
        }
    }

    var isDestroy: Bool { self == .destroy }
}
