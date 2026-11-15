import Foundation

/// The recording wrapper for terraform processes in tests and scenarios
/// (analysis 11): a script named `terraform`, which `OVERTERM_TERRAFORM`
/// names, that records each call — its arguments, its folder, its
/// environment's **names**, and the values of only the variables Overterm
/// sets for Terraform (`recordedValues`) — then `exec`s the target: the
/// real terraform in a sandbox, or a stand-in script (`writeStandIn`). What
/// asserts the argv and environment rules (5.13 rule 3) against real runs.
///
/// A call is a folder of its own under `records/` (`mktemp -d`, so two
/// calls at once don't share a file), its files NUL-separated where a
/// word can hold anything: a shell can't write JSON safely, and values
/// other than those few never reach the disk. The script runs `bash -p`:
/// no `BASH_ENV`, no startup file, no function from the environment, and
/// bash adds nothing to what terraform gets but `PWD`, `SHLVL` and `_`
/// (`shellNames`, left out of `names`).
struct TerraformRecorder: Sendable {
    /// The variables whose values are recorded: the ones Overterm sets,
    /// none a credential (`TerraformGuards.isCredential`).
    static let recordedValues = [
        "CHECKPOINT_DISABLE", "TF_INPUT", "TF_IN_AUTOMATION", "TF_DATA_DIR", "TF_WORKSPACE", "TF_PLUGIN_CACHE_DIR", "TF_CLI_CONFIG_FILE", "HOME",
    ]
    /// What bash itself exports to what it runs.
    static let shellNames: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// One call, as the wrapper saw it.
    struct Call: Equatable, Sendable {
        var arguments: [String]
        /// The folder it ran in, symlinks resolved.
        var cwd: String
        /// The environment's names, sorted, bash's own left out.
        var names: [String]
        /// `recordedValues`' values, those set.
        var values: [String: String]

        /// The subcommand: the first argument that isn't a global option
        /// (`-chdir=…`, `-help`).
        var subcommand: String? { arguments.first { !$0.hasPrefix("-") } }
    }

    /// The folder it lives in: `bin/terraform`, `records/`.
    let folder: URL
    /// What it runs: an absolute path.
    let target: String

    var wrapper: URL { folder.appendingPathComponent("bin/terraform") }
    var records: URL { folder.appendingPathComponent("records", isDirectory: true) }

    /// Writes the wrapper (0700) in `folder` (made 0700), in front of
    /// `target`.
    static func make(in folder: URL, target: String) throws -> TerraformRecorder {
        guard target.hasPrefix("/") else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: target]) }
        let recorder = TerraformRecorder(folder: folder, target: target)
        let manager = FileManager.default
        try manager.createDirectory(at: recorder.records, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: recorder.wrapper.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try Data(recorder.script.utf8).write(to: recorder.wrapper, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recorder.wrapper.path)
        return recorder
    }

    /// The wrapper's text.
    var script: String {
        """
        #!/bin/bash -p
        # Overterm's recording wrapper (TerraformRecorder): records this call,
        # then runs the target. Values are recorded only for the names listed.
        call=$(/usr/bin/mktemp -d \(Self.quoted(records.path + "/call.XXXXXXXX"))) || exit 97
        { [ $# -eq 0 ] || printf '%s\\0' "$@"; } > "$call/argv"
        pwd -P > "$call/cwd"
        compgen -e > "$call/names"
        for name in \(Self.recordedValues.joined(separator: " ")); do
          if [ -n "${!name+x}" ]; then printf '%s=%s\\0' "$name" "${!name}"; fi
        done > "$call/values"
        : > "$call/complete"
        exec \(Self.quoted(target)) "$@"

        """
    }

    /// The calls recorded so far, oldest first. A call still being
    /// written is left out.
    func calls() -> [Call] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: records.path)) ?? []
        var found: [(date: Date, name: String, call: Call)] = []
        for name in names where name.hasPrefix("call.") {
            let dir = records.appendingPathComponent(name, isDirectory: true)
            guard manager.fileExists(atPath: dir.appendingPathComponent("complete").path),
                let argv = try? Data(contentsOf: dir.appendingPathComponent("argv")),
                let cwd = try? String(contentsOf: dir.appendingPathComponent("cwd"), encoding: .utf8),
                let environment = try? String(contentsOf: dir.appendingPathComponent("names"), encoding: .utf8),
                let values = try? Data(contentsOf: dir.appendingPathComponent("values"))
            else { continue }
            var recorded: [String: String] = [:]
            for pair in Self.nulSeparated(values) {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                recorded[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            let call = Call(
                arguments: Self.nulSeparated(argv), cwd: cwd.trimmingCharacters(in: .newlines),
                names: environment.split(separator: "\n").map(String.init).filter { !Self.shellNames.contains($0) }.sorted(), values: recorded)
            let date = (try? manager.attributesOfItem(atPath: dir.path)[.creationDate] as? Date) ?? .distantPast
            found.append((date, name, call))
        }
        return found.sorted { ($0.date, $0.name) < ($1.date, $1.name) }.map(\.call)
    }

    /// Forgets the calls recorded.
    func reset() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []
        for name in names where name.hasPrefix("call.") {
            try? FileManager.default.removeItem(at: records.appendingPathComponent(name))
        }
    }

    /// A stand-in for terraform at `url` (0700): prints `stdout` and
    /// `stderr` (kept in files beside it, so any text goes) and exits
    /// with `exitCode`, whatever it is asked. For a unit test that needs
    /// a process, not Terraform.
    static func writeStandIn(at url: URL, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let out = url.path + ".stdout"
        let err = url.path + ".stderr"
        try Data(stdout.utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
        try Data(stderr.utf8).write(to: URL(fileURLWithPath: err), options: .atomic)
        let script = """
            #!/bin/bash -p
            # A stand-in for terraform (TerraformRecorder.writeStandIn).
            /bin/cat \(quoted(out))
            /bin/cat \(quoted(err)) >&2
            exit \(exitCode)

            """
        try Data(script.utf8).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A word in single quotes, as a shell reads it back.
    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nulSeparated(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        // printf ends every word with a NUL: the last part is the empty rest.
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
