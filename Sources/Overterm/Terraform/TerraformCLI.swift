import Foundation

/// Which terraform Overterm runs (analysis 4.2), stage 1a's part: in a
/// guarded run `OVERTERM_TERRAFORM`'s (a scenario's recording wrapper in
/// front of it) or none; else the first `terraform` on the login shell's
/// PATH, then Homebrew's places (a Dock-launched app's PATH has none). A
/// shim (tfenv, asdf, mise) picks its version by the folder it runs in,
/// which is always the root. `terraform.path` and `mise which` per root
/// come with the version pill (stage 1b).
enum TerraformCLI {
    /// The folders looked in after the shell's PATH.
    static let fallbackFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _scenarioWrapper: URL?

    /// A scenario's recording wrapper (`TerraformRecorder`), put in front of
    /// `OVERTERM_TERRAFORM`'s binary. Honoured only in a guarded run.
    static var scenarioWrapper: URL? {
        get { lock.withLock { _scenarioWrapper } }
        set { lock.withLock { _scenarioWrapper = newValue } }
    }

    /// The binary for `choice` — pure but for `isExecutable`.
    static func resolve(
        _ choice: TerraformGuards.Binary, wrapper: URL?, shellEnvironment: () -> [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        switch choice {
        case .none: return nil
        case .variable(let path):
            if let wrapper, isExecutable(wrapper.path) { return wrapper }
            return URL(fileURLWithPath: path)
        case .search:
            if let found = ShellEnvironment.executable("terraform", in: shellEnvironment(), isExecutable: isExecutable) { return found }
            return fallbackFolders.map { URL(fileURLWithPath: $0).appendingPathComponent("terraform") }.first { isExecutable($0.path) }
        }
    }

    /// The terraform to run now. Blocking the first time (the login shell
    /// is asked): off the main thread.
    static func binary() -> URL? {
        resolve(
            AppEnvironment.terraformBinary, wrapper: AppEnvironment.guardsTerraform ? scenarioWrapper : nil,
            shellEnvironment: { ShellEnvironment.environment() })
    }

    /// The same without waiting, for terraform-ls's `terraform.path`: the
    /// login shell's PATH if it has answered already (`warm` asks it when a
    /// Terraform file opens), else the app's own, then Homebrew's places.
    /// The wrapper is a scenario's: terraform-ls gets the binary itself.
    static func knownBinary() -> URL? {
        resolve(AppEnvironment.terraformBinary, wrapper: nil, shellEnvironment: { ShellEnvironment.known() ?? ProcessInfo.processInfo.environment })
    }

    /// Asks the login shell off the main thread, so `knownBinary` has its PATH.
    static func warm() {
        let work: @Sendable () -> Void = { _ = binary() }
        DispatchQueue.global(qos: .utility).async(execute: work)
    }
}
