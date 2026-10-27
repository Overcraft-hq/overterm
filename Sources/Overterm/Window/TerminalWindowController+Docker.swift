import AppKit
import Combine
import SwiftUI

/// Docker: the page over the body (⌥⌘P), the commands it types into
/// terminal tabs, and the setting that turns it all off.
extension TerminalWindowController {
    var dockerActions: DockerActions {
        DockerActions(
            run: { [weak self] command, folder in self?.runDockerCommand(command, in: folder) },
            confirm: { [weak self] title, detail, button, then in self?.confirmDocker(title, detail, button, then) },
            open: { [weak self] url in self?.openDockerLink(url) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            settings: { [weak self] in self?.openSettings(.docker) }
        )
    }

    /// The page's view, made the first time it opens.
    func makeOverlay(_ overlay: WorkspaceOverlay) -> NSView? {
        switch overlay {
        case .settings: return nil
        case .docker:
            guard let theme else { return nil }
            dockerPage.actions = dockerActions
            return NSHostingView(rootView: DockerPageView(page: dockerPage, docker: .shared, theme: theme, actions: dockerActions))
        }
    }

    /// View ▸ Docker (⌥⌘P): the page, or back to the terminal from it.
    @objc func toggleDockerPage(_ sender: Any?) {
        guard Settings.shared.dockerEnabled else { return openSettings(.docker) }
        if store.showingOverlay == .docker {
            hideOverlay()
        } else {
            showOverlay(.docker)
            focusDockerList()
        }
    }

    /// The keyboard to the list's table — AppKit's way, since SwiftUI's
    /// focus wouldn't take it back from the filter field. Its table exists
    /// only once SwiftUI has laid the list out: tried again shortly.
    func focusDockerList(attempts: Int = 10) {
        guard store.showingOverlay == .docker, let page = dockerView else { return }
        if let table = Self.firstTable(in: page) {
            window?.makeFirstResponder(table)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusDockerList(attempts: attempts - 1) }
        }
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    /// The model polls only while a page shows it; events run regardless
    /// once it has started.
    func watchDockerPage() -> AnyCancellable {
        var shown = false
        return store.$showingOverlay
            .map { $0 == .docker }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.dockerPage.visible = visible
                guard visible != shown else { return }
                shown = visible
                if visible { DockerModel.shared.show() } else { DockerModel.shared.hide() }
            }
    }

    /// Letters act on the list while its table has the keyboard; in the
    /// filter field they are text. SwiftUI's own key handling is macOS 14.
    func installDockerKeys() {
        dockerKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleDockerKey(event) else { return event }
            return nil
        }
        dockerPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusDockerList() }
            .store(in: &cancellables)
    }

    /// A key down: the list's when it has the keyboard and the key means
    /// something there (DockerKey), with no ⌘, ⌃ or ⌥ — those are menus'.
    func handleDockerKey(_ event: NSEvent) -> Bool {
        guard dockerListHasKeyboard(event), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let characters = event.characters
        else { return false }
        return dockerPage.press(characters)
    }

    /// The page shows in this window and its list — a table under it, not a
    /// text field's editor — is the first responder.
    func dockerListHasKeyboard(_ event: NSEvent? = nil) -> Bool {
        guard store.showingOverlay == .docker, event?.window ?? window === window, let page = dockerView,
            let table = window?.firstResponder as? NSTableView
        else { return false }
        return table.isDescendant(of: page)
    }

    func dockerSettingsChanged() {
        if !Settings.shared.dockerEnabled {
            closeOverlay(.docker)
            DockerModel.shared.stop()
        } else if DockerModel.shared.isWatching {
            // Another engine, maybe: nothing starts that wasn't started.
            DockerModel.shared.reconnect()
        }
    }

    /// A command in a new tab: compose in the project's folder, the rest
    /// in the selected tab's (or home).
    func runDockerCommand(_ command: String, in folder: URL?) {
        let directory =
            folder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? store.selected.flatMap { $0.workingDirectory.map { URL(fileURLWithPath: $0) } }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        newTab(in: directory, running: command)
    }

    func confirmDocker(_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { then() }
        }
    }

    /// A container's port: the browser column when links open inside
    /// (the page steps aside for it), else the default browser.
    func openDockerLink(_ url: URL) {
        guard BrowserLinks.opensInside(url, policy: Settings.shared.browserLinks), Settings.shared.browserEnabled else {
            NSWorkspace.shared.open(url)
            return
        }
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        openInBrowser(url, for: store.selected)
    }
}
