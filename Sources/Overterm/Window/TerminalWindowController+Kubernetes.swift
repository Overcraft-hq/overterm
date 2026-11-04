import AppKit
import Combine
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
        page.paletteItems = { [weak self] in self?.kubernetesPaletteItems() ?? [] }
        return page
    }

    /// The page declared, and its list given the keyboard when it asks.
    func wireKubernetesPage() {
        declarePage(kubernetesWorkspacePage())
        kubernetesPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusPageList(.kubernetes) }
            .store(in: &cancellables)
        // Offered: taken only when the window itself has it — nobody does.
        kubernetesPage.$offerList
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, let window = self.window, window.firstResponder === window || window.firstResponder == nil else { return }
                self.focusPageList(.kubernetes)
            }
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
        if held {
            KubernetesModel.shared.show()
            // The last hide dropped every selector: this page's filter asks again.
            kubernetesPage.applySelector()
        } else {
            KubernetesModel.shared.hide()
        }
    }

    /// Whether the window is on screen at all. An isolated run stays in the
    /// background, often under the user's own windows: there it counts as shown.
    func updateKubernetesWindowVisible() {
        guard !AppEnvironment.isIsolated, let window else { return }
        let shown = window.occlusionState.contains(.visible)
        if kubernetesPage.windowVisible != shown { kubernetesPage.windowVisible = shown }
    }

    func kubernetesWindowClosing() {
        releaseKubernetesSwitcher(now: true)
        kubernetesPage.visible = false
        guard kubernetesPageHeld else { return }
        kubernetesPageHeld = false
        KubernetesModel.shared.hide()
    }
}

// MARK: The switcher and the palette

extension TerminalWindowController {
    /// ⌃⌘J: the palette, on contexts, namespaces, kinds and the rows showing. The
    /// switcher looks as the page does: it holds the model while it shows,
    /// so the kubeconfig is read and the context's pods followed, and what
    /// it lists comes in as the cluster answers. With Kubernetes off, its
    /// settings.
    @objc func showKubernetesSwitcher(_ sender: Any?) {
        guard Settings.shared.kubernetesEnabled else { return openSettings(.kubernetes) }
        togglePalette(scope: .kubernetes)
        guard paletteView?.isHidden == false, palette.scope == .kubernetes, !kubernetesSwitcherHeld else { return }
        kubernetesSwitcherHeld = true
        KubernetesModel.shared.show()
    }

    /// The palette closed: the switcher's hold goes — after what was picked
    /// has opened the page, so the page's hold comes first and the watch
    /// runs on rather than starting again.
    func releaseKubernetesSwitcher(now: Bool = false) {
        guard kubernetesSwitcherHeld else { return }
        let release = { [weak self] in
            guard let self, self.kubernetesSwitcherHeld, self.paletteView?.isHidden != false else { return }
            self.kubernetesSwitcherHeld = false
            KubernetesModel.shared.hide()
        }
        if now {
            kubernetesSwitcherHeld = false
            KubernetesModel.shared.hide()
        } else {
            DispatchQueue.main.async(execute: release)
        }
    }

    /// What the switcher lists changed while the palette shows it.
    func watchKubernetesPalette() -> AnyCancellable {
        let model = KubernetesModel.shared
        return model.$contexts.dropFirst().map { _ in () }
            .merge(
                with: model.$namespaces.dropFirst().map { _ in () }, model.$rows.dropFirst().map { _ in () }, model.$scope.dropFirst().map { _ in () },
                model.$catalog.dropFirst().map { _ in () }
            )
            .sink { [weak self] _ in DispatchQueue.main.async { self?.restockPalette() } }
    }

