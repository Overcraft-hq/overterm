import Foundation

/// A shell pane's text comes back on the next launch: saved at quit (plain
/// text, the last lines), printed into the new pane before its shell starts.
///
/// libghostty has no way to feed output into a surface, so a restored pane
/// runs a launcher instead of the shell: a script named after the shell
/// (Ghostty picks its shell integration by that name) that prints the saved
/// text, deletes it, and execs the real shell as a login shell. The
/// integration's environment (ZDOTDIR for zsh, XDG_DATA_DIRS for fish)
/// passes through, so cwd reporting and prompt marks keep working.
enum Scrollback {
    /// How much of a pane comes back.
    static let maxLines = 2000
    /// The environment variable naming the file a launcher prints.
    static let fileVariable = "TERMINUS_RESTORE"

    static var directory: URL { AppEnvironment.supportDirectory.appendingPathComponent("scrollback", isDirectory: true) }

    /// Trailing blank rows dropped, the last `maxLines` kept.
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \r")) == "" ? "" : $0 }
        while lines.last == "" { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Writes a pane's text; the file's name (for the session), or nil
    /// when there was nothing worth keeping.
    static func save(_ text: String) -> String? {
        let text = trimmed(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = UUID().uuidString + ".txt"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((text + "\n").utf8).write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    /// A saved file, if it is still there.
    static func file(named name: String?) -> URL? {
        guard let name, !name.contains("/") else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes saved files no session refers to (a launcher deletes what it
    /// printed; this catches the rest).
    static func removeAll(except keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Shells whose Ghostty integration comes through the environment, so a
    /// launcher in front of them keeps it. (bash's is set up through its
    /// arguments, and Apple's bash 3.2 has none.)
    static let supportedShells: Set<String> = ["zsh", "fish"]

    /// The user's login shell, as login(1) would start it.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The launcher for `shell`, written if needed — nil for a shell it
    /// can't stand in front of. Lives in the temporary directory: Ghostty
    /// runs the command through `bash -c`, and "Application Support" has a
    /// space in it.
    static func launcher(for shell: String = loginShell) -> String? {
        let name = (shell as NSString).lastPathComponent
        guard supportedShells.contains(name) else { return nil }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("terminus-restore", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        let script = launcherScript(shell: shell)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url.path.contains(" ") ? nil : url.path
    }

    static func launcherScript(shell: String) -> String {
        let name = (shell as NSString).lastPathComponent
        return """
            #!/bin/bash
            # Terminus: print this pane's text from the last session, then start the shell.
            if [ -n "$\(fileVariable)" ] && [ -f "$\(fileVariable)" ]; then
              # login(1) has just printed today's "Last login": the old text starts at the top.
              printf '\\033[H\\033[2J\\033[3J'
              cat "$\(fileVariable)"
              rm -f "$\(fileVariable)"
              printf '\\033[2m── restored from the last session ──\\033[0m\\n'
            fi
            unset \(fileVariable)
            exec -a "-\(name)" "\(shell)" "$@"

            """
    }
}
