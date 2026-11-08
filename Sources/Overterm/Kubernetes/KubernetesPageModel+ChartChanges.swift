import Foundation

/// The pods' states read for a Metrics tab's markers: whose, where from,
/// what was seen, and why it couldn't be read.
struct KubePodStatesReading: Equatable {
    var ref: KubeObjectRef
    var path: String
    var log = KubeRestartLog()
    var problem: String?
    /// Refused (403) or the sign-in failed: not read again for this detail.
    var stopped = false
}

/// What the Metrics tab's markers are joined from (docs/design/kubernetes/
/// metrics.md, 3.2; stage M4), and what a marker opens: nothing read for
/// them but what the detail reads anyway — a workload's History (read once
/// as its tab opens), a kind without one its own events (once) — and one
/// bounded read of its pods' states while the tab shows: a pod's own GET,
/// a workload's pods by its selector (at most 250), every
/// `podStatesInterval`, read as it arrives up to `KubePodStates.maxBytes`
/// (past it, the read stops and the connection closes, said), decoded off
/// the main thread to restarts and last terminations, nothing else kept.
/// A 403, a failed sign-in or an answer past the bound stops it, said
/// once. GETs only.
///
/// Not a `KubeMetricsMonitor` target: a workload's tab already takes the
/// three detail targets a context polls (its pods, its replicas, its HPA's),
/// and a fourth would push its own pods' usage out; it is one request a
/// minute of the apiserver's, stopped and said by the same rules.
extension KubernetesPageModel {
    /// The tab's markers' sources, as they stand.
    func chartChanges(of session: KubeDetailSession) -> KubeChartChanges {
        var changes = KubeChartChanges()
        if let timeline = session.timeline {
            changes.timeline = timeline.entries
            // A History reads the object's events itself: joined once it is read, whatever it found.
            changes.eventsJoined = timeline.state == .loaded
        } else {
            changes.events = session.events.value ?? []
            changes.eventsJoined = session.events.value != nil
        }
        if let reading = podStates, reading.ref == session.ref {
            if reading.log.states != nil { changes.restarts = reading.log }
            changes.namesPods = !session.ref.isPod
            changes.problem = reading.problem.map { "Its pods' restarts couldn't be read: \($0)" }
        }
        return changes
    }

    /// Where the pods' states are read for `session`'s tab: the pod
    /// itself, or a workload's pods by its selector — nil for another kind,
    /// or a workload whose selector isn't known yet.
    func podStatesPath(of session: KubeDetailSession) -> String? {
        let ref = session.ref
        guard let namespace = ref.namespace else { return nil }
        if ref.isPod { return "/api/v1/namespaces/\(KubePath.segment(namespace))/pods/\(KubePath.segment(ref.name))" }
        guard case .workload = ref.metricsSubject, let pods = session.overview?.pods, !pods.selector.isEmpty else { return nil }
        return KubePath.query(
            "/api/v1/namespaces/\(KubePath.segment(pods.namespace))/pods", [("labelSelector", pods.selector), ("limit", String(KubePodStates.limit))])
    }

    /// The tab shows on a page on screen: its History or its events asked
    /// for (once), its pods' states read; else nothing is.
    func updateChartChanges() {
        guard let session = detail else {
            stopPodStates()
            podStates = nil
            return
        }
        // Read only where a chart is drawn: without metrics-server only an HPA's tab draws (its status).
        guard visible, windowVisible, section.listsKinds, metricsTabShows, model.selected?.settings.metrics != KubeMetricsSource.none,
            session.ref.metricsSubject == .hpa || model.metrics.availability == .served
        else { return stopPodStates() }
        if session.timeline == nil { session.loadEvents() } else { session.showHistory() }
        guard let path = podStatesPath(of: session) else { return stopPodStates() }
        if let reading = podStates, reading.ref == session.ref, reading.path == path {
            guard podStatesTask == nil, !reading.stopped else { return }
        } else {
            // A pod's object is its first read: its states now, the next a period on.
            var log = KubeRestartLog()
            if session.ref.isPod, let object = session.object, let pod = KubePodStates.pod(object.json) {
                log = KubeRestartLog(KubePodStates(pods: [pod], read: Date()))
            }
            podStates = KubePodStatesReading(ref: session.ref, path: path, log: log)
        }
        startPodStates(ref: session.ref, path: path, waitFirst: podStates?.log.states != nil)
    }

