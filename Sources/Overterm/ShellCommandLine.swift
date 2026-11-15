import Foundation

/// A command line read as zsh splits it, never run: its words, its
/// commands (split at `|`, `&&`, `;`…), and in each the command behind
/// reserved words (`if`, `then`, `{`, `!`…), assignments and wrappers
/// (`sudo`, `env`, `time`, `watch`, `timeout`, `aws-vault exec`, `op run`,
/// `doppler run`, `mise exec`, `direnv exec`…) — and inside the strings a
/// shell runs (`bash -c '…'`, `env -S '…'`, `doppler run --command '…'`):
/// `aws-vault exec acme-prod -- terraform apply` is an apply. What a pane
/// runs is only known by its title (`CommandLedger`) and a process's argv;
/// Kubernetes' pane header (`KubeCommandLine`), a tab's kind (`TabKind`)
/// and Terraform's (`TerraformCommandLine`) read it through this one
/// splitter, so they agree on what a line says. Pure.
enum ShellCommandLine {
    /// A `NAME=value` before the command (`KUBECONFIG=/tmp/a kubectl …`,
    /// `env TF_WORKSPACE=prod terraform …`).
    struct Assignment: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// One command of a line.
    struct Command: Equatable, Sendable {
        /// The assignments before it, in order: before the wrappers and
        /// between them (`env -u FOO TF_WORKSPACE=prod terraform`).
        var assignments: [Assignment]
        /// The wrappers it runs behind, outermost first (`sudo`, `env`).
        var wrappers: [String]
        /// The command's word as written: `/opt/homebrew/bin/terraform`.
        var executable: String
        /// Its last path component: `terraform`.
        var tool: String
        /// The words after it.
        var arguments: [String]

        /// What the line assigns `name`, the last assignment's (the one
        /// the command sees).
        func assigned(_ name: String) -> String? {
            assignments.last { $0.name == name }?.value
        }
    }

    /// How a wrapper reads the words between it and the command it runs.
    struct Wrapper: Equatable, Sendable {
        /// Options that take the next word as their value (`sudo -u root`,
        /// `watch -n 2`): that word is the option's, not the command.
        var valued: Set<String> = []
        /// The subcommand that makes it a wrapper (`aws-vault exec`, `op
        /// run`); any other (`op read`, `mise install`), and the wrapper's
        /// word is itself the command.
        var subcommands: Set<String> = []
        /// Words of its own before the command: `timeout 600`, `aws-vault
        /// exec acme-prod`, `direnv exec .`; `.max` until `--` (`mise exec
        /// terraform@1.9 -- terraform`).
        var positionals = 0
        /// Options whose value is a command line a shell runs (`doppler run
        /// --command '…'`, `mise exec -c '…'`): read as a line of its own.
        var lines: Set<String> = []
        /// Options whose value is split into words that take its place
        /// (`env -S 'terraform apply'`).
        var splits: Set<String> = []
        /// Runs the rest through `sh -c`, joined by spaces (`watch`): one
        /// quoted word (`watch 'terraform plan'`) is a line of its own.
        var viaShell = false
    }

    /// The wrappers a command is looked for behind.
    static let wrappers: [String: Wrapper] = [
        "sudo": Wrapper(valued: [
            "-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "-R", "--user", "--group", "--close-from", "--chdir", "--host", "--prompt",
            "--role", "--type", "--other-user", "--command-timeout", "--chroot",
        ]),
        "doas": Wrapper(valued: ["-u", "-C"]),
        "env": Wrapper(valued: ["-u", "-C", "-P", "--unset", "--chdir"], splits: ["-S", "--split-string"]),
        "watch": Wrapper(valued: ["-n", "--interval", "-q", "--equexit"], viaShell: true),
        "time": Wrapper(valued: ["-f", "-o", "--format", "--output"]),
        "caffeinate": Wrapper(valued: ["-t", "-w"]),
        "exec": Wrapper(valued: ["-a"]),
        "nice": Wrapper(valued: ["-n", "--adjustment"]),
        "timeout": Wrapper(valued: ["-s", "--signal", "-k", "--kill-after"], positionals: 1),
        "xargs": Wrapper(valued: [
            "-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S", "--max-args", "--max-procs", "--delimiter", "--arg-file",
            "--max-lines", "--replace", "--eof", "--max-chars",
        ]),
        "aws-vault": Wrapper(
            valued: ["-d", "--duration", "-t", "--mfa-token", "--region", "--prompt", "--backend", "--keychain", "--config"],
            subcommands: ["exec"], positionals: 1),
        "op": Wrapper(valued: ["--env-file", "--account", "--cache", "--config", "--encoding", "--session"], subcommands: ["run"]),
        "doppler": Wrapper(
            valued: ["-p", "--project", "-c", "--config", "--token", "--scope", "--configuration", "--mount", "--fallback", "--name-transformer"],
            subcommands: ["run"], lines: ["--command"]),
        "mise": Wrapper(valued: ["-j", "--jobs", "-C", "--cd", "-E", "--env"], subcommands: ["exec", "x"], positionals: .max, lines: ["-c", "--command"]),
        "asdf": Wrapper(subcommands: ["exec"]),
        "direnv": Wrapper(subcommands: ["exec"], positionals: 1),
        "command": Wrapper(), "nohup": Wrapper(), "noglob": Wrapper(), "nocorrect": Wrapper(), "builtin": Wrapper(),
    ]