    /// What the palette offers of Kubernetes: the page; every context of the
    /// kubeconfig once read; the context's namespaces; the kinds it serves,
    /// once discovery is read; and the rows of the kind shown while something
    /// looks at them (the page or the switcher) — never a list left from
    /// before: a page's `label:` goes when it hides, and one that shows in
    /// some window is said on each row. ↩ shows each on the page: a context
    /// or a namespace switched to, a kind shown, a row selected.
    func kubernetesPaletteItems() -> [PaletteItem] {
        guard Settings.shared.kubernetesEnabled else { return [] }
        let model = KubernetesModel.shared
        var items = [
            PaletteItem(
                id: "a.kubernetes", group: .action, title: "Kubernetes", subtitle: "Contexts, namespaces, every kind  ⌥⌘J", symbol: "steeringwheel"
            ) { [weak self] _, _ in self?.toggleKubernetesPage(nil) }
        ]
        guard model.contextsRead else { return items }
        items += model.contexts.contexts.map { context in
            let detail = [
                "Context", context.contextClass.title, context.isWritable ? "writable" : "read-only",
                context.name == model.selectedName ? "showing" : nil,
            ]
            return PaletteItem(
                id: "k.c.\(context.name)", group: .kubernetes, title: context.displayName,
                subtitle: detail.compactMap { $0 }.joined(separator: " · "), symbol: context.isProduction ? "exclamationmark.octagon" : "steeringwheel"
            ) { [weak self] _, _ in
                KubernetesModel.shared.select(context.name)
                self?.showKubernetesPage()
            }
        }
        guard let context = model.selected else { return items }
        let favourites = context.settings.favouriteNamespaces
        let own = context.settings.defaultNamespace ?? context.namespace
        var namespaces = favourites
        for name in [own].compactMap({ $0 }) + model.namespaces where !namespaces.contains(name) { namespaces.append(name) }
        items += namespaces.map { name in
            PaletteItem(
                id: "k.n.\(name)", group: .kubernetes, title: name,
                subtitle: "Namespace in \(context.displayName)" + (model.scope == .namespace(name) ? " · showing" : ""), symbol: "square.dashed"
            ) { [weak self] _, _ in
                KubernetesModel.shared.setScope(.namespace(name))
                self?.showKubernetesPage()
            }
        }
        let catalog = model.catalog
        items += KubeSection.allCases.flatMap { section in
            catalog.kinds(in: section).map { kind in
                let names = ([kind.resource] + kind.shortNames).map { ":" + $0 }.joined(separator: " ")
                return PaletteItem(
                    id: "k.k.\(kind.fullName)", group: .kubernetes, title: KubeKindCatalog.title(of: kind),
                    subtitle: "Kind · \(section.title) · \(names) · \(kind.groupVersion)", symbol: section.symbol
                ) { [weak self] _, _ in
                    self?.kubernetesPage.showKind(kind)
                    self?.showKubernetesPage()
                }
            }
        }
        guard model.isShown else { return items }
        let kind = model.kind
        let pods = kind.fullName == KubeResourceKind.pods.fullName
        let columns = model.rows.columns
        // A page showing somewhere asked with its filter: the rows are only those.
        let selected = model.labelSelector.map { ["label: \($0)"] } ?? []
        items += model.rows.sorted.map { row in
            let summary = pods ? KubePodSummary(row: row, columns: columns) : nil
            let status = summary.map { $0.isFailing ? ($0.exitReason ?? $0.status) : $0.status }
            return PaletteItem(
                id: pods ? "k.p.\(row.id.description)" : "k.o.\(kind.fullName)/\(row.id.description)", group: .kubernetes, title: row.id.name,
                subtitle: ([kind.kind.isEmpty ? kind.resource : kind.kind, status, row.id.namespace].compactMap { $0 } + [context.displayName] + selected)
                    .joined(separator: " · "),
                symbol: summary?.isFailing == true ? "exclamationmark.triangle" : pods ? "cube.box" : "doc.text"
            ) { [weak self] _, _ in self?.revealOnKubernetesPage(row.id, kind: kind) }
        }
        return items
    }

    /// The page, its list given the keyboard.
    func showKubernetesPage() {
        if store.showingOverlay != .kubernetes { showOverlay(.kubernetes) }
        focusPageList(.kubernetes)
    }

    /// The page, on the kind's list (Pods unless said), with this row
    /// selected and in view — the filter cleared when it hides it, or has a
    /// `label:` that may: the rows the switcher saw weren't asked for with it.
    func revealOnKubernetesPage(_ id: KubeRowID, kind: KubeResourceKind = .pods) {
        let page = kubernetesPage
        if KubernetesModel.shared.kind.fullName != kind.fullName || !page.showsSection { page.showKind(kind) }
        if page.labelReading.selector != nil || !page.rows.contains(where: { $0.row.id == id }) { page.filter = "" }
        page.selection = [id.description]
        showKubernetesPage()
    }
}
