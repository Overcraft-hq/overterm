import Foundation

/// A terraform-family command — `terraform`, `tofu`, `terragrunt` — as a
/// pane's title or a process's argv says it (analysis 3.2, 3.3): what it
/// does (`apply`, `state rm`, `run --all apply`), the folder `-chdir`
/// names, and the `TF_WORKSPACE` or `TF_DATA_DIR` assigned before it. A
/// line read through `ShellCommandLine`, as Kubernetes' and a tab's kind
/// are; never run. Pure.
struct TerraformCommandLine: Equatable, Sendable {
    static let tools: Set<String> = ["terraform", "tofu", "terragrunt"]
    /// What probably runs Terraform when a root is all the files settle (3.2).
    static let probableTools: Set<String> = ["tf", "make", "just", "task", "atlantis"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    var tool: String
    /// `apply`, `plan`, `state rm`, `workspace select`, `run --all apply`; nil: none given.
    var operation: String?
    /// `-chdir=…`'s folder.
    var chdir: String?
    /// `TF_WORKSPACE=…` or `TF_DATA_DIR=…` before the command.
    var workspace: String?
    var dataDir: String?
    /// The var files the run names (`-var-file=prod.tfvars`, `-var-file
    /// prod.tfvars`) and its backend-config files (`-backend-config=
    /// backend/prod.s3.tfbackend`) — a file's path only, never a `-backend-config=key=value`
    /// pair, whose value may be a credential: 5.1's signal 4, by name.
    var varFiles: [String] = []
    var backendConfigFiles: [String] = []
    var autoApprove = false
    /// `make apply`, `./deploy-prod.sh`: not terraform's own word.
    var probably = false

    /// Subcommands whose next word is part of what they do.
    private static let grouped: Set<String> = ["state", "workspace", "providers"]

    /// What changes infrastructure, state or the workspaces (3.3's list).
    var isWrite: Bool {
        guard let operation else { return autoApprove }
        if autoApprove { return true }
        let first = operation.split(separator: " ").first.map(String.init) ?? operation
        if ["apply", "destroy", "import", "taint", "untaint", "force-unlock", "apply-all", "destroy-all"].contains(first) { return true }
        if ["state rm", "state mv", "state push", "state replace-provider", "workspace delete"].contains(operation) { return true }
        if operation.hasPrefix("run --all apply") || operation.hasPrefix("run --all destroy") || operation.hasPrefix("run-all apply")
            || operation.hasPrefix("run-all destroy") || operation == "run apply" || operation == "run destroy"
        {
            return true
        }
        return false
    }

    /// The first terraform-family command of a line, else (`probable`) a
    /// command that probably runs one.
    static func parse(_ line: String, probable: Bool = true) -> TerraformCommandLine? {
        let commands = ShellCommandLine.commands(in: line)
        for command in commands where tools.contains(command.tool) {
            var parsed = make(tool: command.tool, arguments: command.arguments)
            parsed.workspace = command.assigned("TF_WORKSPACE").flatMap { $0.isEmpty ? nil : $0 }
            parsed.dataDir = command.assigned("TF_DATA_DIR").flatMap { $0.isEmpty ? nil : $0 }
            return parsed
        }
        guard probable else { return nil }
        for command in commands where isProbable(command.tool) {
            return TerraformCommandLine(tool: command.tool, operation: command.arguments.first { !$0.hasPrefix("-") }, probably: true)
        }
        return nil
    }

    static func isProbable(_ tool: String) -> Bool {
        probableTools.contains(tool) || (tool.hasPrefix("deploy") && tool.hasSuffix(".sh"))
    }

    /// A process's argv: `terraform apply`, `/opt/homebrew/bin/tofu plan`,
    /// or a script run by its shell (`bash /…/terraform plan`, the
    /// recording wrapper before it `exec`s).
    static func parse(arguments argv: [String]) -> TerraformCommandLine? {
        guard var tool = argv.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        var rest = Array(argv.dropFirst())
        if shells.contains(tool) {
            while let first = rest.first, first.hasPrefix("-") { rest.removeFirst() }
            guard let script = rest.first else { return nil }
            tool = (script as NSString).lastPathComponent
            rest.removeFirst()
        }
        guard tools.contains(tool) else { return nil }
        return make(tool: tool, arguments: rest)
    }

    /// A var file, or a backend-config that names a file: a `key=value`
    /// pair is a setting (perhaps a password), never kept.
    private mutating func addFile(_ flag: String, _ value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.count <= 1024 else { return }
        if flag == "-var-file" {
            varFiles.append(value)
        } else if !value.contains("=") {
            backendConfigFiles.append(value)
        }
    }

    /// Every file the run names, for the class's signals.
    var namedFiles: [String] { varFiles + backendConfigFiles }

    private static func make(tool: String, arguments: [String]) -> TerraformCommandLine {
        var line = TerraformCommandLine(tool: tool)
        var words: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            index += 1
            if word.hasPrefix("-chdir=") {
                line.chdir = String(word.dropFirst("-chdir=".count))
                continue
            }
            // `-var-file X`, `-var-file=X`, `--var-file…`; terragrunt passes them on.
            let flag = word.hasPrefix("--") ? String(word.dropFirst()) : word
            if flag == "-var-file" || flag == "-backend-config" {
                guard index < arguments.endIndex else { continue }
                let value = arguments[index]
                index += 1
                line.addFile(flag, value)
                continue
            }
            if flag.hasPrefix("-var-file=") || flag.hasPrefix("-backend-config=") {
                let separator = flag.firstIndex(of: "=")!
                line.addFile(String(flag[..<separator]), String(flag[flag.index(after: separator)...]))
                continue
            }
            if word == "-auto-approve" || word == "--auto-approve" || word.hasPrefix("-auto-approve=") && word != "-auto-approve=false" {
                line.autoApprove = true
            }
            words.append(word)
        }
        let plain = words.filter { !$0.hasPrefix("-") }
        guard let first = plain.first else { return line }
        if tool == "terragrunt" {
            switch first {
            case "run":
                let all = words.contains("--all") || words.contains("-a")
                let sub = plain.dropFirst().first
                line.operation = (all ? "run --all" : "run") + (sub.map { " " + $0 } ?? "")
            case "run-all":
                line.operation = "run-all" + (plain.dropFirst().first.map { " " + $0 } ?? "")
            default:
                line.operation = first
            }
            return line
        }
        if grouped.contains(first), let second = plain.dropFirst().first {
            line.operation = "\(first) \(second)"
        } else {
            line.operation = first
        }
        return line
    }
}
