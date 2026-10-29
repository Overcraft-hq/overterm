import Foundation

/// A container's settings changed in place, its name, and an image made of
/// it — through the engine, as `docker update`, `docker rename` and
/// `docker commit` do: nothing goes to a terminal tab.
extension DockerPageModel {
    // MARK: Settings

    /// Settings… (`,`): the sheet, once its inspect is read — and, for a
    /// running one, what it uses now, one sample. The sheet copies what it
    /// is given, so it opens after both.
    func editSettings(_ container: ContainerSummary) {
        guard let engine = docker.engine else { return }
        Task {
            do {
                let detail = try await engine.container(container.Id)
                var settings = DockerContainerSettings(container, detail, engine: docker.info)
                if container.state == .running {
                    let id = container.Id
                    // A shim that stopped answering doesn't keep the sheet shut.
                    let sample = await DockerUsageMonitor.within(.seconds(2)) { try? await engine.oneShotStats(id) }
                    settings.inUse = sample.map { DockerUsage($0).memoryBytes }
                }
                containerSettings = settings
            } catch {
                self.error = "Settings of \(container.name): \(error.localizedDescription)"
            }
        }
    }

    /// The sheet's Apply: what is wrong is said back to the sheet, which
    /// stays open; nil once it is done, the sheet closed and the change
    /// said on the page.
    func applySettings(_ settings: DockerContainerSettings) async -> String? {
        if let problem = settings.problem { return problem }
        guard let change = settings.update else {
            containerSettings = nil
            return nil
        }
        guard let engine = docker.engine else { return "Docker isn't running." }
        do {
            let warnings = try await engine.update(container: settings.id, change)
            containerSettings = nil
            cleaned = "\(settings.name): \(settings.summary)." + (warnings.isEmpty ? "" : " Docker says: " + warnings.joined(separator: " "))
            focusList += 1
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Rename

    /// Rename…: the name asked for, and asked again with the reason when
    /// Docker would refuse it or another container has it. A compose
    /// service's container is asked about first: Compose finds it by its
    /// labels, and gives the old name back when it makes it again.
    func askRename(_ container: ContainerSummary, problem: String? = nil, typed: String? = nil) {
        let ask: () -> Void = { [weak self] in
            self?.actions?.askName("Rename “\(container.name)”", problem ?? "A new name: letters, digits, “_”, “.” and “-”.", typed ?? container.name) {
                name in
                guard let self, name != container.name else { return }
                if let problem = DockerContainerName.problem(name) {
                    self.askRename(container, problem: problem, typed: name)
                } else {
                    self.rename(container, to: name)
                }
            }
        }
        guard problem == nil, let project = container.composeProject, let service = container.composeService else { return ask() }
        actions?.confirm(
            "Rename a Compose service's container?",
            "Compose finds “\(container.name)” by its labels, so \(project) still runs it as \(service) — but the next up that makes it again "
                + "names it as before. For a name that lasts, set container_name in the compose file.", "Rename Anyway", ask)
    }

    func rename(_ container: ContainerSummary, to name: String) {
        busy.insert(container.Id)
        Task {
            defer { self.busy.remove(container.Id) }
            do {
                try await docker.rename(container.Id, to: name)
            } catch let error as DockerError where error.status == 409 && error.message.contains("in use") {
                askRename(container, problem: "Another container is called “\(name)”.", typed: name)
            } catch {
                self.error = "Rename \(container.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Save as Image

    /// Save as Image…: its inspect read first, so the question says what
    /// is left out of the image and what can't be — then `repository:tag`
    /// asked for.
    func askSaveAsImage(_ container: ContainerSummary) {
        guard let engine = docker.engine else { return }
        Task {
            do {
                let detail = try await engine.container(container.Id)
                // What its image set itself stays: a value the container didn't give.
                let imageEnv = (try? await engine.imageConfig(container.ImageID ?? container.Image))?.env ?? []
                askSaveAsImage(container, DockerCommit.plan(container, detail, imageEnv: imageEnv))
            } catch {
                self.error = "Save \(container.name) as an image: \(error.localizedDescription)"
            }
        }
    }

    /// Asked again, with the reason, when the engine would refuse the name.
    func askSaveAsImage(_ container: ContainerSummary, _ plan: DockerCommit.Plan, problem: String? = nil, typed: String? = nil) {
        let explanation = DockerCommit.explanation(plan)
        actions?.askName(
            "Save “\(container.name)” as an Image", problem.map { $0 + "\n\n" + explanation } ?? explanation,
            typed ?? DockerCommit.suggestedName(for: container.name, at: Date())
        ) { [weak self] reference in
            if let problem = DockerCommit.problem(reference) {
                self?.askSaveAsImage(container, plan, problem: problem, typed: reference)
            } else {
                self?.saveAsImage(container, as: reference, plan)
            }
        }
    }

    /// The commit, said on the page as it goes: its secrets blanked and
    /// Compose's and Testcontainers' labels emptied (`DockerCommit.changes`),
    /// committed twice on the classic image store, which keeps the
    /// container's own config in the image too (`commitAnew`); the new
    /// image in Images after.
    func saveAsImage(_ container: ContainerSummary, as reference: String, _ plan: DockerCommit.Plan) {
        let (repository, tag) = DockerEngine.split(reference)
        transfer("Saving \(container.name) as \(repository):\(tag)") { [docker] in
            guard let engine = docker.engine else { throw DockerError.unreachable("Docker isn't running.") }
            let comment = "Saved from \(container.name) by Overterm"
            // Unknown, it is done twice: right on either store.
            var info = docker.info
            if info == nil { info = try? await engine.info() }
            let id: String
            if plan.changes.isEmpty || info?.containerdStore == true {
                id = try await engine.commit(container: container.Id, repository: repository, tag: tag, comment: comment, changes: plan.changes)
            } else {
                let helper = container.name + "-saving-" + UUID().uuidString.prefix(6).lowercased()
                id = try await engine.commitAnew(
                    container: container.Id, helper: helper, repository: repository, tag: tag, comment: comment, changes: plan.changes)
            }
            docker.load(.images)
            return DockerCommit.note(name: container.name, repository: repository, tag: tag, id: id, plan: plan)
        }
    }
}
