import AppKit
import SwiftUI

// MARK: The Kubernetes page (⌥⌘J), as the window wires it (WorkspacePage)

extension TerminalWindowController {
    var kubernetesView: NSView? { pages.view(.kubernetes) }

    var kubernetesActions: KubernetesActions {
        KubernetesActions(
            run: { [weak self] command in self?.runDockerCommand(command, in: nil) },
            settings: { [weak self] in self?.openSettings(.kubernetes) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
    }

    func kubernetesWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.kubernetes)
        // Made the first time it opens.
        page.makeView = { [weak self] in
            guard let self, let theme = self.theme else { return nil }
            self.kubernetesPage.actions = self.kubernetesActions
            return NSHostingView(rootView: KubernetesPageView(page: self.kubernetesPage, model: .shared, theme: theme))
        }
        // The model reads only while a page shows it: the emitted value,
        // since `showingOverlay` isn't set yet.
        page.visibilityChanged = { [weak self] visible in
            self?.kubernetesPage.visible = visible
            self?.updateKubernetesPageHold(pageShowing: visible)
        }
        page.closed = { [weak self] in self?.kubernetesPage.selection = [] }
        page.hasList = true
        page.press = { [weak self] characters in self?.kubernetesPage.press(characters) ?? false }
        page.occlusionChanged = { [weak self] in
            self?.updateKubernetesWindowVisible()
            self?.updateKubernetesPageHold()
        }
        page.windowClosing = { [weak self] in self?.kubernetesWindowClosing() }
        return page
    }

    /// The page declared, and its list given the keyboard when it asks.
    func wireKubernetesPage() {
        declarePage(kubernetesWorkspacePage())
        kubernetesPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusPageList(.kubernetes) }
            .store(in: &cancellables)
    }

    /// View ▸ Kubernetes (⌥⌘J): the page, or back to the terminal from it.
    /// With Kubernetes off it opens on saying so, and reads nothing.
    @objc func toggleKubernetesPage(_ sender: Any?) {
        togglePage(.kubernetes)
    }

    /// The page shows in this window and its list has the keyboard.
    func kubernetesListHasKeyboard(_ event: NSEvent? = nil) -> Bool { pageListHasKeyboard(.kubernetes, event) }

    /// Holds `KubernetesModel.show()` while the page shows in a window on
    /// screen, and gives it back otherwise — and when the window closes:
    /// a page nobody sees watches no pods.
    func updateKubernetesPageHold(pageShowing: Bool? = nil) {
        let held = (pageShowing ?? (store.showingOverlay == .kubernetes)) && kubernetesPage.windowVisible
        guard held != kubernetesPageHeld else { return }
        kubernetesPageHeld = held
        if held { KubernetesModel.shared.show() } else { KubernetesModel.shared.hide() }
    }

    /// Whether the window is on screen at all. An isolated run stays in the
    /// background, often under the user's own windows: there it counts as shown.
    func updateKubernetesWindowVisible() {
        guard !AppEnvironment.isIsolated, let window else { return }
        let shown = window.occlusionState.contains(.visible)
        if kubernetesPage.windowVisible != shown { kubernetesPage.windowVisible = shown }
    }

    func kubernetesWindowClosing() {
        guard kubernetesPageHeld else { return }
        kubernetesPageHeld = false
        KubernetesModel.shared.hide()
    }
}