    /// The shells whose `-c` string is read as a line of its own (`bash -c
    /// 'terraform apply'`, `zsh -lc …`); without `-c` the shell is the command.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// Reserved words before a command (`if terraform plan; then terraform
    /// apply; fi`, `{ terraform apply; }`, `! terraform …`): skipped.
    static let leadingReservedWords: Set<String> = ["if", "then", "elif", "else", "do", "while", "until", "{", "!", "coproc"]
    /// Reserved words that begin a segment with no command in it: a
    /// closer (`fi`, `done`), or a header whose words aren't one (`for x in
    /// a b`, `case $x in`, `[[ … ]]`).
    static let commandlessReservedWords: Set<String> = ["fi", "done", "esac", "}", "for", "case", "select", "function", "[[", "]]"]

    /// The line's words, as the shell splits them: `'…'` (and the `'\''`
    /// that puts a quote in one), `"…"` and `\ ` keep a space in a word,
    /// their quotes taken off; `''` is an empty word. Unclosed, the rest
    /// is the word. Operators (`|`, `&&`, `;`) are words here too: for a
    /// line's commands, `segments(of:)`.
    static func words(_ line: String) -> [String] {
        tokens(line, splitting: false).flatMap { $0 }
    }

    /// The line's commands, each its words: split at `|`, `||`, `&&`, `;`,
    /// `&`, parentheses and newlines outside quotes; quotes and
    /// backslashes read as `words` reads them.
    static func segments(of line: String) -> [[String]] {
        tokens(line, splitting: true)
    }

    /// Every command of the line that has one, in order — a `bash -c`
    /// string's, `env -S`'s, `doppler run --command`'s among them.
    static func commands(in line: String) -> [Command] {
        commands(inLine: line, depth: 0)
    }

    /// The (first) command of one segment's words: past reserved words,
    /// the assignments, the wrappers and the wrappers' own options. Nil
    /// when there is none (only assignments, a wrapper with nothing after
    /// it, a `for` header).
    static func command(in words: [String]) -> Command? {
        commands(of: words, depth: 0).first
    }

    /// How deep strings inside strings are read (`bash -c "env -S '…'"`).
    private static let maximumDepth = 4

    private static func commands(inLine line: String, depth: Int) -> [Command] {
        guard depth <= maximumDepth else { return [] }
        return segments(of: line).flatMap { commands(of: $0, depth: depth) }
    }

