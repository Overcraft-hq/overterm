import Foundation

/// A pane's screen asking for a Terraform write (analysis 3.3), in one of
/// two shapes:
/// - an agent's permission prompt — Claude Code's "Bash command … Do you
///   want to proceed?", Codex's "Would you like to run the following
///   command?" — whose command parses (`TerraformCommandLine`) as `apply`,
///   `destroy`, `state rm|mv|push`, `force-unlock`, `import`, `taint`,
///   `workspace delete`, or carries `-auto-approve`;
/// - Terraform's own prompt in a pane where it has the tty — "Do you want
///   to perform these actions in workspace "acme-prod"? … Enter a value:",
///   "Do you really want to destroy all resources?".
///
/// Either marks the tab, and the Inbox shows it — never with a button
/// that answers: nothing in Overterm ever types a reply to a
/// `TerraformPrompt` (`TerminalWindowController.answer` refuses one).
/// Read off the screen's last lines; never run. Pure.
struct TerraformPrompt: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// An agent asks to run `command` (one line, as its prompt shows it).
        case agent(command: String)
        /// Terraform itself asks `question` (its own words), in `workspace` when it says one.
        case terraform(question: String, workspace: String?)
    }

    var shape: Shape
    /// The write it asks for, as `TerraformCommandLine` reads it; for
    /// Terraform's own prompt, what its words say (`apply`, `destroy`).
    var line: TerraformCommandLine

    var command: String? { if case .agent(let command) = shape { command } else { nil } }
    var isAgents: Bool { command != nil }
    var operation: String { line.tool + (line.operation.map { " " + $0 } ?? "") + (line.autoApprove && line.operation != nil ? " -auto-approve" : "") }

    /// How many of the screen's last lines are read: a prompt is the newest thing there.
    static let window = 40

    /// The questions an agent's permission prompt asks, in their words.
    static let agentQuestions = [
        "Do you want to proceed?", "Would you like to run the following command?", "Allow command?", "Do you want to allow", "Run this command?",
        "Approve this command?",
    ]

    /// Terraform's (and OpenTofu's) own confirmations, and what each asks to do.
    static let terraformQuestions: [(prefix: String, operation: String)] = [
        ("Do you want to perform these actions", "apply"),
        ("Do you really want to destroy all resources", "destroy"),
        ("Do you really want to force-unlock?", "force-unlock"),
        ("Do you want to migrate all workspaces to", "init -migrate-state"),
        ("Do you want to copy existing state to the new backend?", "init -migrate-state"),
        ("Do you really want to delete workspace", "workspace delete"),
    ]

    /// The prompt at the end of `screen`, if it asks for a Terraform write.
    static func parse(_ screen: String) -> TerraformPrompt? {
        let all = screen.components(separatedBy: "\n").map(clean)
        var lines = Array(all.suffix(window))
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        if let own = terraformOwn(lines) { return own }
        return agents(lines)
    }

    /// Terraform waits at its `Enter a value:` — a variable's value, perhaps a secret (5.6 rule 6).
    static func asksForValue(_ screen: String) -> Bool {
        screen.components(separatedBy: "\n").map(clean).last(where: { !$0.isEmpty })?.hasPrefix("Enter a value:") == true
    }

    /// Box borders and the agents' markers off a line, its spaces trimmed.
    static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\u{00a0}", with: " ")
        let borders = CharacterSet(charactersIn: "│┃║╭╮╰╯─━═┌┐└┘|")
        text = text.trimmingCharacters(in: borders.union(.whitespaces))
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Terraform's own: the last line is its `Enter a value:` and one of
    /// its questions is just above.
    private static func terraformOwn(_ lines: [String]) -> TerraformPrompt? {
        guard let last = lines.last, last.hasPrefix("Enter a value:") else { return nil }
        for line in lines.suffix(8).reversed() {
            guard let known = terraformQuestions.first(where: { line.hasPrefix($0.prefix) }) else { continue }
            let workspace = quoted(after: "in workspace", in: line)
            var parsed = TerraformCommandLine(tool: line.contains("OpenTofu") ? "tofu" : "terraform")
            parsed.operation = known.operation == "init -migrate-state" ? "init" : known.operation
            parsed.workspace = workspace
            return TerraformPrompt(shape: .terraform(question: TerraformPlanText.cut(line, to: 200), workspace: workspace), line: parsed)
        }
        return nil
    }

    /// An agent's: one of its questions, choices under it (Claude Code's
    /// numbers, Codex's), and a Terraform write in its command block —
    /// Codex's between the question and the choices (from its `$ ` line),
    /// Claude Code's under its "Bash command" header, else the run of
    /// lines just above the question. A block's lines are joined: a long
    /// command wraps inside the box (`cd …/envs/prod && terraform` over
    /// `apply -auto-approve`), more so in a narrow split. Nothing above the
    /// block is read: a `terraform apply` said earlier in the chat is not
    /// the ask for an `ls`.
    private static func agents(_ lines: [String]) -> TerraformPrompt? {
        guard let question = lines.lastIndex(where: { line in agentQuestions.contains { line.hasPrefix($0) || line.contains($0) } }) else { return nil }
        // Choices below it: the prompt is open, not scrolled-by output.
        let below = lines[(question + 1)...]
        guard let firstChoice = below.firstIndex(where: isChoice), let lastChoice = below.lastIndex(where: isChoice) else { return nil }
        // The choices are the newest thing on screen (a hint line at most
        // under them): one scrolled up under a shell's prompt is answered.
        guard lines[(lastChoice + 1)...].filter({ !$0.isEmpty }).count <= 1 else { return nil }
        for block in commandBlocks(lines, question: question, firstChoice: firstChoice) {
            guard let (command, line) = writeCommand(inBlock: block) else { continue }
            return TerraformPrompt(shape: .agent(command: TerraformPlanText.cut(masked(command), to: 300)), line: line)
        }
        return nil
    }

    /// The candidate command blocks of a prompt, each its run of lines.
    static func commandBlocks(_ lines: [String], question: Int, firstChoice: Int) -> [[String]] {
        var blocks: [[String]] = []
        // Codex: between the question and the choices, from its `$ ` line.
        for run in runs(Array(lines[(question + 1)..<firstChoice])) {
            if let dollar = run.firstIndex(where: { $0.hasPrefix("$ ") }) { blocks.append(Array(run[dollar...])) } else { blocks.append(run) }
        }
        // Claude Code: its header, then the command and its description.
        let floor = max(0, question - 40)
        if let header = lines[floor..<question].lastIndex(where: { $0.hasPrefix("Bash command") }) {
            if let run = runs(Array(lines[(header + 1)..<question])).first { blocks.append(run) }
        } else {
            // No header: the run just above the question, and no further.
            var end = question
            while end > floor, lines[end - 1].isEmpty { end -= 1 }
            var start = end
            while start > floor, !lines[start - 1].isEmpty, start > end - 12 { start -= 1 }
            if start < end { blocks.append(Array(lines[start..<end])) }
        }
        return blocks
    }

    /// Runs of non-empty lines.
    private static func runs(_ lines: [String]) -> [[String]] {
        var found: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { found.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { found.append(current) }
        return found
    }

    /// The block's first lines that, joined, run a Terraform write: one
    /// line, then two, … — so a wrapped command is read whole and the
    /// description under it, when the command already parses, is not.
    /// A trailing `\` is a continuation; a word cut by the wrap is tried
    /// joined without a space too.
    static func writeCommand(inBlock block: [String]) -> (String, TerraformCommandLine)? {
        var words = block.map { line -> String in
            var text = line
            if text.hasPrefix("$ ") { text.removeFirst(2) }
            if text.hasSuffix("\\") { text.removeLast() }
            return text.trimmingCharacters(in: .whitespaces)
        }
        words = Array(words.prefix(12))
        guard !words.isEmpty else { return nil }
        for count in 1...words.count {
            let part = words.prefix(count)
            let joins = count == 1 ? [part.joined()] : [part.joined(separator: " "), part.joined()]
            let found = joins.compactMap { joined in writeCommand(in: joined).map { (joined, $0) } }
            // A wrap between words, or inside one (`terraform a` / `pply`):
            // the reading whose operation is one Terraform has.
            if let known = found.first(where: { isKnown($0.1) }) ?? found.first { return known }
        }
        return nil
    }

    /// The words Terraform, OpenTofu and Terragrunt take as a command.
    static let subcommands: Set<String> = [
        "apply", "destroy", "import", "taint", "untaint", "force-unlock", "state", "workspace", "refresh", "test", "init", "plan", "show", "output",
        "validate", "fmt", "console", "providers", "get", "graph", "login", "logout", "metadata", "modules", "version", "query", "run", "run-all",
        "run --all", "apply-all", "destroy-all", "stack",
    ]

    private static func isKnown(_ line: TerraformCommandLine) -> Bool {
        guard let operation = line.operation else { return false }
        if subcommands.contains(operation) { return true }
        return subcommands.contains(String(operation.split(separator: " ").first ?? ""))
            || (operation.hasPrefix("run --all") && subcommands.contains(String(operation.split(separator: " ").dropFirst(2).first ?? "")))
    }

    /// `❯ 1. Yes`, `› 1. Yes, proceed (y)`, `2. No…`.
    static func isChoice(_ line: String) -> Bool {
        var text = Substring(line)
        while let first = text.first, "❯›>*".contains(first) || first == " " { text = text.dropFirst() }
        guard let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty else { return false }
        return text[text.index(after: dot)...].hasPrefix(" ")
    }

    /// The first terraform-family command of `text` that writes (3.3's list).
    static func writeCommand(in text: String) -> TerraformCommandLine? {
        TerraformCommandLine.all(in: text).first(where: \.isWrite)
    }

    /// The command as the Inbox and the header may show it (5.6): every
    /// `-var` value masked, whatever its name, then `Secrets`' flags and
    /// assignments (`TF_VAR_admin_password=…`, `--token …`) and text rules.
    static func masked(_ command: String) -> String {
        let string = command as NSString
        guard let pattern = try? NSRegularExpression(pattern: #"\S+"#) else { return TerraformValidation.scrub(command) }
        let matches = pattern.matches(in: command, range: NSRange(location: 0, length: string.length))
        var words = matches.map { string.substring(with: $0.range) }
        func maskVariable(_ value: String) -> String {
            let quote = value.first.map { "'\"".contains($0) ? String($0) : "" } ?? ""
            let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard let equals = bare.firstIndex(of: "=") else { return quote + Secrets.credentialMask + quote }
            let name = String(bare[...equals])
            return quote + name + Secrets.credentialMask + quote
        }
        var afterVar = false
        for index in words.indices {
            let word = words[index]
            if afterVar {
                words[index] = maskVariable(word)
                afterVar = false
            } else if word == "-var" || word == "--var" {
                afterVar = true
            } else if word.hasPrefix("-var=") || word.hasPrefix("--var=") {
                let equals = word.firstIndex(of: "=")!
                words[index] = String(word[...equals]) + maskVariable(String(word[word.index(after: equals)...]))
            }
        }
        words = Secrets.maskArguments(words)
        var out = command as NSString
        for (match, word) in zip(matches, words).reversed() { out = out.replacingCharacters(in: match.range, with: word) as NSString }
        return TerraformValidation.scrub(out as String)
    }

    /// The `"…"` after `marker` in `line`.
    static func quoted(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...]
        guard let open = rest.firstIndex(where: { $0 == "\"" || $0 == "“" }) else { return nil }
        let after = rest[rest.index(after: open)...]
        guard let close = after.firstIndex(where: { $0 == "\"" || $0 == "”" }) else { return nil }
        let name = String(after[..<close])
        return name.isEmpty || name.count > 90 ? nil : name
    }

    /// The folder an agent's command runs terraform in: `base` (where the
    /// agent works), then a `cd` before it on the line, then `-chdir`. Nil
    /// for an absolute or `~` path it can't settle. Pure.
    static func folder(of command: String, line: TerraformCommandLine, base: URL) -> URL {
        var folder = base
        for part in ShellCommandLine.commands(in: command) {
            if part.tool == "cd", let target = part.arguments.first, !target.hasPrefix("~"), !target.hasPrefix("-") {
                folder = target.hasPrefix("/") ? URL(fileURLWithPath: target, isDirectory: true) : folder.appendingPathComponent(target, isDirectory: true)
            }
            if TerraformCommandLine.tools.contains(part.tool) { break }
        }
        if let chdir = line.chdir, !chdir.isEmpty {
            folder = chdir.hasPrefix("/") ? URL(fileURLWithPath: chdir, isDirectory: true) : folder.appendingPathComponent(chdir, isDirectory: true)
        }
        return folder.standardizedFileURL
    }
}

