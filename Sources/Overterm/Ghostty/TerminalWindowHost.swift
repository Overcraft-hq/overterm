import AppKit
import GhosttyKit

/// The window a terminal is in, as libghostty's actions and the clipboard
/// reach it (`GhosttyRuntime`): `TerminalWindowController`, which sits
/// above this module.
@MainActor
package protocol TerminalWindowHost: NSWindowController {
    var store: TabStore { get }
    func tab(containing pane: TerminalView?) -> Tab?
    func blocks(of pane: TerminalView?) -> PaneBlocks
    func newTab(from source: TerminalView?, joining group: TabGroup.ID?)
    func split(_ source: TerminalView?, _ direction: SplitTree<TerminalView>.Direction)
    func focusSplit(from source: TerminalView?, _ focus: SplitTree<TerminalView>.Focus) -> Bool
    func resizeSplit(_ source: TerminalView?, toward direction: SplitTree<TerminalView>.Direction, points: Double)
    func equalizeSplits(_ source: TerminalView?)
    func toggleSplitZoom(_ source: TerminalView?)
    func confirmClipboard(_ confirmation: ClipboardConfirmation, from terminal: TerminalView, answer: @escaping @MainActor (Bool) -> Void)
    func showPalette(_ sender: Any?)
    func closeTabs(of view: TerminalView, mode: ghostty_action_close_tab_mode_e)
    func gotoTab(_ value: Int32) -> Bool
    func moveTab(of view: TerminalView, by amount: Int)
}

/// A path as typed into a shell: relative to the pane's folder where it is
/// inside it, quoted where it needs to be.
package enum ShellPaths {
    package nonisolated static func relativePath(_ url: URL, cwd: String?) -> String {
        let path = url.standardizedFileURL.path
        guard let cwd = cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return path }
        if path == cwd { return "." }
        return path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
    }

    package nonisolated static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        if ShellWord.hasControl(path) { return ShellWord.ansiC(path) }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
