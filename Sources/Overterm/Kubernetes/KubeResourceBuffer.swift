import AppKit
import Combine
import Foundation

/// A cluster object's YAML, edited in the editor (2.8): one buffer per
/// resource — the detail's YAML tab shows it (an embedded editor), and so
/// does the window editor's tab `y` opens: the same `EditorBuffer`, so
/// both show the same edits. Its text is the object stripped as the tab
/// always stripped it (managedFields, status, the last-applied annotation,
/// what names this one version), a Secret's values and secret-looking env
/// values masked; its version is kept beside it and sent with the apply.
///
/// It is never a file: no copy on disk, no autosave, nothing of it in the
/// session; a save is refused (`KubeManifestEdits.unsaved`) and closing it
/// with edits asks. Its Diff/Apply is `session` — the one apply path, with
/// its guards (KubeManifestSession).
///
/// While it shows (the detail's YAML tab on screen, or the active tab of a
/// window's editor) it follows the object — one watch of it by name. A
/// change that comes while the text is as the cluster had it replaces it
/// quietly; one that comes while it has edits is held in `clusterChange`
/// — the banner's Reload or Diff against it — and never overwrites them.
/// A Secret isn't followed: a read is every value at once, so it is read
/// only when the user asks (Show, `y`), and only its masks are kept.
@MainActor
final class KubeResourceBuffer: ObservableObject {
    enum State: Equatable {
        case empty
        case loaded
        case failed(String)
    }

    /// What the cluster did while the text had edits.
    enum ClusterChange: Equatable {
        /// A newer object: its text (stripped and masked) and its version.
        case changed(text: String, resourceVersion: String?)
        case deleted
    }

    /// What one object read does to the buffer (`rule`). Pure.
    enum Outcome: Equatable {
        /// The first text, or a change taken quietly: the text replaced.
        case replace
        /// The same object (its version, or its text unchanged): only the version kept.
        case keep
        /// The text has edits: held for the banner, never written over them.
        case banner
    }

    let ref: KubeObjectRef
    /// Its name in the editor: a path nothing is ever written at.
    let url: URL
    let buffer = EditorBuffer()
    let session: KubeManifestSession
    let model: KubernetesModel
    @Published private(set) var state: State = .empty
    @Published private(set) var clusterChange: ClusterChange?
    /// The text differs from what the cluster had when it was read.
    @Published private(set) var isEdited = false
    /// The detail's YAML tab shows the diff in place of the text (the
    /// right-hand pane is under the page).
    @Published var showsDiff = false
    /// The text as last read from the cluster (or last applied).
    private(set) var baseline = ""
    /// The version that text is of: sent with the apply.
    private(set) var resourceVersion: String?

    /// What it reads through: the context's proxy, the page's slot — or a test's.
    var client: () -> KubeClient?
    /// The registry's: held by nobody and without edits, it goes.
    var onSettled: ((KubeResourceBuffer) -> Void)?

    private var watchers: Set<ObjectIdentifier> = []
    private var following: Task<Void, Never>?
    /// The follow ended (the proxy closed for idle or for a writes switch,
    /// the socket reopened) or couldn't start while somebody still shows
    /// it: started again after this wait.
    private var restarting: Task<Void, Never>?
    private var restarts = 0
    /// The `n`th wait in a row before following again: backing off to 30 s.
    var restartDelay: (Int) -> Duration = { n in .milliseconds(min(500 * (1 << min(n, 6)), 30_000)) }
    private var reading: Task<Void, Never>?
    private var readAgain = false

    init(ref: KubeObjectRef, model: KubernetesModel) {
        self.ref = ref
        self.model = model
        url = KubeManifestEdits.url(for: ref)
        session = KubeManifestSession(source: .object(ref), file: url, model: model)
        client = { [weak model] in model?.client(for: ref.context) }
        buffer.resource = self
        buffer.document.unsaveable = KubeManifestEdits.unsaved
        buffer.kubeManifest = session
        session.resource = self
        session.text = { [weak self] in self?.buffer.storage.string ?? "" }
        session.onObjectApplied = { [weak self] version in self?.applied(version) }
        buffer.relay.onEdit = { [weak self] in self?.refreshEdited() }
        _ = KubeManifestEdits.register(ref, resourceVersion: nil)
    }

