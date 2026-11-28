import Combine
import Foundation

/// A fresh install's two settings, made once (onboarding; the rules are
/// `FreshInstall`'s): the theme at launch, the panels once the login shell
/// has said its PATH. Here, above the features, because the panels' tools
/// are looked for with each feature's own finder — Docker's folders,
/// `KubectlLocator`, Terraform's — and one search for all would contradict
/// what each panel then does.
///
/// It looks; it never runs. A file's existence or whether it is executable,
/// the login shell's PATH, and the Ghostty config's few files: no Docker
/// socket is reached, no kubeconfig read, no tool run. An isolated run looks
/// at nothing of the user's — a scenario hands it what it would have found
/// (`toolsOverride`, `ghosttyThemeOverride`) — and never blocks the main
/// thread: the shell is asked on a queue of its own.
package enum FreshInstallSetup {
    /// A scenario's look at this Mac, handed back instead of looking.
    @MainActor package static var toolsOverride: FreshInstall.Tools?
    /// A scenario's Ghostty config: whether it names a theme.
    @MainActor package static var ghosttyThemeOverride: Bool?

    /// Where Docker Desktop and OrbStack install their apps: either counts
    /// as Docker on this Mac, its CLI linked or not yet.
    package static let dockerApps = ["/Applications/Docker.app", "/Applications/OrbStack.app"]

    // MARK: Theme

    /// The terminal follows macOS between `FreshInstall.darkTheme` and
    /// `lightTheme` — on a fresh install only, before the window is made:
    /// the window writes Ghostty's overrides from settings as it is built,
    /// so the first pane already has them. Left alone where the person's
    /// Ghostty config or settings.json names a theme. Reads only settings,
    /// the Ghostty config's own few files and the two bundled themes.
    /// Returns whether it chose them.
    @MainActor @discardableResult
    package static func chooseTheme(_ launch: FirstRun.Launch, settings: Settings = .shared, defaults: UserDefaults = AppEnvironment.defaults) -> Bool {
        guard launch == .fresh, defaults.object(forKey: FreshInstall.themeDecidedKey) == nil else { return false }
        let ghosttySetsTheme: Bool
        if let override = ghosttyThemeOverride {
            ghosttySetsTheme = override
        } else {
            guard !AppEnvironment.isIsolated else { return false }
            ghosttySetsTheme = FreshInstall.ghosttySetsTheme(files: AppEnvironment.ghosttyConfigFiles) { url in
                try? String(contentsOf: url, encoding: .utf8)
            }
        }
        defaults.set(true, forKey: FreshInstall.themeDecidedKey)
        let chosen = FreshInstall.choosesTheme(
            ghosttySetsTheme: ghosttySetsTheme, settingsHasTheme: FreshInstall.themeKeys.contains { key in settings.isSet(key) },
            themesAvailable: ThemeCatalog.read(FreshInstall.darkTheme) != nil && ThemeCatalog.read(FreshInstall.lightTheme) != nil)
        guard chosen else { return false }
        settings.set("appearance.theme", .string(FreshInstall.darkTheme))
        settings.set("appearance.themeLight", .string(FreshInstall.lightTheme))
        settings.set("appearance.followSystemAppearance", .bool(true))
        return true
    }

    // MARK: Panels

    /// The optional panels whose tool isn't on this Mac turned off — on a
    /// fresh install only, once. The PATH is the login shell's, asked
    /// through `ShellEnvironment.login()`, which keeps its answer: the Start
    /// card's second step and the Setup page read that same answer, so the
    /// shell is asked once. Unanswered, nothing is turned off. A switch the
    /// person set while the shell answered is theirs, even set back to its
    /// default — which settings.json then doesn't hold, so `isSet` alone
    /// can't tell: every key settings says changed meanwhile is left alone.
    /// `looking`: a test's own look, awaited in place of the shell's.
    /// Returns the panels it hid.
    @MainActor @discardableResult
    package static func decidePanels(
        _ launch: FirstRun.Launch, settings: Settings = .shared, defaults: UserDefaults = AppEnvironment.defaults,
        looking: (@MainActor () async -> FreshInstall.Tools)? = nil
    ) async -> [SidebarPanel] {
        guard launch == .fresh, defaults.object(forKey: FreshInstall.panelsDecidedKey) == nil else { return [] }
        let touched = TouchedKeys()
        let watching = settings.changes.sink { keys in touched.keys.formUnion(keys) }
        defer { watching.cancel() }
        let tools: FreshInstall.Tools
        if let looking {
            tools = await looking()
        } else if let toolsOverride {
            tools = toolsOverride
        } else {
            guard !AppEnvironment.isIsolated else { return [] }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let appPath = ProcessInfo.processInfo.environment["PATH"]
            tools = await withCheckedContinuation { (continuation: CheckedContinuation<FreshInstall.Tools, Never>) in
                // Spelled `@Sendable`: a block for a queue written here would
                // otherwise be typed main-actor and trap off it.
                let work: @Sendable () -> Void = {
                    let files = FileManager.default
                    let found = Self.tools(
                        login: ShellEnvironment.login(), appPath: appPath, home: home, exists: { path in files.fileExists(atPath: path) },
                        isExecutable: { path in files.isExecutableFile(atPath: path) })
                    continuation.resume(returning: found)
                }
                DispatchQueue.global(qos: .utility).async(execute: work)
            }
        }
        // Asked again on the main thread: decided meanwhile, or a switch the person set.
        guard defaults.object(forKey: FreshInstall.panelsDecidedKey) == nil else { return [] }
        let hidden = FreshInstall.panelsToHide(tools) { key in settings.isSet(key) || touched.keys.contains(key) }
        defaults.set(true, forKey: FreshInstall.panelsDecidedKey)
        defaults.set(hidden.map(\.rawValue), forKey: FreshInstall.panelsHiddenKey)
        for panel in hidden {
            if let key = panel.toggleKey { settings.set(key, .bool(false)) }
        }
        return hidden
    }

    /// The settings changed while `decidePanels` waited.
    @MainActor
    private final class TouchedKeys {
        var keys = Set<String>()
    }

    /// What this Mac has of the three panels' tools, each where its feature
    /// looks: `docker` in the PATH Overterm was started with — where Docker's
    /// page and the Setup page look (`DockerCLI.locate`) —, the login shell's,
    /// and its installers' folders (`DockerCLI.folders`), or Docker Desktop's
    /// or OrbStack's app; `kubectl`
    /// where the Kubernetes panel looks (`KubectlLocator`, Settings' path
    /// aside — a fresh install has none); `terraform` or `tofu` on the PATH
    /// or in Homebrew's folders (`TerraformCLI.fallbackFolders`). Nil
    /// `login`: the PATH is unknown. Nothing under Desktop, Documents,
    /// Downloads or iCloud Drive is looked at (`SetupProbe.isProtected`):
    /// macOS would ask the person, at their first launch. Pure but for
    /// `exists` and `isExecutable`.
    package nonisolated static func tools(
        login: [String: String]?, appPath: String? = nil, home: URL, exists: (String) -> Bool, isExecutable: (String) -> Bool
    ) -> FreshInstall.Tools {
        guard let login else { return .unknown }
        let homePath = home.path
        func looksExecutable(_ path: String) -> Bool { !SetupProbe.isProtected(path, home: homePath) && isExecutable(path) }
        let path = login["PATH"]
        let dockerPath = [appPath, path].compactMap { part in part }.filter { part in !part.isEmpty }.joined(separator: ":")
        let docker =
            DockerCLI.folders(home: home, path: dockerPath).contains { folder in
                looksExecutable(URL(fileURLWithPath: folder).appendingPathComponent("docker").path)
            }
            || dockerApps.contains(where: exists)
        let kubectl = !KubectlLocator.candidates(
            configured: "", guarded: false, loginPath: path, home: home, isExecutable: looksExecutable, resolve: { url in url }
        ).isEmpty
        let terraform = ["terraform", "tofu"].contains { tool in
            ShellEnvironment.executable(tool, in: login, isExecutable: looksExecutable) != nil
                || TerraformCLI.fallbackFolders.contains { folder in looksExecutable(URL(fileURLWithPath: folder).appendingPathComponent(tool).path) }
        }
        return FreshInstall.Tools(pathKnown: true, docker: docker, kubectl: kubectl, terraform: terraform)
    }
}
