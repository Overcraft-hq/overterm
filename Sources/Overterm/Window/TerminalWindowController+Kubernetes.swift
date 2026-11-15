import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
            },
            copySecret: { text in
                // nspasteboard.org's markers: clipboard managers that honour
                // them keep no history of it.
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item])
            },
            save: { [weak self] name, text in self?.saveKubernetesFile(name, text) },
            askAgent: { [weak self] text, about in self?.askAgent(aboutKubernetes: text, about) },
            openTerminal: { [weak self] context, namespace in self?.openKubernetesTerminal(context, namespace: namespace) },
            runInTab: { [weak self] command, context, namespace in self?.runKubernetesCommand(command, in: context, namespace: namespace) },
            runPodInTab: { [weak self] command, context, namespace, env in
                self?.runKubernetesCommand(command, in: context, namespace: namespace, podEnv: env)
            },
            confirm: { [weak self] title, detail, button, then in self?.confirmKubernetes(title, detail, button, then) },
            askText: { [weak self] title, detail, initial, then in
                self?.askForName(title: title, detail: detail, initial: initial, action: "OK") { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return "A path, please." }
                    then(trimmed)
                    return nil
                }
            },
            pickSave: { [weak self] name, then in
                guard let window = self?.window else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.prompt = "Copy Here"
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    MainActor.assumeIsolated { then(url) }
                }
            },
            pickOpen: { [weak self] message, then in
                guard let window = self?.window else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Copy"
                panel.message = message
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    MainActor.assumeIsolated { then(url) }
                }
            },
            choose: { [weak self] title, detail, buttons, then in self?.chooseDocker(title, detail, buttons, then) },
            openURL: { [weak self] url in self?.openDockerLink(url) },
            currentTab: { [weak self] in self?.store.selected?.id },
            openExternal: { [weak self] url in self?.openKubernetesExternally(url) },
            openDatabase: { [weak self] guess in self?.newDatabaseConnection(from: guess) },
            runLocally: { [weak self] spec in self?.runOnDockerPage(spec) },
            scanImage: { [weak self] image, origin in self?.scanOnDockerPage(image, from: origin) },
            importAPI: { [weak self] source in self?.importForwardAPI(source) },
            askWhy: { [weak self] brief in self?.presentKubernetesBrief(brief) },
            selectedBinding: { [weak self] in KubeBindingStore.shared.binding(for: self?.kubernetesCheckout) },
            confirmWrite: { [weak self] confirmation, then in self?.confirmKubernetesWrite(confirmation, then) },
            openEditor: { [weak self] url in self?.openKubernetesEdit(url) },
            openResource: { [weak self] resource in self?.openKubernetesResource(resource) },
            showChange: { [weak self] change in self?.showKubernetesChange(change) },
            snippets: { [weak self] in Settings.shared.snippetsEnabled ? self?.snippets.snippets ?? [] : [] },
            fillSnippet: { [weak self] snippet, then in self?.fillKubernetesSnippet(snippet, then) },
            expandChart: { [weak self] chart in self?.showKubernetesExpandedChart(chart) },
            checkouts: { [weak self] in
                guard let self else { return [] }
                // The selected tab's first, then the window's others.
                return ([store.selected] + store.tabs).compactMap { $0?.checkoutSource?.root }
            },
            openReview: { [weak self] source, root in self?.openReview(source, in: root) })
    }

    /// A Metrics tab's chart alone in the right-hand pane (metrics.md 2.1,
    /// M9) — the slot the browser shares, so it steps aside (`RightSlot`) —
    /// and the page steps aside so it shows beside the terminal. The slot
    /// is on screen before the page hides: the tab's reads go on for it
    /// without a pause.
    func showKubernetesExpandedChart(_ chart: KubeExpandedChart) {
        kubernetesManifest.show(chart)
        rightPane.manifestOpened = true
        rightPane.mode = .manifest
        // A zoomed column hides the slot: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
        // Beside the terminal, which has the keyboard again.
        if store.showingOverlay != nil { hideOverlay() }
    }

    /// A key or a click in this window while its expanded chart reads with
    /// the page hidden: Live's idle time starts again (metrics.md 3.5,
    /// "without input in the window") — the terminal typed in beside the
    /// chart is the input that matters, and the page's own keys no longer see it.
    func noteKubernetesWindowInput(_ event: NSEvent) {
        guard event.window === window, kubernetesPage.holdsChartsForExpansion else { return }
        kubernetesPage.noteMetricsInput()
    }

    /// "Show in Kubernetes" from the slot: the page, on the chart's object's Metrics tab.
    func showKubernetesExpandedSource(_ chart: KubeExpandedChart) {
        kubernetesPage.showExpandedChartSource(chart)
        showKubernetesPage()
    }

    /// A Kubernetes snippet's own `{{…}}`, asked for as Snippets asks;
    /// none, it goes straight on.
    func fillKubernetesSnippet(_ snippet: Snippet, _ then: @escaping (String) -> Void) {
        guard !snippet.placeholders.isEmpty else { return then(snippet.command) }
        presentSheet { close in
            SnippetFillView(
                snippet: snippet,
                onUse: { command, _ in
                    close()
                    then(command)
                },
                onCancel: close)
        }
    }

    /// A workload's change, its diff masked, in the right-hand pane where a
    /// manifest's diff shows — the page steps aside so it can be read.
    func showKubernetesChange(_ change: KubeChangeDiff) {
        kubernetesManifest.show(change)
        rightPane.manifestOpened = true
        rightPane.mode = .manifest
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        // A zoomed column hides the slot: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// A template's copy in the editor, the page stepping aside.
    func openKubernetesEdit(_ url: URL) {
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        openInEditor(url)
    }

    /// `y`: an object's YAML — the YAML tab's buffer, the same edits — in
    /// the window's editor, the page stepping aside.
    func openKubernetesResource(_ resource: KubeResourceBuffer) {
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        openInEditor(resource.url)
    }

    /// A write asked first (rule 3), in the one confirmation every write
    /// takes (`WriteConfirmation`): the confirmation's words, the context
    /// and namespace — red on production —, its button and Cancel, and —
    /// where rule 4 asks it — a field for the object's name. What was typed
    /// goes back to the page, which checks it; Cancel sends nothing.
    func confirmKubernetesWrite(_ confirmation: KubeWriteConfirmation, _ then: @escaping (KubeWriteAnswer) -> Void) {
        guard let window else { return }
        WriteConfirmation(
            title: confirmation.title, scope: confirmation.scope, production: confirmation.production, detail: confirmation.detail,
            button: confirmation.button, typedName: confirmation.typedName, image: confirmation.image,
            critical: confirmation.production || confirmation.typedName != nil
        ).presentAnswer(on: window, then: then)
    }

    /// The page's other asks (production's switch, a shell on production):
    /// the same sheet, a production scope on its first line drawn red.
    func confirmKubernetes(_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) {
        guard let window else { return }
        WriteConfirmation.splittingProduction(title: title, detail: detail, button: button).present(on: window) { _ in then() }
    }

    /// The typed-name field's identifier, for the scenario.
    static let kubernetesTypedNameField = WriteConfirmation.typedNameField

    /// Run Locally (3.12): the Docker page over the body, its Run window
    /// filled in from the pod — Run in a Tab is the user's press.
    func runOnDockerPage(_ spec: DockerRunSpec) {
        guard Settings.shared.dockerEnabled else { return openSettings(.docker) }
        if store.showingOverlay != .docker { showOverlay(.docker) }
        dockerPage.runSpec = spec
    }

    /// Scan (3.12): the Docker page's Images, the image's Vulnerabilities
    /// tab, scanned — asked first when the engine hasn't got it.
    func scanOnDockerPage(_ image: KubeRunLocally.Image, from origin: String) {
        guard Settings.shared.dockerEnabled else { return openSettings(.docker) }
        if store.showingOverlay != .docker { showOverlay(.docker) }
        dockerPage.scanImage(named: image.name, digest: image.digest, from: origin)
        focusDockerList()
    }

    /// An Ingress's host, in the default browser. An isolated run opens
    /// nothing of the user's: it records what it would have opened.
    func openKubernetesExternally(_ url: URL) {
        if AppEnvironment.isIsolated {
            kubernetesOpenedExternally.append(url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// A forward's OpenAPI document, imported on a press as the API
    /// panel imports a tab's server: into the checkout's collection, its
    /// first request opened — the panel on screen, saying what went wrong.
    func importForwardAPI(_ source: APIDiscovery.Source) {
        showAPIClient(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let imported = try await self.apiWorkspace.importSource(source)
                self.kubernetesPage.commandProblem = nil
                if self.store.showingOverlay != nil { self.hideOverlay(focus: false) }
                if let first = imported.firstRequest { self.openInEditor(first) }
            } catch {
                self.kubernetesPage.commandProblem = "Couldn't import \(source.title): \(error.localizedDescription)"
                guard !AppEnvironment.isIsolated, let window = self.window else { return }
                NSAlert(error: error).beginSheetModal(for: window) { _ in }
            }
        }
    }

    // MARK: Port-forwards (docs/design/kubernetes/analysis.md, 3.8)

    /// Each tab's forwards as pills in its panes' headers (and in Tab Info,
    /// the browser column's empty page): the app's forwards that tab asked
    /// for, kept as they change — the emitted list, since `forwards` isn't
    /// set yet.
    func followKubernetesForwards() {
        KubeForwards.shared.$forwards
            .sink { [weak self] forwards in
                DispatchQueue.main.async { self?.updateForwardPorts(forwards) }
            }
            .store(in: &cancellables)
        // What a forward's server publishes: offered by the API client (3.8).
        KubeForwards.shared.$openAPI
            .sink { [weak self] found in
                let sources = found.values.sorted { $0.id < $1.id }
                DispatchQueue.main.async {
                    guard let self, self.apiWorkspace.forwardSources != sources else { return }
                    self.apiWorkspace.forwardSources = sources
                }
            }
            .store(in: &cancellables)
    }

    func updateForwardPorts(_ forwards: [KubeForward] = KubeForwards.shared.forwards) {
        for tab in store.tabs {
            let ports = forwards.filter { $0.spec.tab == tab.id }.compactMap(\.listeningPort)
            if tab.forwardPorts != ports { tab.forwardPorts = ports }
        }
    }

    /// A forward's pill's Kubernetes: the page's Forwards section.
    func showKubernetesForwards() {
        kubernetesPage.showForwards()
        showKubernetesPage()
    }

    /// The page on its Helm section (the palette's Kubernetes Helm Releases).
    func showKubernetesHelm() {
        kubernetesPage.showSection(.helm)
        showKubernetesPage()
    }

    /// The Overview section: what fails, usage, counts, applications.
    func showKubernetesOverview() {
        kubernetesPage.showSection(.overview)
        showKubernetesPage()
    }

    // MARK: Terminal in this context (docs/design/kubernetes/analysis.md, 3.11)

    /// A tab pinned to `context`: its shell's `KUBECONFIG` starts with a
    /// file of Overterm's naming the context (and `namespace`, else the
    /// context's own), then exactly Overterm's kubeconfig files — so a
    /// plain `kubectl` there goes to it, and the user's current context is
    /// never changed. It opens in the context's `terminalDirectory`, else
    /// the home folder. It is the user's own kubectl: on production it is
    /// asked first, naming the context, and its pane carries the red band.
    func openKubernetesTerminal(_ context: KubeContext, namespace: String? = nil) {
        let pin = KubeTerminalPin(context, namespace: namespace)
        guard context.isProduction else { return startKubernetesTerminal(context, pin) }
        let scope = pin.namespace.map { ", namespace \($0)" } ?? ""
        confirmDocker(
            "Open a terminal pinned to production?",
            "A plain kubectl, helm or k9s in the new tab goes to \(context.name)\(scope) — with your own credentials and rights. "
                + "Nothing Overterm checks reaches into a terminal. Your current context stays as it is.",
            "Open Terminal in \(context.displayName)"
        ) { [weak self] in self?.startKubernetesTerminal(context, pin) }
    }

    /// A pod's command (`KubeCommands`: a shell, attach, a log followed) in a
    /// new tab pinned to `context` and `namespace` as Terminal in this
    /// context pins one — so what is typed there after it ends goes there
    /// too. Whatever confirming it needed (on production a shell, an
    /// attach, a log followed) was asked before. A scenario's recorder gets the command and the tab instead
    /// of the command being typed.
    /// `podEnv`: the pod's plain env values, when the command is a pod's
    /// own (a shell, attach, a log followed) — what ⌘L in its tab scrubs.
    func runKubernetesCommand(_ command: String, in context: KubeContext, namespace: String, podEnv: [(key: String, value: String)] = []) {
        startKubernetesTerminal(context, KubeTerminalPin(context, namespace: namespace), running: command, podEnv: podEnv)
    }

    private func startKubernetesTerminal(
        _ context: KubeContext, _ pin: KubeTerminalPin, running command: String? = nil, podEnv: [(key: String, value: String)] = []
    ) {
        let extra = Settings.shared.kubernetesKubeconfigs
        let home = FileManager.default.homeDirectoryForCurrentUser
        // The checkout bound to the context (3.11): the selected tab's when it is, else the first.
        let bound = KubeBindingStore.shared.bindings(on: context.name, namespace: nil)
        let selected = kubernetesPanel.binding.flatMap { $0.context == context.name ? $0 : nil }
        let checkout = (selected ?? bound.first).map { URL(fileURLWithPath: $0.checkout, isDirectory: true) }
        let directory = KubeTerminalDirectory.choose(setting: context.settings.terminalDirectory, checkout: checkout, home: home)
        Task { @MainActor [weak self] in
            // The files are the proxies' list; blocking the first time (the shell is asked).
            let files = await KubeBlocking.run { AppEnvironment.kubeconfigs(extra: extra) }
            guard let self else { return }
            do {
                let ready = try KubeTerminalLaunch.prepare(pin, kubeconfigs: files)
                self.kubernetesPage.terminalProblem = nil
                if self.store.showingOverlay != nil { self.hideOverlay(focus: false) }
                let recorder = command == nil ? nil : self.kubernetesCommandRecorder
                // The pin's KUBECONFIG on the line itself: the shell's startup
                // files may export another, and `--context` means what it names.
                let typed = command.map { KubeTerminalLaunch.pinnedLine($0, environment: ready.environment) ?? $0 }
                let tab = self.newTab(in: directory, environment: ready.environment, kubePin: ready.pin, running: recorder == nil ? typed : nil)
                tab?.terminal.kubePodEnv = podEnv
                if let recorder, let typed, let tab { recorder(typed, tab) }
            } catch {
                self.kubernetesPage.terminalProblem = "\(error)"
                guard !AppEnvironment.isIsolated, let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = "Overterm couldn't open a terminal in \(context.displayName)"
                alert.informativeText = "\(error)"
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    /// Overterm's kubeconfigs as they are now, for a saved session's pinned
    /// panes (`KubeTerminalRestore`): the proxies' list — guarded, only
    /// OVERTERM_KUBECONFIG's — and its contexts with the current settings.
    /// Blocking the first time (the shell is asked), at launch, and only
    /// when a saved pane was pinned: its shell can't start before its
    /// `KUBECONFIG` is known.
    static func kubernetesRestoreList() -> (files: [URL], list: KubeContextList) {
        let files = AppEnvironment.kubeconfigs(extra: Settings.shared.kubernetesKubeconfigs)
        return (files, KubeContextList.load(files: files, settings: Settings.shared.kubernetesContexts, guarded: AppEnvironment.guardsKubeconfig))
    }

    /// The pin a pane is saved with: the one it has, else the one it lost
    /// (tried again on the next launch). Never neither for a pinned pane.
    static func savedKubePin(_ pane: TerminalView) -> KubeTerminalPin? {
        pane.kubePin ?? pane.kubePinLost?.pin
    }

    /// Each pinned pane's label and band follow what its plain kubectl
    /// reaches now (`KubeTerminalFollow`): read again when a pin's file
    /// changes (a `use-context` or `set-context` typed in the pane rewrites
    /// it) and when the contexts change (a class set in Settings). Started
    /// by the first pinned pane; called again, it reads every pin once.
    func followKubernetesPins() {
        if kubePinWatcher == nil {
            let folder = KubeTerminalFiles.defaultFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            kubePinWatcher = DirectoryWatcher(root: folder, latency: 0.2) { [weak self] _ in self?.readKubernetesPins() }
            kubePinContexts = KubernetesModel.shared.$contexts.dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.readKubernetesPins() }
        }
        readKubernetesPins()
    }

    /// Every pinned pane's files read as kubectl merges them, off the main
    /// thread; a pane whose answer changed shows it, and its tab is saved.
    func readKubernetesPins() {
        let panes = store.tabs.flatMap { tab in tab.terminals.filter { $0.kubePin != nil }.map { (tab, $0) } }
        guard !panes.isEmpty else { return }
        let work = panes.map { (_, pane) in (KubeTerminalFollow.files(of: pane.environment["KUBECONFIG"]), pane.kubePin!) }
        let settings = Settings.shared.kubernetesContexts
        let guarded = AppEnvironment.guardsKubeconfig
        Task { @MainActor [weak self] in
            let followed = await KubeBlocking.run {
                work.map { files, was in
                    KubeTerminalFollow.pin(from: KubeContextList.load(files: files, settings: settings, guarded: guarded), was: was, settings: settings)
                }
            }
            guard self != nil else { return }
            for ((tab, pane), pin) in zip(panes, followed) where pane.kubePin != nil && pane.kubePin != pin {
                pane.kubePin = pin
                tab.objectWillChange.send()
            }
        }
    }

    /// A file the page made (the list as CSV), where the user says. An
    /// isolated run shows no panel: it writes into its own folder
    /// (`kubernetesExportFolder`), where the scenario reads it. A write
    /// that fails is said — an alert on the window, and the page's
    /// `exportProblem`, which a scenario checks — never a place picked and
    /// no file.
    func saveKubernetesFile(_ name: String, _ text: String) {
        if AppEnvironment.isIsolated {
            let folder = Self.kubernetesExportFolder
            writeKubernetesFile(text, to: folder.appendingPathComponent(name), alert: false) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            return
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: (name as NSString).pathExtension) ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeKubernetesFile(text, to: url, alert: true)
        }
    }

    private func writeKubernetesFile(_ text: String, to url: URL, alert: Bool, before: () throws -> Void = {}) {
        do {
            try before()
            try text.write(to: url, atomically: true, encoding: .utf8)
            kubernetesPage.exportProblem = nil
        } catch {
            kubernetesPage.exportProblem = error.localizedDescription
            if alert, let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    /// Lines of a pod's log, already scrubbed (`KubernetesPageModel.askAboutLogLines`):
    /// the Ask Agent sheet, the window's agents offered, a new one in the
    /// selected tab's folder.
    func askAgent(aboutKubernetes text: String, _ about: AskAgentModel.Part) {
        guard window?.attachedSheet == nil else { return NSSound.beep() }
        let agents = store.tabs.filter { $0.agent != nil }
        presentAskAgent(text: text, command: nil, folder: store.selected?.workingDirectory, targets: agents, parts: [about])
    }

    /// Ask Why's brief (`KubeAgentBriefing`, scrubbed): the Ask Agent sheet
    /// with the whole brief shown before it is sent. The agent offered
    /// first is the one in a tab of the checkout bound to the brief's
    /// namespace (3.4: it has the code that failed), else the selected
    /// tab's — the one under the page — then the window's others, or a new
    /// one in the bound checkout (else the selected tab's folder). No git
    /// diff is offered: the sheet shows the whole of what is sent.
    func presentKubernetesBrief(_ brief: KubeAgentBrief, preferring marked: Tab? = nil) {
        guard window?.attachedSheet == nil else { return NSSound.beep() }
        let folder = brief.checkout ?? store.selected?.workingDirectory
        // A mark's Ask Why: that tab's own agent before the checkout's others.
        var targets = kubernetesBriefTargets(brief)
        if let marked, marked.agent != nil {
            targets.removeAll { $0 === marked }
            targets.insert(marked, at: 0)
        }
        presentAskAgent(
            text: brief.text, command: nil, folder: folder, targets: targets, message: brief.message, subject: brief.subject,
            parts: brief.parts, diff: false, showsBrief: true)
    }

    /// Where an isolated run's exports go: its own support folder.
    static var kubernetesExportFolder: URL { AppEnvironment.supportDirectory.appendingPathComponent("Exports", isDirectory: true) }

    /// File ▸ Export Kubernetes List as CSV…: the page's list, while it shows.
    @objc func exportKubernetesList(_ sender: Any?) {
        guard store.showingOverlay == .kubernetes else { return }
        kubernetesPage.exportCSV()
    }

    func kubernetesWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.kubernetes)
        // Made the first time it opens.
        page.makeView = { [weak self] in
            guard let self, let theme = self.theme else { return nil }
            self.kubernetesPage.actions = self.kubernetesActions
            self.kubernetesPage.makeYAMLEditor = { [weak self] in
                let runtime = GhosttyRuntime.shared
                let editor = EditorViewController(
                    theme: theme, background: runtime.backgroundColor, foreground: runtime.foregroundColor, opener: self?.opener ?? ExternalOpener(),
                    embedded: true)
                editor.kubernetesHost = self
                return editor
            }
            return NSHostingView(rootView: KubernetesPageView(page: self.kubernetesPage, model: .shared, theme: theme))
        }
        // The model reads only while a page shows it: the emitted value,
        // since `showingOverlay` isn't set yet.
        page.visibilityChanged = { [weak self] visible in
            self?.kubernetesPage.visible = visible
            self?.updateKubernetesPageHold(pageShowing: visible)
        }
        page.closed = { [weak self] in
            self?.kubernetesPage.closeDetail()
            self?.kubernetesPage.selection = []
        }
        page.hasList = true
        page.press = { [weak self] characters in self?.kubernetesPage.press(characters) ?? false }
        page.commandPress = { [weak self] characters in self?.kubernetesPage.commandPress(characters) ?? false }
        // ⌘L over the page: Ask Why on the pod or Deployment shown or
        // picked (lines picked in a log answer it themselves).
        page.askAboutSelection = { [weak self] in self?.kubernetesPage.askWhy() ?? false }
        page.occlusionChanged = { [weak self] in
            self?.updateKubernetesWindowVisible()
            self?.updateKubernetesPageHold()
            self?.updateKubernetesPanelVisibility()
            self?.updateTerraformPanelVisibility()
        }
        page.windowClosing = { [weak self] in self?.kubernetesWindowClosing() }
        page.paletteItems = { [weak self] in self?.kubernetesPaletteItems() ?? [] }
        return page
    }

    /// The page declared, and its list given the keyboard when it asks.
    func wireKubernetesPage() {
        declarePage(kubernetesWorkspacePage())
        // What the manifest pane shows decides whether an expanded chart reads: after it lands.
        kubernetesManifest.$shown.combineLatest(kubernetesManifest.$chart.map { $0?.id })
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateRightPaneVisibility() } }
            .store(in: &cancellables)
        followKubernetesForwards()
        followEditorOnScreen()
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
        // Nothing followed or held for views that are going: a cluster
        // object's edits stay with the registry, which the quit asks about.
        kubernetesPage.detail?.cancel()
        kubernetesPage.madeYAMLEditor?.showOnly(nil)
        editor?.releaseResources()
        releaseKubernetesSwitcher(now: true)
        kubernetesPanel.panelVisible = false
        // The expanded chart let go, not only marked off screen: a layout pass after can't bring its reads back.
        kubernetesPage.expandedChartWindowClosing()
        kubernetesManifest.dropChart()
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
        let release: @MainActor @Sendable () -> Void = { [weak self] in
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

    /// What the switcher lists changed while the palette shows it — the
    /// forwards too: one started or stopped, its server's API found.
    func watchKubernetesPalette() -> AnyCancellable {
        let model = KubernetesModel.shared
        let forwards = KubeForwards.shared
        return model.$contexts.dropFirst().map { _ in () }
            .merge(
                with: model.$namespaces.dropFirst().map { _ in () }, model.$rows.dropFirst().map { _ in () }, model.$scope.dropFirst().map { _ in () },
                model.$catalog.dropFirst().map { _ in () }
            )
            .merge(with: forwards.$forwards.dropFirst().map { _ in () }, forwards.$openAPI.dropFirst().map { _ in () })
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
            ) { [weak self] _, _ in self?.toggleKubernetesPage(nil) },
            PaletteItem(
                id: "a.kubernetes.overview", group: .action, title: "Kubernetes Overview",
                subtitle: "What fails, usage, workload counts, applications  \(KubeSection.overview.key)", symbol: "gauge.with.dots.needle.33percent"
            ) { [weak self] _, _ in self?.showKubernetesOverview() },
            PaletteItem(
                id: "a.kubernetes.forwards", group: .action, title: "Kubernetes Forwards",
                subtitle: "The port-forwards: open, edit, stop  \(KubeSection.forwards.key)", symbol: "arrow.left.arrow.right"
            ) { [weak self] _, _ in self?.showKubernetesForwards() },
            PaletteItem(
                id: "a.kubernetes.helm", group: .action, title: "Kubernetes Helm Releases",
                subtitle: "Releases, their history, values and manifest — masked  \(KubeSection.helm.key)", symbol: "shippingbox"
            ) { [weak self] _, _ in self?.showKubernetesHelm() },
            PaletteItem(
                id: "a.kubernetes.explain", group: .action, title: "Kubernetes Explain…",
                subtitle: "A kind's fields as kubectl explain says them, from the cluster's own API docs", symbol: "book"
            ) { [weak self] _, _ in self?.showKubernetesExplain() },
        ]
        items += kubernetesPage.forwardPaletteItems { [weak self] in self?.showKubernetesPage() }
        items += kubernetesTemplateItems()
        guard model.contextsRead else { return items }
        items += kubernetesSavedFilterItems(model)
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
        // Terminal in this context, for each: the user's own kubectl, pinned.
        items += model.contexts.contexts.map { context in
            PaletteItem(
                id: "k.t.\(context.name)", group: .kubernetes, title: "Terminal in \(context.displayName)",
                subtitle: "A tab whose plain kubectl goes to this context"
                    + (context.isProduction ? " · PRODUCTION, asked first" : "") + " · your current context unchanged",
                symbol: "helm"
            ) { [weak self] _, _ in
                let namespace = context.name == model.selectedName ? self?.kubernetesPage.shownNamespace : nil
                self?.openKubernetesTerminal(context, namespace: namespace)
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
                subtitle: "Namespace in \(context.displayName)" + (model.scope.names?.contains(name) == true ? " · showing" : ""), symbol: "square.dashed"
            ) { [weak self] _, _ in
                KubernetesModel.shared.setScope(.namespace(name))
                self?.showKubernetesPage()
            }
        }
        items += kubernetesPageCommands()
        let catalog = model.catalog
        items += KubeSection.allCases.flatMap { section in
            catalog.kinds(in: section).map { kind in
                let names = ([kind.resource] + kind.shortNames).map { ":" + $0 }.joined(separator: " ")
                return PaletteItem(
                    id: "k.k.\(kind.fullName)", group: .kubernetes, title: "Go to \(KubeKindCatalog.title(of: kind))",
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
        let selected = model.selectors.said.map { [$0] } ?? []
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

    /// The page's own commands, while it shows in this window: what its
    /// keys do, findable by name — the pickers, `:`, Copy as kubectl, the
    /// CSV, wide and all namespaces.
    func kubernetesPageCommands() -> [PaletteItem] {
        guard store.showingOverlay == .kubernetes, KubernetesModel.shared.selected != nil else { return [] }
        let page = kubernetesPage
        func command(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ run: @escaping @MainActor (KubernetesPageModel) -> Void)
            -> PaletteItem
        {
            PaletteItem(id: "k.a.\(id)", group: .action, title: title, subtitle: subtitle, symbol: symbol) { [weak self] _, _ in
                guard let self else { return }
                self.showKubernetesPage()
                run(self.kubernetesPage)
            }
        }
        var items = [
            command("context", "Kubernetes: Switch Context…", "The context picker  c", "steeringwheel") { $0.openPicker(.context) },
            command("namespace", "Kubernetes: Switch Namespace…", "The namespace picker  n", "square.dashed") { $0.openPicker(.namespace) },
            command("command", "Kubernetes: Go to Kind…", "The command bar  :  — :deploy, :po shop, :svc @fake-dev", "chevron.right") { $0.openCommand() },
            command("allNamespaces", "Kubernetes: All Namespaces", "0", "square.grid.2x2") { $0.model.setScope(.all) },
            command("gitops", "Kubernetes: GitOps", "Argo CD's and Flux's objects in or deploying into the scope  g  —  :gitops, :argo, :flux", "arrow.triangle.branch") {
                $0.showSection(.gitops)
            },
            command("wide", page.wide ? "Kubernetes: Default Columns" : "Kubernetes: Wide Columns", "w", "rectangle.split.3x1") { $0.wide.toggle() },
            command("terminal", "Kubernetes: Terminal in This Context", "A tab whose plain kubectl goes to the context shown", "helm") {
                $0.openTerminal()
            },
        ]
        // The writes, findable by name: each by the guard path, as its key.
        // A context that takes none says why when one is picked.
        items.append(
            command("newNamespace", "Kubernetes: New Namespace…", "N  —  a name, then asked first; on a writable context", "plus.square.dashed") {
                $0.openNamespaceSheet()
            })
        if let target = page.writeTarget {
            let object = KubeWriteOutcome.spoken(target)
            let writes = page.writeVerbs(for: target).map { ($0, $0.title.replacingOccurrences(of: "…", with: "") + " " + object) }
            // Drain, Roll Back, Debug: `Drain node fake-node-1 in a Tab`.
            let tabWrites = page.tabWriteVerbs(for: target).map { ($0, ($0.label ?? $0.title) + " " + object + " in a Tab") }
            // Copy Out, Copy In: `Copy In pod shop/web-7d9 in a Tab`.
            let copies = page.podFileVerbs(for: target).map { ($0, ($0.label ?? $0.title) + " " + object + " in a Tab") }
            // Run Locally, Scan: `Scan pod shop/web-7d9 on Docker`.
            for verb in page.dockerVerbs(for: target) where verb.unavailable == nil {
                let name = (verb.label ?? verb.title) + " " + object + " on Docker"
                items.append(
                    PaletteItem(
                        id: "k.d.\(name).\(target)", group: .action, title: "Kubernetes: \(name)…",
                        subtitle: "The Docker page — nothing runs or is scanned until you say", symbol: verb.symbol
                    ) { [weak self] _, _ in
                        self?.showKubernetesPage()
                        verb.perform()
                    })
            }
            for (verb, name) in writes + tabWrites + copies where verb.unavailable == nil {
                items.append(
                    PaletteItem(
                        id: "k.w.\(name).\(target)", group: .action, title: "Kubernetes: \(name)…",
                        subtitle: (verb.key.map { "\($0)  —  " } ?? "") + "asked first, naming \(target.context)", symbol: verb.symbol
                    ) { [weak self] _, _ in
                        self?.showKubernetesPage()
                        verb.perform()
                    })
            }
        }
        // The GitOps section's rows, by name: each opens in its kind's list.
        items += page.gitOpsPaletteItems { [weak self] in self?.showKubernetesPage() }
        // The Helm section's release: Roll Back and Uninstall, by the same path.
        if page.section == .helm, let release = page.helmPicked, let context = page.helmContext {
            for verb in page.helmWriteVerbs(for: release) where verb.unavailable == nil {
                let name = (verb.label ?? verb.title) + " Helm Release \(release.namespace)/\(release.name) in a Tab"
                items.append(
                    PaletteItem(
                        id: "k.h.\(name).\(context.name)", group: .action, title: "Kubernetes: \(name)…",
                        subtitle: (verb.key.map { "\($0)  —  " } ?? "") + "asked first, naming \(context.name)", symbol: verb.symbol
                    ) { [weak self] _, _ in
                        self?.showKubernetesPage()
                        verb.perform()
                    })
            }
        }
        if !page.filter.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(
                command("saveFilter", "Kubernetes: Save This Filter", "“\(page.filter)” on \(KubernetesModel.shared.selectedName ?? "")", "bookmark") {
                    $0.saveFilter()
                })
        }
        if let line = page.copyTarget {
            items.append(command("copyKubectl", "Kubernetes: Copy as kubectl", "k  —  \(line)", "terminal") { $0.copyKubectl() })
        }
        if page.canExport {
            let rows = page.selection.isEmpty ? "The visible rows" : "The selected rows"
            items.append(command("copyTSV", "Kubernetes: Copy Rows as TSV", rows + ", for a spreadsheet", "tablecells") { $0.copyRows(.tsv) })
            items.append(command("copyCSV", "Kubernetes: Copy Rows as CSV", rows, "tablecells") { $0.copyRows(.csv) })
            items.append(command("exportCSV", "Kubernetes: Export List as CSV…", page.csvFileName, "square.and.arrow.up") { $0.exportCSV() })
        }
        return items
    }

    /// View ▸ Terminal in Kubernetes Context…: the switcher on its
    /// Terminal in items — the kubeconfig read, if it wasn't.
    @objc func openKubernetesTerminalPicker(_ sender: Any?) {
        guard Settings.shared.kubernetesEnabled else { return openSettings(.kubernetes) }
        if paletteView?.isHidden != false || palette.scope != .kubernetes { showKubernetesSwitcher(sender) }
        palette.query = "Terminal in "
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
        if !page.selectorReading.selectors.isEmpty || !page.rows.contains(where: { $0.row.id == id }) { page.filter = "" }
        page.selection = [id.description]
        showKubernetesPage()
    }
}

// MARK: A manifest in the editor, against its cluster (stage 2b)

extension TerminalWindowController: KubeManifestHost {
    /// An apply asked as every write is (`WriteConfirmation`): its scope red
    /// on production, the dry-run diff and the owners in its detail, the
    /// name typed where asked. An isolated run with no window answers no.
    func askManifestWrite(_ confirmation: KubeWriteConfirmation) async -> String? {
        guard let window else { return nil }
        return await WriteConfirmation(
            title: confirmation.title, scope: confirmation.scope, production: confirmation.production, detail: confirmation.detail,
            button: confirmation.button, typedName: confirmation.typedName, critical: confirmation.production || confirmation.typedName != nil
        ).ask(on: window)
    }

    /// Said on the page: the copy's tab is gone, and the bar with it.
    func manifestTemplateApplied(_ said: String) {
        kubernetesPage.writeStatus = .done(said + " The template's copy is closed: nothing typed in it is kept.")
    }

    func askManifest(_ title: String, _ detail: String, _ button: String) async -> Bool {
        guard let window else { return false }
        return await WriteConfirmation.splittingProduction(title: title, detail: detail, button: button).ask(on: window) != nil
    }

    /// The diff in the right-hand pane — the slot the browser shares, so it
    /// steps aside as it does for the changes pane.
    func showManifestDiff(_ session: KubeManifestSession) {
        // The detail's YAML tab on screen: its diff there — this pane is under the page.
        if store.showingOverlay == .kubernetes, let resource = session.resource, kubernetesPage.detail?.resource === resource,
            kubernetesPage.detailTab == .yaml
        {
            resource.showsDiff = true
            return
        }
        kubernetesManifest.session = session
        kubernetesManifest.showsHelm = false
        rightPane.manifestOpened = true
        rightPane.mode = .manifest
        // A zoomed column hides the slot: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// `kubectl explain` from the cluster's docs, in the same pane (3.15).
    func showExplain(_ session: KubeExplainSession) {
        kubernetesManifest.explain = session
        kubernetesManifest.shown = .explain
        rightPane.manifestOpened = true
        rightPane.mode = .manifest
        // A zoomed column hides the slot: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// The explain view on the page's context: nothing read until Explain is pressed.
    @discardableResult
    func showKubernetesExplain(_ query: String = "") -> KubeExplainSession {
        let session = KubeExplainSession(query: query, context: KubernetesModel.shared.selectedName, model: .shared)
        showExplain(session)
        return session
    }
}

// MARK: New Task pinned to a context (docs/design/kubernetes/analysis.md, 3.11)

extension TerminalWindowController {
    /// What New Task offers: Overterm's contexts but production, the
    /// repository's bound one first (`KubeTaskPin`). Read off the main thread.
    static func kubernetesTaskOffer(for repo: URL) async -> KubeTaskPin.Offer {
        let extra = Settings.shared.kubernetesKubeconfigs
        let settings = Settings.shared.kubernetesContexts
        let list = await KubeBlocking.run { KubeContextList.load(files: AppEnvironment.kubeconfigs(extra: extra), settings: settings, guarded: AppEnvironment.guardsKubeconfig) }
        return KubeTaskPin.offer(list, binding: KubeBindingStore.shared.binding(for: repo))
    }

    /// The task's pin, checked — the context read again: gone, or
    /// production now, it is refused —, nothing written yet: its file is
    /// written once the worktree is made (`KubeTerminalLaunch.prepare`), so
    /// a task that fails leaves no pin behind. The namespace is the
    /// repository's binding's on it, else the context's own.
    func kubernetesTaskPin(_ name: String, repo: URL) async throws -> (pin: KubeTerminalPin, kubeconfigs: [URL]) {
        let extra = Settings.shared.kubernetesKubeconfigs
        let settings = Settings.shared.kubernetesContexts
        let (files, list) = await KubeBlocking.run {
            let files = AppEnvironment.kubeconfigs(extra: extra)
            return (files, KubeContextList.load(files: files, settings: settings, guarded: AppEnvironment.guardsKubeconfig))
        }
        if let refused = KubeTaskPin.refused(name, in: list) { throw KubeTerminalLaunch.Problem.file(refused) }
        guard let context = list.context(named: name) else { throw KubeTerminalLaunch.Problem.noKubeconfig }
        let binding = KubeBindingStore.shared.binding(for: repo)
        let namespace = binding?.context == name ? binding?.namespace : nil
        try KubeTerminalLaunch.check(kubeconfigs: files)
        return (KubeTerminalPin(context, namespace: namespace), files)
    }
}

// MARK: Templates and saved filters, in the palette

extension TerminalWindowController {
    /// A new resource from each template, in the editor — and the user's templates' folder.
    func kubernetesTemplateItems() -> [PaletteItem] {
        let namespace = kubernetesPage.templateNamespace
        var items = KubeTemplates.list().map { template in
            PaletteItem(
                id: "k.template.\(template.id)", group: .action, title: "New Kubernetes \(template.kind)",
                subtitle: (template.isUsers ? "Your template" : "A template") + " in the editor, namespace \(namespace) — Diff with Cluster, then Apply…",
                symbol: "doc.badge.plus"
            ) { [weak self] _, _ in self?.kubernetesPage.newFromTemplate(template) }
        }
        items.append(
            PaletteItem(
                id: "k.templates.folder", group: .action, title: "Open Kubernetes Templates Folder",
                subtitle: "Your own templates: a YAML file there, by name, replaces Overterm's", symbol: "folder"
            ) { _, _ in
                let folder = KubeTemplates.userFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !AppEnvironment.isIsolated { NSWorkspace.shared.open(folder) }
            })
        return items
    }

    /// Each saved filter of a context the kubeconfig names: shown again on ↩.
    func kubernetesSavedFilterItems(_ model: KubernetesModel) -> [PaletteItem] {
        KubeSavedFilters.shared.all.filter { model.contexts.context(named: $0.context) != nil }.flatMap { saved in
            [
                PaletteItem(
                    id: "k.f.\(saved.id)", group: .kubernetes, title: "Kubernetes Filter: \(saved.name)", subtitle: saved.said + " · " + saved.filter,
                    symbol: "line.3.horizontal.decrease.circle"
                ) { [weak self] _, _ in
                    self?.kubernetesPage.applySavedFilter(saved)
                    self?.showKubernetesPage()
                },
                PaletteItem(
                    id: "k.f.remove.\(saved.id)", group: .action, title: "Kubernetes: Remove Saved Filter \(saved.name)", subtitle: saved.said,
                    symbol: "bookmark.slash"
                ) { _, _ in KubeSavedFilters.shared.remove(saved.id) },
            ]
        }
    }
}

// MARK: The editor on screen, and what closing loses

extension TerminalWindowController {
    /// The window's editor follows a cluster object's YAML only while it is
    /// on screen (`EditorViewController.isOnScreen`): its pane open, no page
    /// or review over it, the window not hidden or minimised.
    func followEditorOnScreen() {
        guard let editorItem else { return }
        editorItem.publisher(for: \.isCollapsed)
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateEditorOnScreen() } }
            .store(in: &cancellables)
        // @Published says before it changes: read after.
        store.$showingOverlay.map { _ in () }.merge(with: store.$reviewShowing.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.updateEditorOnScreen() } }
            .store(in: &cancellables)
    }

    func updateEditorOnScreen() {
        guard let editor, let window else { return }
        // An isolated run stays in the background, often under the user's own windows: there it counts as shown.
        let windowShown = window.isVisible && (AppEnvironment.isIsolated || window.occlusionState.contains(.visible))
        let shown = editorItem?.isCollapsed == false && !store.pageShowing && windowShown
        if editor.isOnScreen != shown { editor.isOnScreen = shown }
    }

    /// No other Overterm window is open: closing this one loses whatever
    /// edits the app keeps for nobody.
    var isLastWindow: Bool {
        !NSApp.windows.contains { $0 !== window && $0.isVisible && $0.windowController is TerminalWindowController }
    }

    /// What closing the window (`everyWindow`: the last one, or quitting)
    /// loses: the editor's unsaved files, and cluster objects' YAML with
    /// edits not applied — the editor's tabs, the detail's YAML tab, and,
    /// with `everyWindow`, the ones kept after the detail moved on.
    func unsavedNames(everyWindow: Bool) -> [String] {
        var names = editor?.unsavedNames ?? []
        var resources = everyWindow ? KubernetesModel.shared.resourceBuffers.edited : []
        if let shown = kubernetesPage.detail?.resource, shown.isEdited { resources.append(shown) }
        for resource in resources where !names.contains(resource.buffer.name) { names.append(resource.buffer.name) }
        return names
    }
}
