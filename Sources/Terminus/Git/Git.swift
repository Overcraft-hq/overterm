import Foundation

struct GitError: LocalizedError {
    let arguments: [String]
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(status)" : message
    }
}

/// Runs git (and other command-line tools). Each call blocks a libdispatch thread, never a Swift
/// concurrency one: blocking the cooperative pool with many waits starves
/// the whole app (signalbox froze exactly that way).
enum Git {
    /// /usr/bin/git is the Xcode shim; a GUI app's PATH has no Homebrew.
    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// - Parameter success: exit codes that are not failures. `git diff
    ///   --no-index` exits 1 when the files differ, which is the point.
    static func run(_ arguments: [String], in directory: URL, success: Set<Int32> = [0]) async throws -> String {
        try await run(executable, arguments, in: directory, success: success)
    }

    /// Any tool, the same way: a GCD thread, stderr drained, no prompts.
    static func run(_ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32> = [0]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(tool, arguments, in: directory, success: success) })
            }
        }
    }

    private static func runBlocking(_ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32>) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Never block on a credential or editor prompt nobody can see.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain stderr concurrently: a full pipe would block git, and git
        // would never close stdout.
        var errData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        guard success.contains(process.terminationStatus) else {
            throw GitError(arguments: arguments, status: process.terminationStatus, stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
