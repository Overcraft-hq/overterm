import Foundation

/// A Testcontainers run on the page: Remove All does what Ryuk does when a
/// run ends — its containers forced out with their anonymous volumes, then
/// the networks, volumes and images labelled with its session — and takes
/// Ryuk last. Killed sooner, Ryuk would leave the rest for good.
extension DockerPageModel {
    /// Asked first. The run is read again at the yes, so what it made
    /// meanwhile goes too.
    func confirmRemove(session: TestcontainersSession) {
        let members = session.members
        let title =
            members.isEmpty
            ? "Remove this run's reaper?" : "Remove this run's \(members.count) container\(members.count == 1 ? "" : "s")?"
        var detail: String
        if session.id.isEmpty {
            detail = "Testcontainers keeps these for reuse; the next run makes them again."
        } else {
            let made = [session.lang, "session " + session.shortID].compactMap { $0 }.joined(separator: ", ")
            detail = "Testcontainers made them for a test run (\(made))."
        }
        if members.contains(where: { $0.state.isUp }) { detail += " Running ones are stopped first — a run still going will fail." }
        detail +=
            session.id.isEmpty
            ? " Their anonymous volumes go with them."
            : " Their anonymous volumes go with them, then the networks, volumes and images labelled with the run, as Ryuk removes them when a run ends"
                + (session.reaper == nil ? "." : "; Ryuk itself last, once all of that has gone.")
        actions?.confirm(title, detail, "Remove All") { [weak self] in
            guard let self, let now = self.docker.testcontainers.first(where: { $0.id == session.id }) else { return }
            self.remove(session: now)
        }
    }

    /// Removes the run: its containers together, then what it labelled,
    /// then Ryuk — only when everything else went, so it still clears what
    /// couldn't go when the run ends. The window asks before.
    func remove(session: TestcontainersSession) {
        guard let engine = docker.engine else { return }
        let tag = Self.sessionTag(session.id)
        let members = session.members
        let ids = Set(session.containers.map(\.Id))
        busy.insert(tag)
        busy.formUnion(ids)
        Task {
            var failures = await withTaskGroup(of: String?.self) { group in
                for container in members { group.addTask { await Self.removing(container, engine) } }
                var failed: [String] = []
                for await failure in group { if let failure { failed.append(failure) } }
                return failed.sorted()
            }
            failures += await Self.removingLabelled(session.id, engine)
            if failures.isEmpty, let reaper = session.reaper, let failure = await Self.removing(reaper, engine) { failures.append(failure) }
            await docker.reload()
            busy.subtract(ids)
            busy.remove(tag)
            selection.subtract(ids)
            selection.remove(tag)
            if let first = failures.first { error = "Remove All: " + first + (failures.count > 1 ? " (and \(failures.count - 1) more)" : "") }
        }
    }

    /// One container forced out with its anonymous volumes, as Ryuk removes
    /// it: nil when it went, or was gone — Ryuk's own removal racing this
    /// one says "already in progress". Else what the engine said.
    nonisolated static func removing(_ container: ContainerSummary, _ engine: DockerEngine) async -> String? {
        do {
            try await engine.remove(container: container.Id, force: true, volumes: true)
            return nil
        } catch let error as DockerError where error.status == 404 || (error.status == 409 && error.message.contains("already in progress")) {
            return nil
        } catch {
            return "\(container.name): \(error.localizedDescription)"
        }
    }

    /// What the run labelled, in Ryuk's order once its containers are
    /// gone: networks, volumes, images — each list read once. Nothing for
    /// the containers in no run. What couldn't go, said.
    nonisolated static func removingLabelled(_ session: String, _ engine: DockerEngine) async -> [String] {
        guard !session.isEmpty else { return [] }
        var failures: [String] = []
        func failed(_ name: String, _ error: Error) {
            // Gone already: Ryuk got there first.
            if (error as? DockerError)?.status != 404 { failures.append("\(name): \(error.localizedDescription)") }
        }
        do {
            for network in Testcontainers.networks(of: session, in: try await engine.networks()) {
                do { try await engine.remove(network: network.Id) } catch { failed(network.Name, error) }
            }
        } catch {
            failures.append("its networks: \(error.localizedDescription)")
        }
        do {
            for volume in Testcontainers.volumes(of: session, in: try await engine.volumes()) {
                do { try await engine.remove(volume: volume.Name) } catch { failed(volume.shortName, error) }
            }
        } catch {
            failures.append("its volumes: \(error.localizedDescription)")
        }
        do {
            for image in Testcontainers.images(of: session, in: try await engine.images()) {
                do { try await engine.remove(image: image.Id) } catch { failed(image.tags.first ?? image.shortID, error) }
            }
        } catch {
            failures.append("its images: \(error.localizedDescription)")
        }
        return failures
    }
}