    var spoken: String { KubeWriteOutcome.spoken(ref) }
    var isProduction: Bool { model.contexts.context(named: ref.context)?.isProduction ?? true }

    /// The text an object is shown as.
    func text(of object: [String: Any]) -> String {
        KubeManifestEdits.header(ref, production: isProduction) + KubeYAML.text(KubeManifestDiff.forEditing(object))
    }

    /// The rule, for one object read. Pure.
    static func rule(loaded: Bool, edited: Bool, sameVersion: Bool, sameText: Bool) -> Outcome {
        guard loaded else { return .replace }
        if sameVersion || sameText { return .keep }
        return edited ? .banner : .replace
    }

    // MARK: What the cluster has

    /// An object read (the detail's GET, `y`'s, the follow's): the text
    /// replaced, kept, or — edited — held for the banner. A Secret's only
    /// from a read of its own (its values masked here), never any other
    /// kind's answer that turns out to be one.
    func take(_ object: [String: Any]) {
        guard KubeObjectStrip.isSecret(object) == ref.isSecret else { return }
        let version = (object["metadata"] as? [String: Any])?["resourceVersion"] as? String
        let text = text(of: object)
        switch Self.rule(
            loaded: state == .loaded, edited: isEdited, sameVersion: version != nil && version == resourceVersion, sameText: text == baseline)
        {
        case .replace:
            replace(with: text, version: version)
        case .keep:
            setVersion(version ?? resourceVersion)
            if !isEdited || text == baseline { clusterChange = nil }
        case .banner:
            clusterChange = .changed(text: text, resourceVersion: version)
        }
        state = .loaded
    }

    /// The object is gone from the cluster: said, the text kept — Apply
    /// would make it again.
    func deleted() {
        guard state == .loaded else { return state = .failed("\(spoken) isn't in \(ref.context).") }
        clusterChange = .deleted
    }

    /// The banner's Reload: the cluster's newer object, the edits dropped.
    func reload() {
        guard case .changed(let text, let version) = clusterChange else { return }
        replace(with: text, version: version)
    }

    /// Back to what the cluster has — its newer object when one came.
    func revert() {
        if case .changed(let text, let version) = clusterChange { return replace(with: text, version: version) }
        replace(with: baseline, version: resourceVersion)
    }

    /// The banner's Diff against it: the text against the live object.
    func diffAgainstCluster() { session.diffWithCluster() }

    /// An apply landed: what is in the editor is what the cluster has now —
    /// masked again. A Secret's apply goes through only once every value
    /// is retyped in clear (a masked one is never sent), and an env value
    /// whose name looks secret may be typed in clear on any kind: the
    /// buffer, its tab and its Copy hold masks again, and the undo that
    /// would bring the values back is dropped.
    private func applied(_ version: String?) {
        let typed = buffer.storage.string
        if let masked = Self.masked(typed, as: text(of:)), masked != typed {
            EditorViewController.replaceWhole(buffer, with: masked)
            buffer.undo.removeAllActions()
        }
        baseline = buffer.storage.string
        buffer.document.replaceVirtual(baseline)
        setVersion(version)
        clusterChange = nil
        refreshEdited()
    }

    /// `typed`'s one object as `shown` would show it, when that masks
    /// something typed in clear; nil when nothing is to be masked (or it
    /// isn't one object). Pure but for `shown`.
    static func masked(_ typed: String, as shown: ([String: Any]) -> String) -> String? {
        guard let objects = try? KubeManifest.parse(typed), objects.count == 1 else { return nil }
        let object = objects[0].object
        let masking = KubeObjectStrip.shown(object, full: false)
        guard !NSDictionary(dictionary: masking).isEqual(to: object) else { return nil }
        return shown(object)
    }