    func stopPodStates() {
        podStatesTask?.cancel()
        podStatesTask = nil
    }

    private func startPodStates(ref: KubeObjectRef, path: String, waitFirst: Bool) {
        podStatesTask?.cancel()
        let interval = podStatesInterval
        let maxBytes = podStatesMaxBytes
        podStatesTask = Task { [weak self] in
            var wait = waitFirst
            while !Task.isCancelled {
                if wait { try? await Task.sleep(for: interval) }
                wait = true
                guard !Task.isCancelled, let self else { return }
                guard let client = self.model.client(for: ref.context) else { continue }
                do {
                    // Bounded as it arrives: past the bound nothing more is read, let alone held.
                    let body = try await client.get(path, maxBytes: maxBytes)
                    // Decoded off the main thread: up to 250 pods' objects, dropped as read.
                    let states = try await Task.detached(priority: .utility) { try KubePodStates.read(body, at: Date()) }.value
                    guard !Task.isCancelled, self.podStates?.ref == ref, self.podStates?.path == path else { return }
                    self.podStates?.log.record(states)
                    self.podStates?.problem = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.podStates?.ref == ref else { return }
                    self.podStates?.problem = KubernetesModel.said(error)
                    if let large = error as? KubeBodyTooLarge {
                        self.podStates?.problem = KubePodStates.tooLarge(limit: large.limit)
                    }
                    // Refused, the sign-in failed or too large: said once, never asked again in a loop.
                    if error is KubeProxyProblem || error is KubeBodyTooLarge || (error as? KubeAPIError)?.isForbidden == true {
                        self.podStates?.stopped = true
                        self.podStatesTask = nil
                        return
                    }
                }
            }
        }
    }

    // MARK: The window around a marker

    /// ⌥-click, or "Show ±30 min": every chart of the tab narrowed to the
    /// marker's time ± 30 minutes — nothing asked: what was sampled, narrowed.
    func showAround(_ marker: KubeChartMarker, now: Date = Date()) {
        metricsWindow = KubeChartWindow.around(marker.time, now: now)
    }

    /// Reset (or Esc): the range again. False when there was no window.
    @discardableResult
    func resetMetricsWindow() -> Bool {
        guard metricsWindow != nil, metricsTabShows else { return false }
        metricsWindow = nil
        return true
    }

    // MARK: What a marker opens

    /// A marker's popover's button (or a click with nothing else to say):
    /// a restart's or an OOMKill's previous log — a workload's pod's on
    /// that pod's Logs tab —, a change's History entry and its diff, an
    /// event in Events.
    func openMarker(_ marker: KubeChartMarker) {
        switch marker.opens ?? marker.container.map({ .previousLog(pod: nil, container: $0) }) {
        case .previousLog(let pod, let container)?:
            if let pod, let current = detail?.ref, let namespace = current.namespace {
                let kind = model.knownDiscovery(of: current.context)?.kind(apiVersion: "v1", kind: "Pod") ?? .pods
                detailTab = .logs
                open(KubeObjectRef(context: current.context, kind: kind, namespace: namespace, name: pod), from: .link)
                detail?.logs?.pick(container: container, previous: true)
                updateLogsReading()
                return
            }
            guard let logs = detail?.logs else { return }
            logs.pick(container: container, previous: true)
            showTab(.logs)
        case .history(let entry, let change)?:
            markedEntry = entry
            showTab(.history)
            if let change { openChange(change) }
        case .event(let id)?:
            markedEntry = "event/\(id)"
            showTab(.events)
        case nil:
            break
        }
    }
}
