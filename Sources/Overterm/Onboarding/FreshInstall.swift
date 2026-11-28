import Foundation

/// What a fresh install sets once, before the person has chosen anything
/// (onboarding 7.2; the owner's reversal of D-8, and the theme): the
/// optional panels whose tool isn't on this Mac start hidden, and the
/// terminal follows macOS between a light and a dark theme. Only on
/// `FirstRun.Launch.fresh` — an update or the same version again changes
/// nothing —, each decision written to settings.json once, never over a
/// setting the person already has there, and remembered as made in the
/// app's own defaults (`AppEnvironment.defaults`) so it never runs again.
///
/// Pure: the rules and the words. What is looked at, and when, is
/// `FreshInstallSetup`'s (the shell's, which has the features' own finders).
package enum FreshInstall {
    // MARK: Kept

    /// The panels' decision was made (whatever it hid): never again.
    package static let panelsDecidedKey = "onboarding.panelsDecided"
    /// The panels it hid, by `SidebarPanel` raw value: what the card's line
    /// and the Setup page say while they are still off.
    package static let panelsHiddenKey = "onboarding.panelsHidden"
    /// The theme's decision was made (whether or not it chose one): never again.
    package static let themeDecidedKey = "onboarding.themeDecided"

    // MARK: Panels

    /// What a look at this Mac found: each panel's tool there or not.
    /// Existence and executability only — no tool run, no socket reached,
    /// no kubeconfig read.
    package struct Tools: Equatable, Sendable {
        /// The login shell said its PATH. Without it nothing is known, and
        /// nothing is hidden: a tool may be on the PATH it didn't say.
        package var pathKnown: Bool
        /// `docker` on the PATH or in its installers' folders, or Docker
        /// Desktop's or OrbStack's app.
        package var docker: Bool
        /// `kubectl` where the Kubernetes panel looks for it.
        package var kubectl: Bool
        /// `terraform` or `tofu` on the PATH or in Homebrew's folders.
        package var terraform: Bool

        package init(pathKnown: Bool, docker: Bool = false, kubectl: Bool = false, terraform: Bool = false) {
            self.pathKnown = pathKnown
            self.docker = docker
            self.kubectl = kubectl
            self.terraform = terraform
        }

        /// The login shell didn't answer.
        package static let unknown = Tools(pathKnown: false)
    }

    /// The panels a fresh install may start hidden, each by its own tool,
    /// in the rail's order. API, Database, Notes, Sessions and Snippets need
    /// nothing installed and are left as they are.
    package static let toolPanels: [SidebarPanel] = [.docker, .kubernetes, .terraform]

    /// The panels to hide: those whose tool wasn't found — none while the
    /// PATH is unknown — leaving out any whose switch the person already
    /// set in settings.json (`isSet`).
    package static func panelsToHide(_ tools: Tools, isSet: (String) -> Bool) -> [SidebarPanel] {
        guard tools.pathKnown else { return [] }
        return toolPanels.filter { panel in
            guard let key = panel.toggleKey, !isSet(key) else { return false }
            switch panel {
            case .docker: return !tools.docker
            case .kubernetes: return !tools.kubectl
            case .terraform: return !tools.terraform
            default: return false
            }
        }
    }

    /// The panels it hid, as `panelsHiddenKey` keeps them; an id this build
    /// doesn't know, or a panel that isn't one of `toolPanels`, is passed over.
    package static func hidden(stored: [String]?) -> [SidebarPanel] {
        let panels = (stored ?? []).compactMap(SidebarPanel.init(rawValue:))
        return toolPanels.filter { panel in panels.contains(panel) }
    }

    /// The card's line: "Docker, Kubernetes hidden — not found on this Mac";
    /// nil when nothing it hid is still off.
    package static func hiddenLine(_ panels: [SidebarPanel]) -> String? {
        guard !panels.isEmpty else { return nil }
        return panels.map(\.title).joined(separator: ", ") + " hidden — not found on this Mac"
    }

    /// The card's button beside it.
    package static let show = "Show"

    // MARK: Theme

    /// The pair a fresh install follows macOS with: Catppuccin's Mocha after
    /// dark and Latte in daylight — one palette drawn as a pair, so the
    /// switch at sunset changes the light, not the colours' meaning (red is
    /// the same red, a diff reads the same way). Both keep text well apart
    /// from their background and both are bundled with Ghostty v1.4.0 and in
    /// the gallery's Popular row, where Settings ▸ Themes opens.
    package static let darkTheme = "Catppuccin Mocha"
    package static let lightTheme = "Catppuccin Latte"

    /// The settings a theme is chosen by: any of them in settings.json is the
    /// person's choice, kept.
    package static let themeKeys = ["appearance.theme", "appearance.themeLight", "appearance.followSystemAppearance"]

    /// Whether a fresh install sets the pair: neither the person's Ghostty
    /// config nor settings.json names a theme, and both themes are there.
    package static func choosesTheme(ghosttySetsTheme: Bool, settingsHasTheme: Bool, themesAvailable: Bool) -> Bool {
        !ghosttySetsTheme && !settingsHasTheme && themesAvailable
    }

    /// What a Ghostty config file says of the theme, read the way Ghostty
    /// reads its lines: its last `theme = …` (any value, a `light:…,dark:…`
    /// pair too; empty — `theme =` — puts Ghostty's default back), nil when
    /// it has none, and the files it includes (`config-file = …`, `?` for an
    /// optional one). Comments and blank lines are passed over. Pure.
    package static func ghosttyConfig(_ text: String) -> (theme: String?, includes: [String]) {
        var theme: String?
        var includes: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "theme":
                theme = value
            case "config-file":
                if value.hasPrefix("?") { value = String(value.dropFirst()) }
                if !value.isEmpty { includes.append(value) }
            default:
                break
            }
        }
        return (theme, includes)
    }

    /// Whether the Ghostty config Overterm loads names a theme, in the order
    /// libghostty loads it: every one of `files` — the default ones
    /// (`AppEnvironment.ghosttyConfigFiles`), `ghostty_config_load_default_files`
    /// — then the files they include (`ghostty_config_load_recursive_files`),
    /// each after all the files before it, an include's own includes at the
    /// end of the list, relative to the including file's folder. The last
    /// `theme` line read decides: a later file's `theme =` puts the default
    /// back. At most `ghosttyFilesLimit` files read (only those there count),
    /// a file once, `ghosttyLookupsLimit` looked for. `read`: a file's text,
    /// nil when it isn't there. Pure but for `read`.
    package static func ghosttySetsTheme(files: [URL], read: (URL) -> String?) -> Bool {
        var list = files
        var next = 0
        var seen = Set<String>()
        var readCount = 0
        var theme: String?
        while next < list.count, next < ghosttyLookupsLimit, readCount < ghosttyFilesLimit {
            let file = list[next]
            next += 1
            guard seen.insert(file.standardizedFileURL.path).inserted, let text = read(file) else { continue }
            readCount += 1
            let said = ghosttyConfig(text)
            if let value = said.theme { theme = value }
            let folder = file.deletingLastPathComponent()
            for include in said.includes {
                let path = (include as NSString).expandingTildeInPath
                list.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path))
            }
        }
        return theme.map { value in !value.isEmpty } ?? false
    }

    /// The most config files `ghosttySetsTheme` reads: the default ones and what they include.
    package static let ghosttyFilesLimit = 16
    /// The most paths it looks for, there or not: a loop of missing includes ends.
    package static let ghosttyLookupsLimit = 64
}