    private func replace(with text: String, version: String?) {
        baseline = text
        setVersion(version)
        clusterChange = nil
        if buffer.storage.string != text {
            if buffer.document.url == nil {
                buffer.loadVirtual(url, text: text, attributes: [.font: EditorViewController.font])
            } else {
                EditorViewController.replaceWhole(buffer, with: text)
            }
        } else if buffer.document.url == nil {
            buffer.loadVirtual(url, text: text, attributes: [.font: EditorViewController.font])
        }
        buffer.document.replaceVirtual(text)
        refreshEdited()
    }

    private func setVersion(_ version: String?) {
        resourceVersion = version
        KubeManifestEdits.applied(url, resourceVersion: version)
    }

    private func refreshEdited() {
        let was = isEdited
        let edited = state == .loaded && buffer.storage.string != baseline
        if edited != was { isEdited = edited }
        // Every editor's tab says the same: the text against the cluster's.
        buffer.document.setVirtualEdited(edited)
        // Edits gone (reverted, applied, undone): held by nobody, it may go now.
        if was, !edited { onSettled?(self) }
    }

    // MARK: Reading

    /// One GET of the object, taken. A Secret only when `secret` says the
    /// user asked (Show's consent, `y`'s): every value comes, and only
    /// their masks are kept.
    func load(secret: Bool = false) async throws {
        guard !ref.isSecret || secret else { throw KubeManifestProblem("A Secret is read only when you ask: Show, or Edit YAML.") }
        guard let client = client() else { throw KubeManifestProblem("Kubernetes is off, or the context is gone.") }
        do {
            let body = try await client.get(KubeWrites.path(ref)).body
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw KubeManifestProblem("\(spoken)'s answer couldn't be read.")
            }
            take(object)
        } catch let error as KubeAPIError where error.isNotFound {
            deleted()
            if state != .loaded { throw error }
        }
    }

    /// The follow's read: one at a time, the last change read again after it.
    private func read() {
        guard reading == nil else { return readAgain = true }
        reading = Task { [weak self] in
            do { try await self?.load() } catch {}
            guard let self else { return }
            self.reading = nil
            if self.readAgain, !self.watchers.isEmpty {
                self.readAgain = false
                self.read()
            }
        }
    }

    // MARK: Following, while it shows

    var isFollowing: Bool { following != nil }
    /// Followed, or waiting to follow again: somebody shows it.
    var wantsFollowing: Bool { following != nil || restarting != nil }

    /// `who` shows it now: followed while anybody does.
    func watch(by who: AnyObject) {
        watchers.insert(ObjectIdentifier(who))
        startFollowing()
    }

    func unwatch(by who: AnyObject) {
        watchers.remove(ObjectIdentifier(who))
        guard watchers.isEmpty else { return }
        stopFollowing()
        readAgain = false
    }

    private func stopFollowing() {
        following?.cancel()
        following = nil
        restarting?.cancel()
        restarting = nil
        restarts = 0
    }

    /// One watch of the object by name; each change read whole (the watch's
    /// rows are a Table's, without the spec). Never a Secret's.
    private func startFollowing() {
        guard following == nil, restarting == nil, !ref.isSecret, !watchers.isEmpty else { return }
        // Off, or the context not read yet: tried again while it shows.
        guard let client = client() else { return restartLater() }
        let ref = self.ref
        let scope: KubeScope = ref.namespace.map { .namespace($0) } ?? .all
        following = Task { [weak self] in
            do {
                for try await update in client.follow(ref.kind, in: scope, options: KubeListOptions(fieldSelector: "metadata.name=\(ref.name)")) {
                    guard let self, !Task.isCancelled else { return }
                    self.restarts = 0
                    switch update {
                    case .listed(let table):
                        if table.rows.isEmpty { self.deleted() } else { self.read() }
                    case .changed(let changes, _):
                        if changes.contains(where: { if case .deleted = $0 { true } else { false } }) { self.deleted() } else { self.read() }
                    case .bookmark, .retrying, .unlisted:
                        break
                    }
                }
            } catch {}
            guard let self, !Task.isCancelled else { return }
            self.following = nil
            // Ended while somebody still shows it: followed again, its list read again.
            self.restartLater()
        }
    }

    private func restartLater() {
        guard restarting == nil, following == nil, !watchers.isEmpty, !ref.isSecret else { return }
        let delay = restartDelay(restarts)
        restarts += 1
        restarting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.restarting = nil
            self.startFollowing()
        }
    }

    // MARK: Holders

    weak var registry: KubeResourceBuffers?

    /// A view that keeps it: the detail showing it, an editor tab.
    func hold(by holder: AnyObject) { registry?.hold(self, by: holder) }
    func release(by holder: AnyObject) { registry?.release(self, by: holder) }

    /// Gone from the registry: nothing followed, nothing read, its session's diff dropped.
    func close() {
        stopFollowing()
        reading?.cancel()
        reading = nil
        watchers = []
        session.close()
        for editor in buffer.relay.editors.allObjects {
            if let index = editor.buffers.firstIndex(where: { $0 === buffer }) { editor.removeBuffer(at: index) }
        }
    }
}