    /// The command of one segment, or the commands of the string it runs.
    private static func commands(of segment: [String], depth: Int) -> [Command] {
        var words = segment
        var index = 0
        var assignments: [Assignment] = []
        var through: [String] = []
        /// The commands of a line run inside this one, behind what came before.
        func inner(_ line: String, behind wrapper: String) -> [Command] {
            commands(inLine: line, depth: depth + 1).map { command in
                var command = command
                command.assignments = assignments + command.assignments
                command.wrappers = through + [wrapper] + command.wrappers
                return command
            }
        }
        while index < words.count {
            let word = words[index]
            if assignments.isEmpty, through.isEmpty {
                if commandlessReservedWords.contains(word) { return [] }
                if leadingReservedWords.contains(word) {
                    index += 1
                    continue
                }
            }
            if let assignment = assignment(word) {
                assignments.append(assignment)
                index += 1
                continue
            }
            guard let wrapper = wrappers[word] else { break }
            var at = index + 1
            if !wrapper.subcommands.isEmpty {
                // `op run`, `aws-vault exec`: its own options, then the subcommand; any other, and it is the command.
                while at < words.count, isOption(words[at]) { at += wrapper.valued.contains(words[at]) ? 2 : 1 }
                guard at < words.count, wrapper.subcommands.contains(words[at]) else { break }
                at += 1
            }
            through.append(word)
            index = at
            var positionals = wrapper.positionals
            phase: while index < words.count {
                let word = words[index]
                if word == "--" {
                    index += 1
                    break phase
                }
                if isOption(word) {
                    let (name, attached) = option(word, among: wrapper.lines.union(wrapper.splits))
                    if wrapper.lines.contains(name) || wrapper.splits.contains(name) {
                        let valueIndex = attached == nil ? index + 1 : index
                        guard let value = attached ?? (valueIndex < words.count ? words[valueIndex] : nil) else { return [] }
                        if wrapper.lines.contains(name) { return inner(value, behind: through.removeLast()) }
                        // `env -S`: its words take its place, read on as env's.
                        words = Array(words[..<index]) + Self.words(value) + Array(words[(valueIndex + 1)...])
                        continue
                    }
                    index += wrapper.valued.contains(word) ? 2 : 1
                    continue
                }
                if positionals > 0 {
                    if positionals != .max { positionals -= 1 }
                    index += 1
                    continue
                }
                break
            }
            if wrapper.viaShell, index < words.count {
                return inner(words[index...].joined(separator: " "), behind: through.removeLast())
            }
        }
        guard index < words.count else { return [] }
        let executable = words[index]
        let tool = (executable as NSString).lastPathComponent
        if shells.contains(tool), let line = shellString(Array(words[(index + 1)...])) {
            return inner(line, behind: tool)
        }
        return [
            Command(
                assignments: assignments, wrappers: through, executable: executable, tool: tool, arguments: Array(words[(index + 1)...]))
        ]
    }

    /// A word that is an option: `-x`, `--long`, `--long=value` (not `-`, not `--`).
    private static func isOption(_ word: String) -> Bool {
        word.count > 1 && word.hasPrefix("-") && word != "--"
    }

    /// An option's name, and its value when attached (`--split-string=…`,
    /// `-S'…'`, `-c…`) to one of `names`.
    private static func option(_ word: String, among names: Set<String>) -> (String, String?) {
        if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
            return (String(word[..<equals]), String(word[word.index(after: equals)...]))
        }
        if !word.hasPrefix("--"), word.count > 2 {
            let short = String(word.prefix(2))
            if names.contains(short) { return (short, String(word.dropFirst(2))) }
        }
        return (word, nil)
    }

    /// The string a shell's `-c` runs: `-c`, or a cluster with `c` in it
    /// (`-lc`, `-ic`), makes the first word that is no option the line.
    /// Nil when there is no `-c` (`bash deploy.sh`).
    private static func shellString(_ arguments: [String]) -> String? {
        var command = false
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "--" {
                index += 1
                break
            }
            if ["-o", "+o", "-O", "+O"].contains(word) {
                index += 2
                continue
            }
            if word.hasPrefix("-") || word.hasPrefix("+"), word.count > 1 {
                if !word.hasPrefix("--"), word.dropFirst().contains("c") { command = true }
                index += 1
                continue
            }
            break
        }
        guard command, index < arguments.count else { return nil }
        return arguments[index]
    }

    /// `NAME=value`, a name being letters, digits and `_`.
    static func assignment(_ word: String) -> Assignment? {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex,
            word[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return Assignment(name: String(word[..<equals]), value: String(word[word.index(after: equals)...]))
    }

    /// The tokenizer both read through. `splitting`: operators and
    /// newlines end a segment; otherwise there is one segment and a
    /// newline is a space.
    private static func tokens(_ line: String, splitting: Bool) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        for character in line {
            if escaped {
                word.append(character)
                inWord = true
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "\\":
                escaped = true
                inWord = true
            case "'", "\"":
                quote = character
                inWord = true
            case " ", "\t", "\r":
                endWord()
            case "\n", "\r\n":
                if splitting { endSegment() } else { endWord() }
            case "|", "&", ";", "(", ")":
                if splitting {
                    endSegment()
                } else {
                    word.append(character)
                    inWord = true
                }
            default:
                word.append(character)
                inWord = true
            }
        }
        endSegment()
        return segments
    }
}
