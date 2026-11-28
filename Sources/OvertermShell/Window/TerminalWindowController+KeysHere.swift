import AppKit
import SwiftUI

/// Help ▸ Keys Here (DISC-N1): the keys of wherever the keyboard is — a
/// page's own `?` sheet over Docker, Kubernetes, Activity and Review;
/// otherwise the terminal's, the editor's or the browser's, from
/// `KeyCommands` and the bindings now (`KeySheet.Surface`).
extension TerminalWindowController {
    @objc package func showKeysHere(_ sender: Any?) {
        switch store.showingOverlay {
        case .docker: dockerPage.cheatSheet = true
        case .kubernetes: kubernetesPage.cheatSheet = true
        case .activity: activityPage.cheatSheet = true
        default:
            if let review = shownReview {
                review.showsKeys = true
            } else {
                presentKeySheet(keysSurface)
            }
        }
    }

    /// The surface the keyboard is on: the editor or the browser column
    /// when one of theirs has it, else the terminal.
    package var keysSurface: KeySheet.Surface {
        if focusedColumn == .editor { return .editor }
        if let responder = window?.firstResponder as? NSView, let browser = browserColumn?.view, browserItem?.isCollapsed == false,
            responder.isDescendant(of: browser)
        {
            return .browser
        }
        return .terminal
    }

    private func presentKeySheet(_ surface: KeySheet.Surface) {
        guard let window, let theme, window.attachedSheet == nil else { return NSSound.beep() }
        let panel = KeySheetPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let close: () -> Void = { [weak window, weak panel] in
            guard let panel else { return }
            window?.endSheet(panel)
        }
        panel.dismiss = close
        let groups = surface.groups { Keybindings.shared.key(for: $0)?.display }
        let host = NSHostingView(
            rootView: KeySheetView(
                theme: theme, title: surface.title, groups: groups, footnote: "Every command and its key: Settings ▸ Keyboard Shortcuts.",
                identifier: "keysHere.\(surface.rawValue)", close: close))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        window.beginSheet(panel)
    }
}

/// Keys Here's sheet: any key, Esc among them, puts it away.
final class KeySheetPanel: NSPanel {
    var dismiss: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func keyDown(with event: NSEvent) { dismiss() }
}