/// The resources' buffers: one each, by the name it has in the editor.
/// One is kept while a view holds it (the detail showing it, an editor's
/// tab) or while it has edits — the edits are nowhere else; held by
/// nobody and without edits it goes.
@MainActor
final class KubeResourceBuffers {
    unowned let model: KubernetesModel
    private(set) var open: [String: KubeResourceBuffer] = [:]
    private var holders: [String: Set<ObjectIdentifier>] = [:]

    init(model: KubernetesModel) { self.model = model }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// `ref`'s, made when there is none (held by nobody yet).
    func buffer(for ref: KubeObjectRef) -> KubeResourceBuffer {
        let url = KubeManifestEdits.url(for: ref)
        if let known = open[Self.key(url)] { return known }
        let made = KubeResourceBuffer(ref: ref, model: model)
        made.registry = self
        made.onSettled = { [weak self] resource in self?.dropIfUnheld(resource) }
        open[Self.key(url)] = made
        return made
    }

    func existing(_ ref: KubeObjectRef) -> KubeResourceBuffer? { open[Self.key(KubeManifestEdits.url(for: ref))] }

    /// The one named `url` in the editor.
    func resource(at url: URL) -> KubeResourceBuffer? { open[Self.key(url)] }

    @discardableResult
    func hold(_ ref: KubeObjectRef, by holder: AnyObject) -> KubeResourceBuffer {
        let resource = buffer(for: ref)
        hold(resource, by: holder)
        return resource
    }

    func hold(_ resource: KubeResourceBuffer, by holder: AnyObject) {
        holders[Self.key(resource.url), default: []].insert(ObjectIdentifier(holder))
    }

    func release(_ resource: KubeResourceBuffer, by holder: AnyObject) {
        holders[Self.key(resource.url)]?.remove(ObjectIdentifier(holder))
        dropIfUnheld(resource)
    }

    func isHeld(_ resource: KubeResourceBuffer) -> Bool { !(holders[Self.key(resource.url)] ?? []).isEmpty }

    /// Nobody holds it and it has no edits: gone.
    func dropIfUnheld(_ resource: KubeResourceBuffer) {
        let key = Self.key(resource.url)
        guard open[key] === resource, !isHeld(resource), !resource.isEdited else { return }
        open[key] = nil
        holders[key] = nil
        resource.close()
    }

    /// The ones with edits not applied.
    var edited: [KubeResourceBuffer] { open.values.filter(\.isEdited).sorted { $0.url.path < $1.url.path } }
}
