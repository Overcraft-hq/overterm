import Foundation

/// An app a file can be opened with, known by its bundle id — that is
/// what gets remembered, since the app itself may move or update.
struct ExternalApp: Hashable, Identifiable {
    let bundleID: String
    /// As Finder shows it: "Visual Studio Code", not the bundle's "Code".
    let name: String
    /// Where it is installed.
    let url: URL

    var id: String { bundleID }
}

/// Opening a file outside Terminus in the app the user picked, the way
/// Finder's Open With, GitHub Desktop or Fork do it: asked the first time,
/// remembered, changed any time. This is the pure part — which apps to
/// offer and in what order, whether the remembered one can be used, what
/// the menus say. `ExternalOpener` asks and opens.
enum OpenWith {
    /// The remembered app's bundle id, in AppEnvironment.defaults.
    static let rememberedKey = "openWithApp"

    /// Code editors, offered first when installed, in this order — whether
    /// or not they claim the file's type (a Makefile or a .toml is still
    /// code). Ids as the apps' Info.plist has them; names don't help (VS
    /// Code's bundle is "Code", Cursor's id is its packager's).
    static let editors = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.google.antigravity",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
        // JetBrains
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rustrover",
        "com.jetbrains.datagrip",
    ]

    static let submenuTitle = "Open With"
    static let otherTitle = "Other…"
    static let question = "Open files with which app?"

    /// The Open With list: the installed `editors` (in `editors` order), the
    /// system's default, then by name everything else that can open the
    /// file — and the app in use, which may not claim it (picked with
    /// Other…); picking one doesn't reorder the list. One entry per bundle
    /// id, the first seen (Xcode and Xcode-beta share one), and never
    /// `excluding` (Terminus itself).
    static func candidates(
        editors: [ExternalApp], current: ExternalApp?, systemDefault: ExternalApp?, canOpen: [ExternalApp], excluding: String?
    ) -> [ExternalApp] {
        let rest = (canOpen + [current].compactMap { $0 }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seen = Set([excluding].compactMap { $0 })
        return (editors + [systemDefault].compactMap { $0 } + rest).filter { seen.insert($0.bundleID).inserted }
    }

    enum Resolution: Equatable {
        case open(ExternalApp)
        case ask
    }

    /// What opening a file does: the remembered app while it is installed;
    /// with none, or one that is gone, ask.
    static func resolve(remembered: String?, installed: (String) -> ExternalApp?) -> Resolution {
        guard let remembered, let app = installed(remembered) else { return .ask }
        return .open(app)
    }

    /// The item that opens a file right away, and the editor ↗'s tooltip:
    /// "Open in Zed", or "Open With…" (it asks) while no app is picked.
    static func openTitle(_ app: ExternalApp?) -> String {
        app.map { "Open in \($0.name)" } ?? "Open With…"
    }

    /// An app in the Open With list; Finder's "(default)" on the system's pick.
    static func title(of app: ExternalApp, systemDefault: String?) -> String {
        app.bundleID == systemDefault ? "\(app.name) (default)" : app.name
    }

    enum Entry: Equatable {
        case app(ExternalApp, title: String, isCurrent: Bool)
        case divider
        case other
    }

    /// The Open With menu (and the question sheet's pop-up): the candidates,
    /// the one in use ticked, then Other….
    static func entries(candidates: [ExternalApp], systemDefault: String?, current: String?) -> [Entry] {
        let apps = candidates.map { Entry.app($0, title: title(of: $0, systemDefault: systemDefault), isCurrent: $0.bundleID == current) }
        return apps.isEmpty ? [.other] : apps + [.divider, .other]
    }

    /// An app's name from its file's display name ("Visual Studio Code.app"
    /// when Finder shows all extensions).
    static func appName(displayName: String) -> String {
        displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
    }
}
