import AppKit

// MARK: A root's state and outputs in the right slot (docs/design/terraform/analysis.md 2.4, 5.6, stage 2c)

extension TerminalWindowController {
    var terraformStateActions: TerraformStateActions {
        TerraformStateActions(
            refresh: { [weak self] read in self?.showTerraformState(read.card, checkout: read.checkout) },
            offer: { [weak self] offer, output, read in self?.openTerraformOutput(offer, output: output, read: read) },
            open: { [weak self] url, line in self?.openInEditor(url, line: line) },
            close: { [weak self] in
                self?.terraformPlanPane.stopState()
                self?.toggleDiff(nil)
            })
    }

    /// A root's state in the right slot, which takes it (`RightSlot`):
    /// `state list` at once, then its values — the person's read, in the
    /// user's environment, nothing written anywhere. A read of the same
    /// root and workspace still going is shown again, never started twice:
    /// the card's State, its menu's and Read Again all come here.
    @discardableResult
    func showTerraformState(_ card: TerraformRootCard, checkout: URL? = nil) -> TerraformStateRead? {
        guard let checkout = checkout ?? terraformPanel.checkout else {
            NSSound.beep()
            return nil
        }
        let read: TerraformStateRead
        if let going = TerraformStateReads.shared.latest(checkout: checkout, root: card.path, reader: .person), going.isGoing,
            going.card.workspace == card.workspace
        {
            read = going
        } else {
            read = TerraformStateRead(checkout: checkout, card: card)
            TerraformStateReads.shared.add(read)
            read.begin(settingPath: Settings.shared.terraformPath)
        }
        // A read of another root shown before gives way, and stops (`TerraformPlanPaneModel.state`).
        terraformPlanPane.showState(read)
        rightPane.terraformPlanOpened = true
        rightPane.mode = .terraformPlan
        // A zoomed column hides the slot: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
        return read
    }

    /// What an output opens (2.4): never a sensitive one's (it offers
    /// nothing), never a password read from an output. An isolated run
    /// records it (`TerraformStateReads.offerRecorder`).
    func openTerraformOutput(_ offer: TerraformOutputLinks.Offer, output: TerraformState.Output, read: TerraformStateRead) {
        guard !output.sensitive else { return }
        if let recorder = TerraformStateReads.shared.offerRecorder { return recorder(offer) }
        switch offer {
        case .browser(let url):
            openDockerLink(url)
        case .database(let kind, let host, let port, let database):
            var connection = DatabaseConnection(name: "\(output.name) · \(read.card.name)", kind: kind)
            connection.host = host
            if let port { connection.port = port }
            if let database { connection.database = database }
            // The password is typed in the form, into the keychain: an output never holds it.
            newDatabaseConnection(from: DockerDatabaseGuess.Guess(connection: connection, password: nil))
        case .apiVariable(let name, let value):
            addTerraformOutputToAPI(name: name, value: value, read: read)
        case .kubernetes(let cluster):
            openTerraformCluster(cluster)
        }
    }

    /// Add to API environment: the variable written into the picked
    /// environment's `.bru` of the checkout's collection — asked first,
    /// every other block of the file kept byte for byte (`BruFile`).
    func addTerraformOutputToAPI(name: String, value: String, read: TerraformStateRead) {
        guard Settings.shared.apiEnabled else { return openSettings(.api) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let workspace = self.apiWorkspace
            if workspace.root?.standardizedFileURL != read.checkout.standardizedFileURL { workspace.setRoot(read.checkout) }
            await workspace.loadIfNeeded()
            guard let collection = workspace.collection, !collection.isPersonal else {
                return self.terraformNotice("No API collection in \(read.checkout.lastPathComponent)", "Make one in the API panel (⌥⌘R), then add the output to its environment.")
            }
            guard let environment = workspace.environmentName ?? collection.environments.first?.name,
                let ref = collection.environments.first(where: { $0.name == environment })
            else {
                return self.terraformNotice("\(collection.name) has no environment", "Add one in the API panel, then add the output to it.")
            }
            let file = ref.url.path.hasPrefix(collection.root.path + "/") ? String(ref.url.path.dropFirst(collection.root.path.count + 1)) : ref.url.lastPathComponent
            self.confirmDocker(
                "Add \(name) to the \(environment) environment?",
                "\(name) = \(value)\n\nWritten into \(file) of \(collection.name), in the checkout — the rest of the file as it is.", "Add"
            ) { [weak self] in
                guard let self else { return }
                do {
                    let text = try String(contentsOf: ref.url, encoding: .utf8)
                    guard let written = TerraformOutputLinks.environment(text, setting: name, to: value) else {
                        return self.terraformNotice("\(name) is a secret of \(environment)", "Its value lives in the keychain: Overterm doesn't write an output over it.")
                    }
                    try written.write(to: ref.url, atomically: true, encoding: .utf8)
                    workspace.reload()
                    self.showAPIClient(nil)
                } catch {
                    self.terraformNotice("Couldn't add \(name)", error.localizedDescription)
                }
            }
        }
    }

    /// Open in Kubernetes: the page on the kubeconfig context whose server
    /// or name is the cluster's; none is said, with the command that adds
    /// one — to run in a terminal, never typed by Overterm.
    func openTerraformCluster(_ cluster: TerraformOutputLinks.Cluster) {
        guard Settings.shared.kubernetesEnabled else { return openSettings(.kubernetes) }
        showKubernetesPage()
        Task { @MainActor [weak self] in
            let model = KubernetesModel.shared
            for _ in 0..<50 where !model.contextsRead { try? await Task.sleep(nanoseconds: 100_000_000) }
            let contexts = model.contexts.contexts.map { (name: $0.name, cluster: $0.cluster, server: $0.server) }
            if let name = TerraformOutputLinks.context(for: cluster, in: contexts) {
                model.select(name)
            } else {
                self?.terraformNotice(
                    "No context for \(cluster.name ?? cluster.server ?? "this cluster")",
                    "No kubeconfig context points at this \(cluster.service.rawValue) cluster. Add one in a terminal: \(TerraformOutputLinks.kubeconfigHint(for: cluster))")
            }
        }
    }

    /// A notice on the window; an isolated run's goes nowhere.
    func terraformNotice(_ title: String, _ detail: String) {
        guard !AppEnvironment.isIsolated, let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window) { _ in }
    }
}
