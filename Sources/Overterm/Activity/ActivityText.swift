import Darwin
import Foundation

/// What Activity shows of another program's text (docs/design/activity/
/// analysis.md, 9.3, 8.4): a command line masked when it is read — the raw
/// words never kept, no unmasked view anywhere (D-27) — a tab title masked
/// as one, the same text made safe for an agent, and an interpreter's
/// label. Pure, over `Secrets`, which Docker and Kubernetes share: a form
/// it misses is a residual risk, its tests growing with each one found.
package enum ActivityText {
    /// A command's words as every screen and agent sees them: secret flags,
    /// `KEY=value` and the passwords programs take in places of their own
    /// (`Secrets.maskArguments`), joined, then every URL's password, the
    /// credentials free text carries (bearer tokens, vendor prefixes, PEM
    /// blocks) and base64 blobs (`display`).
    package static func command(_ words: [String]) -> String {
        command(masked: Secrets.maskArguments(words))
    }

    /// Words `Secrets.maskArguments` gave, joined and masked as text.
    package static func command(masked words: [String]) -> String {
        display(words.joined(separator: " "))
    }

    /// Text whose words are masked already — a command `command` joined —
    /// with what looks secret in text masked: URLs' passwords, then
    /// credentials and base64 blobs. Not for a title: its words aren't
    /// (`title`).
    package static func display(_ text: String) -> String {
        Secrets.scrubCredentials(Secrets.maskURLs(in: text))
    }

    /// A tab's title, or any text a program wrote: a command too (9.3), so
    /// its words are masked as a command's first (`Secrets.maskArguments`:
    /// `psql --password x`, `mysql -px`, `docker login -p x`, its spacing
    /// kept), then as text (`display`).
    package static func title(_ text: String) -> String {
        display(Secrets.maskArguments([text]).first ?? text)
    }

    /// The most an agent reads of one field of another program's (8.2).
    package static let agentFieldLimit = 120

    /// `text` for an agent (8.4): `title`'s masking, the home folder as
    /// `~`, one line with every character visible (a control character as
    /// its code, as the asker line shows it), cut at `limit` characters —
    /// none for Overterm's own words.
    package static func forAgents(_ text: String, home: String = ActivityText.home, limit: Int? = agentFieldLimit) -> String {
        var out = title(text)
        if !home.isEmpty, home != "/" { out = replacingHome(home, in: out) }
        out = DockerMCP.displayed(String(out.map { $0.isNewline || $0 == "\t" ? " " : $0 }))
        if let limit, out.count > limit { out = String(out.prefix(max(limit - 1, 0))) + "…" }
        return out
    }

    /// This user's home folder, as processes' paths spell it — the
    /// password database's, not `$HOME`, which an isolated run moves.
    package static let home: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }()

    /// `home` as `~` where a path starts with it: the folder itself or
    /// below it, never `/Users/ann2` for `/Users/ann`.
    package static func replacingHome(_ home: String, in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            let after = rest[range.upperBound...]
            let ends = after.first.map { $0 == "/" || $0.isWhitespace || "\"'),;:".contains($0) } ?? true
            out += rest[..<range.lowerBound]
            out += ends ? "~" : String(rest[range])
            rest = after
        }
        return out + rest
    }

    // MARK: Labels

    /// Interpreters whose script names what runs: `node …/vite/bin/vite.js`
    /// is vite (6.5). Lowercased, a version cut (`python3.12`).
    package static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "python", "pypy", "ruby", "perl", "php", "java"]
    /// Package runners, as a command or as the script node runs.
    package static let runners: [String: String] = [
        "npm": "npm", "npm-cli.js": "npm", "npx": "npx", "npx-cli.js": "npx", "pnpm": "pnpm", "pnpm.cjs": "pnpm", "pnpm.js": "pnpm",
        "pnpx": "pnpx", "yarn": "yarn", "yarn.js": "yarn", "yarn.cjs": "yarn", "yarnpkg": "yarn", "bunx": "bunx", "uvx": "uvx",
        "pipx": "pipx",
    ]
    /// Each interpreter's flags whose value is the next word.
    package static let valuedFlags: [String: Set<String>] = [
        "node": ["-r", "--require", "--import", "--loader", "--experimental-loader", "--inspect-port", "--env-file", "--title", "--conditions", "-C"],
        "python": ["-X", "-W", "-Q"],
        "pypy": ["-X", "-W", "-Q"],
        "ruby": ["-I", "-r", "-C", "-E"],
        "perl": ["-I", "-M", "-m"],
        "java": ["-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-modules"],
    ]

    /// The longest label, in characters.
    package static let labelLimit = 80

    /// A short name for what an interpreter or a package runner runs, from
    /// its masked words (6.5): `node …/vite/bin/vite.js` is "vite",
    /// `python -m http.server 8000` "python -m http.server", `npm exec
    /// @playwright/mcp` "npm exec @playwright/mcp"; nil for anything else,
    /// whose own name says it. The interpreter stays in the Command column.
    /// Masked whole, then cut at `labelLimit`: cut first, a URL's password
    /// lost its `@` and showed.
    package static func label(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        let program = (first as NSString).lastPathComponent
        let label: String?
        if let runner = runners[program] {
            label = runnerLabel(runner, Array(words.dropFirst()))
        } else if let interpreter = interpreter(program) {
            label = interpreterLabel(interpreter, as: program == "Python" ? "python" : program, Array(words.dropFirst()))
        } else {
            label = nil
        }
        return label.map { String(display($0).prefix(labelLimit)) }
    }

    /// `program` as one of `interpreters`, its version cut; nil when it is none.
    package static func interpreter(_ program: String) -> String? {
        let lower = program.lowercased()
        let bare = String(lower.prefix { !$0.isNumber && $0 != "." })
        return interpreters.contains(bare) ? bare : nil
    }

    private static func interpreterLabel(_ interpreter: String, as program: String, _ arguments: [String]) -> String? {
        var index = 0
        // deno and bun take a subcommand first: `deno run`, `bun run`.
        if interpreter == "deno" || interpreter == "bun", let first = arguments.first, ["run", "x", "exec", "task"].contains(first) {
            if first == "x" || first == "task" { return arguments.count > 1 ? "\(program) \(first) \(arguments[1])" : nil }
            index = 1
        }
        while index < arguments.count {
            let word = arguments[index]
            if word == "-m", interpreter == "python" || interpreter == "pypy" {
                return index + 1 < arguments.count ? "\(program) -m \(arguments[index + 1])" : nil
            }
            if word == "-jar", interpreter == "java" {
                return index + 1 < arguments.count ? (arguments[index + 1] as NSString).lastPathComponent : nil
            }
            // Code on the command line, no script: `node -e`, `python -c`, `php -r`.
            if ["-e", "--eval", "-c", "-p", "--print"].contains(word) && interpreter != "java" || word == "-r" && interpreter == "php" {
                return "\(program) \(word)"
            }
            if word == "--" {
                index += 1
                break
            }
            if word.hasPrefix("-") {
                index += valuedFlags[interpreter == "nodejs" ? "node" : interpreter]?.contains(word) == true ? 2 : 1
                continue
            }
            break
        }
        guard index < arguments.count else { return nil }
        let script = arguments[index]
        if interpreter == "java" { return (script as NSString).lastPathComponent }
        let name = (script as NSString).lastPathComponent
        if let runner = runners[name] { return runnerLabel(runner, Array(arguments.dropFirst(index + 1))) }
        return scriptLabel(script)
    }

    /// A script's path as a name: a command in `node_modules/.bin`
    /// (`eslint`); a package's bin (`…/vite/bin/vite.js` is "vite"), a
    /// venv's or a system folder's bin its file (`.venv/bin/uvicorn`); a
    /// package's file (`node_modules/@playwright/mcp/cli.js`); else the
    /// file's name.
    package static func scriptLabel(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return path }
        let folder = parts.count >= 2 ? parts[parts.count - 2] : nil
        if folder == ".bin" { return file }
        if folder == "bin" {
            let package = parts.count >= 3 ? parts[parts.count - 3] : nil
            guard let package, !package.hasPrefix("."), !systemFolders.contains(package) else {
                return (file as NSString).deletingPathExtension
            }
            if parts.count >= 4, parts[parts.count - 4].hasPrefix("@") { return "\(parts[parts.count - 4])/\(package)" }
            return package
        }
        if let modules = parts.lastIndex(of: "node_modules"), modules + 2 < parts.count {
            let first = parts[modules + 1]
            if first.hasPrefix("@"), modules + 3 < parts.count { return "\(first)/\(parts[modules + 2])" }
            return first
        }
        return file
    }

    /// Folders whose `bin` holds commands, not a package's.
    private static let systemFolders: Set<String> = ["", "usr", "local", "opt", "homebrew", "venv", "env", "sbin", "libexec", "Cellar"]

    /// `npm exec pkg`, `npm run dev`, `npx pkg`, `pnpm dlx pkg`, `pnpm dev`,
    /// `yarn dev`, `uvx tool`, `pipx run tool`.
    private static func runnerLabel(_ runner: String, _ arguments: [String]) -> String {
        let words = arguments.filter { !$0.hasPrefix("-") }
        switch runner {
        case "npx", "pnpx", "bunx", "uvx":
            return words.first.map { "\(runner) \($0)" } ?? runner
        case "pipx":
            return words.count >= 2 && words[0] == "run" ? "pipx run \(words[1])" : (words.first.map { "pipx \($0)" } ?? runner)
        default:
            guard let command = words.first else { return runner }
            let named = ["x": "exec", "run-script": "run", "rr": "run"][command] ?? command
            if ["exec", "dlx", "run"].contains(named), words.count >= 2 { return "\(runner) \(named) \(words[1])" }
            return "\(runner) \(command)"
        }
    }
}
