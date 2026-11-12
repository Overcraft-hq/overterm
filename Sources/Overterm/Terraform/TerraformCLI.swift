import Foundation

/// Which terraform Overterm runs (analysis 4.2), stage 1a's part: in a
/// guarded run `OVERTERM_TERRAFORM`'s (a scenario's recording wrapper in
/// front of it) or none; else the first `terraform` on the login shell's
/// PATH, then Homebrew's places (a Dock-launched app's PATH has none). A
/// shim (tfenv, asdf, mise) picks its version by the folder it runs in,
/// which is always the root. Per root (stage 1b, `binary(forRoot:)`):
/// `terraform.path`, else `mise which terraform` where a version file asks
/// for one, else the same search; its version asked once (`version`).
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

    // MARK: Per root (4.2)

    /// The terraform a root runs, as an absolute path: guarded, the one
    /// above; else `terraform.path` when it names an executable; else, when
    /// a version file from the root up asks for a version and mise is on
    /// the login shell's PATH, `mise which terraform` with the root as its
    /// folder; else the search. Blocking (the shell, mise): off the main thread.
    static func binary(forRoot root: URL, settingPath: String, hasVersionFile: Bool) -> URL? {
        guard !AppEnvironment.guardsTerraform else { return binary() }
        let setting = (settingPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if setting.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: setting) { return URL(fileURLWithPath: setting) }
        if hasVersionFile, let mise = ShellEnvironment.executable("mise", in: ShellEnvironment.environment()),
            let found = try? Git.runBlocking(mise, ["which", "terraform"], in: root, success: [0], timeout: 10, outputLimit: 4096)
        {
            let path = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return binary()
    }

    /// `version -json`'s `terraform_version`. Pure.
    static func parseVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["terraform_version"] as? String,
            TerraformVersion(version) != nil
        else { return nil }
        return version
    }

    /// The version of `binary` as it runs in `root` (a shim picks by its
    /// folder). Blocking: a GCD thread's.
    static func version(of binary: URL, in root: URL) -> String? {
        guard let base = try? AppEnvironment.terraformBaseEnvironment(),
            let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
        else { return nil }
        let environment = TerraformEnvironment.build(base: base, purpose: .format, root: root, scratch: scratch)
        guard let result = try? TerraformRun.runBlocking(binary, TerraformCommands.version, in: root, environment: environment, input: nil, timeout: 15),
            result.status == 0
        else { return nil }
        return parseVersion(result.stdout)
    }
}