/// A pane's Terraform ask (3.3): the prompt, and the root, workspace and
/// class it would touch, as the pane header says them — what its tab's
/// mark and the Inbox's card say.
struct TerraformAsk: Equatable, Sendable {
    var prompt: TerraformPrompt
    /// The root it runs in, its class; nil when the command's folder holds no configuration.
    var warning: TerraformPaneWarning?

    var isProduction: Bool { warning?.isProduction == true }

    /// "asks to run terraform apply in envs/prod · workspace prod · PRODUCTION".
    var summary: String {
        let verb = prompt.isAgents ? "asks to run" : "terraform asks to"
        var text = prompt.isAgents ? "\(verb) \(prompt.operation)" : "\(verb) \(prompt.line.operation ?? "write")"
        if let warning {
            text += " in \(warning.root) · workspace \(warning.workspace)"
            text += " · " + warning.rootClass.title.uppercased()
        } else if let workspace = prompt.line.workspace {
            text += " · workspace \(workspace)"
        }
        return text
    }

    /// The lines the Inbox's card shows: the command, the root's backend.
    var preview: [String] {
        var lines: [String] = []
        switch prompt.shape {
        case .agent(let command): lines.append("$ " + command)
        case .terraform(let question, _): lines.append(question)
        }
        if let warning { lines.append(warning.label) }
        lines.append("Overterm never answers this: read it in the tab, and answer there yourself.")
        return lines
    }
}

extension TerraformCommandLine {
    /// What prints a value Terraform marks sensitive, or an output's, in
    /// clear (5.6 rule 6): a pane that ran one keeps no scrollback.
    var printsSecrets: Bool {
        guard let operation else { return false }
        return ["output", "show", "console", "state show", "state pull", "run output", "run show"].contains(operation)
            || operation.hasPrefix("run --all output") || operation.hasPrefix("run --all show")
    }
}
