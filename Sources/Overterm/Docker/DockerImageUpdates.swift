import Combine
import Foundation

/// What a registry says a tag names now, as `docker buildx imagetools
/// inspect <ref>` prints it by default: the tag's own digest (an index's
/// for a multi-platform tag), its media type, and an index's children.
/// Pure.
struct DockerRegistryDigest: Equatable, Sendable {
    var digest: String
    var mediaType: String?
    /// An index's manifests' digests, one per platform (and attestation).
    var manifests: [String] = []

    /// buildx's text: `Name:`, `MediaType:` and `Digest:` unindented, then
    /// for an index `Manifests:` with each child's `Name: <ref>@<digest>`
    /// indented. Nil without a top digest — never a child's taken for it.
    static func parse(_ output: String) -> Self? {
        var digest: String?
        var mediaType: String?
        var manifests: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let indented = line.first?.isWhitespace == true
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon]
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !indented {
                if key == "Digest", digest == nil, DockerImageReference.isDigest(value) { digest = value }
                if key == "MediaType", mediaType == nil, !value.isEmpty { mediaType = value }
            } else if key == "Name", let at = value.lastIndex(of: "@") {
                let child = String(value[value.index(after: at)...])
                if DockerImageReference.isDigest(child) { manifests.append(child) }
            }
        }
        return digest.map { Self(digest: $0, mediaType: mediaType, manifests: manifests) }
    }

    /// Whether it names one of `digests`: its own, or one of an index's
    /// children — a pull by a platform's digest records that one.
    func names(any digests: Set<String>) -> Bool { digests.contains(digest) || manifests.contains(where: digests.contains) }
}

/// One tag's answer, kept with when it came.
struct DockerImageCheck: Equatable, Sendable {
    /// As the CLI was given it: `nginx:1.27`.
    var reference: String
    var remote: DockerRegistryDigest?
    /// Why it couldn't be asked, in a sentence.
    var failure: String?
    /// The registry has no such image, or wants credentials it was asked
    /// for without: for a tag that may have been built here, not a failure.
    var absent = false
    var at: Date
}

/// Where a tag stands. Pure.
enum DockerImageUpdateState: Equatable, Sendable {
    /// Built or tagged here — no repo digest for its own name in the
    /// classic store, or a project's files build it — or pinned by
    /// digest: nothing to ask.
    case local
    /// Not asked yet.
    case unchecked
    case checking
    case current
    /// Its registry names another image now.
    case available
    /// Its registry names another image, and nothing here says this one
    /// came from it: the containerd store records a repo digest for every
    /// named image, a build's too. Built or tagged here, or pulled before
    /// the registry moved on — never pulled over for that.
    case differs
    /// Its registry has no such image (or wants credentials, asked
    /// without) — and nothing says this one came from it: built here.
    case notInRegistry(String)
    case failed(String)

    /// `local`: the tag's repo digests (`DockerImageUpdates.localDigests`),
    /// nil when it isn't here. `known`: whether they say it came from its
    /// registry — in the classic store they do; in the containerd store
    /// only once an answer named one, or a project's files pull it.
    static func of(local: Set<String>?, check: DockerImageCheck?, checking: Bool, known: Bool = true) -> Self {
        if checking { return .checking }
        guard let local, !local.isEmpty else { return .local }
        guard let check else { return .unchecked }
        if let failure = check.failure { return check.absent && !known ? .notInRegistry(failure) : .failed(failure) }
        guard let remote = check.remote else { return .unchecked }
        if remote.names(any: local) { return .current }
        return known ? .available : .differs
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Why a registry couldn't be asked: no buildx (which stops the whole
/// check), or what to say. Pure.
enum DockerImageUpdateFailure: Error, Equatable, Sendable {
    case noBuildx
    /// No such image or tag there, or credentials wanted of a question
    /// asked without any.
    case absent(String)
    /// It didn't answer: the rest of its tags aren't asked.
    case unreachable(String)
    case reason(String)
    /// Stopped by the person.
    case cancelled

    /// buildx's stderr, in a sentence for `registry` (its domain). The
    /// reference, the URLs and the digests are taken out first: a tag
    /// like `2.401.3` or `nightly-20240429` is no status code.
    static func of(_ stderr: String, reference: String = "", registry: String) -> Self {
        let text = scrub(stderr, reference: reference)
        let name = registry == "docker.io" ? "Docker Hub" : registry
        if text.contains("'buildx' is not a docker command") || (text.contains("unknown command") && text.contains("buildx")) { return .noBuildx }
        // A helper named in ~/.docker/config.json that isn't there (a
        // `credsStore: desktop` left after a move to Colima) says "not found".
        if text.contains("error getting credentials") || text.contains("docker-credential-") {
            if let helper = text.range(of: #"docker-credential-[a-z0-9_.-]+"#, options: .regularExpression).map({ String(text[$0]) }),
                text.contains("not found")
            {
                return .reason("\(helper) isn't on this Mac — ~/.docker/config.json names it to sign in.")
            }
            return .reason("docker's credential helper failed — see ~/.docker/config.json's credsStore.")
        }
        if text.contains("name unknown") { return .absent("\(name) has no such image.") }
        if text.contains("manifest unknown") || text.contains("not found") { return .absent("\(name) has no such tag.") }
        if ["toomanyrequests", "429 too many requests", "too many requests"].contains(where: text.contains) {
            return .reason(
                registry == "docker.io" ? "Docker Hub's pull limit was reached; signed in (docker login), it's higher." : "\(name) is limiting requests.")
        }
        let refused = [
            "401 unauthorized", "403 forbidden", "unauthorized:", "insufficient_scope", "denied:", "access to the resource is denied", "failed to authorize",
            "authentication required",
        ]
        if refused.contains(where: text.contains) {
            let why = "\(name) wants credentials, or has no such image: docker login in a terminal tab if it's private."
            // Asked without credentials, a registry says the same of an
            // image it doesn't have.
            return text.contains("anonymous token") ? .absent(why) : .reason(why)
        }
        let unreachable = [
            "no such host", "dial tcp", "i/o timeout", "timed out", "connection refused", "connection reset", "network is unreachable", "tls:",
            "tls handshake", "x509:", "deadline exceeded",
        ]
        if unreachable.contains(where: text.contains) { return .unreachable("\(name) didn't answer.") }
        let line = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let said = line.hasPrefix("ERROR: ") ? String(line.dropFirst("ERROR: ".count)) : line
        if said.isEmpty { return .reason("buildx said nothing of \(name).") }
        return .reason(said.count > 200 ? String(said.prefix(199)) + "…" : said)
    }

    /// Lower case, without the reference in any of its spellings, the
    /// URLs (a request's carries the tag) and the digests.
    static func scrub(_ stderr: String, reference: String) -> String {
        var text = stderr.lowercased().replacingOccurrences(of: #"https?://[^\s"']+"#, with: " ", options: .regularExpression)
        var forms = reference.isEmpty ? [] : [reference]
        if let parsed = DockerImageReference(reference) {
            forms += [parsed.key, parsed.familiar, parsed.repository, parsed.path].compactMap { $0 }
        }
        for form in Set(forms.map { $0.lowercased() }).sorted(by: { $0.count > $1.count }) where form.contains(":") || form.contains("/") {
            text = text.replacingOccurrences(of: form, with: " ")
        }
        return text.replacingOccurrences(of: #"[a-z0-9]+:[0-9a-f]{32,}"#, with: " ", options: .regularExpression)
    }

    /// What a tag's answer says of it.
    var words: String? {
        switch self {
        case .absent(let why), .unreachable(let why), .reason(let why): why
        case .noBuildx, .cancelled: nil
        }
    }
}

/// A compose project's services by where their images stand: what its
/// detail and its row say. Pure.
struct DockerProjectUpdates: Equatable {
    struct Entry: Equatable {
        var service: String
        var reference: String
        var reason: String?
    }

    var available: [Entry] = []
    var current: [Entry] = []
    var failed: [Entry] = []
    /// Services whose registry names another image, where nothing says
    /// theirs came from it (`DockerImageUpdateState.differs`).
    var differs: [Entry] = []
    /// Current services a container of which runs another image than its
    /// tag names now — pulled since it was made: Up makes it again.
    var recreate: [String] = []
    /// The oldest of its answers.
    var checkedAt: Date?

    /// The detail's words; nil while nothing of it was checked.
    func line(ago: (Date) -> String) -> String? {
        let checked = checkedAt.map { " — checked " + ago($0) } ?? ""
        var parts: [String] = []
        if !available.isEmpty { parts.append("Newer in the registry: " + Self.entries(available) + checked) }
        if !recreate.isEmpty {
            parts.append("Pulled: Up recreates \(Self.list(recreate)) on the new image\(recreate.count == 1 ? "" : "s")")
        }
        if !differs.isEmpty { parts.append("Not as in the registry: " + Self.entries(differs) + " — built here, or pulled before it moved on") }
        for entry in failed { parts.append("Couldn't check \(entry.service) (\(entry.reference)): \(entry.reason ?? "")") }
        if available.isEmpty, differs.isEmpty, !current.isEmpty, failed.isEmpty, recreate.isEmpty { parts.append("Its images are current" + checked) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private static func entries(_ entries: [Entry]) -> String { entries.map { "\($0.service) (\($0.reference))" }.joined(separator: ", ") }

    private static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}

/// What the Images header counts, an image once: its tags' best news.
struct DockerImageUpdateCounts: Equatable, Sendable {
    var available = 0
    var differs = 0
    var failed = 0
    /// Not asked yet, or being asked: "Up to date" waits for them.
    var unchecked = 0
}

/// Check for Updates: whether each local tag still names what its
/// registry names, asked only when someone asks — every answer is a GET of
/// the registry's manifest, which Docker Hub counts as a pull. Through the
/// user's own `docker buildx imagetools inspect`, so the CLI's credential
/// helpers sign in and Overterm sees no password. The answers are kept in
/// memory with their time, for the app's run; the local side is read again
/// when an image changes, so a pull anywhere — the page's, `compose pull`
/// in a tab — makes an update current with no second question.
@MainActor
final class DockerImageUpdates: ObservableObject {
    static let shared = DockerImageUpdates(docker: .shared)

    /// By `DockerImageReference.key`.
    @Published private(set) var checks: [String: DockerImageCheck] = [:]
    /// Each local tag's repo digests in its own repository, by key: empty
    /// for one built or tagged here in the classic store.
    @Published private(set) var local: [String: Set<String>] = [:]
    /// The image each local tag names, by key.
    @Published private(set) var imageIDs: [String: String] = [:]
    /// Tags whose repo digests say nothing of where they came from: the
    /// containerd store records one for every named image (its own ID), a
    /// build's too.
    @Published private(set) var unproven: Set<String> = []
    /// Each tag's repo digests that a registry's answer named, this run:
    /// those came from it, even once it has moved on.
    @Published private(set) var confirmed: [String: Set<String>] = [:]
    /// Tags a project's files build: not the registry's, never asked.
    @Published private(set) var builtKeys: Set<String> = []
    /// Tags a project's files pull — an `image:` they don't build: the
    /// registry's.
    @Published private(set) var pulledKeys: Set<String> = []
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// When a check last asked a registry something — of some images, or
    /// all: the header counts what wasn't asked.
    @Published private(set) var lastRun: Date?

    /// Each project's services' references as last seen: once a tag
    /// moves, the engine lists a container by its image's ID, and the
    /// name it was made from would be lost.
    private var projectReferences: [String: [String: String]] = [:]
    /// Services each project's files build, as far as they were read.
    private var builtServices: [String: Set<String>] = [:]
    /// The projects the engine listed last: one gone takes its references.
    private var listedProjects: Set<String> = []
    private var task: Task<Outcome, Never>?
    private let docker: DockerModel
    private let cli: @MainActor (DockerEndpoint?) -> DockerCLI?
    private let parallel: Int
    private let now: () -> Date
    private var subscriptions: Set<AnyCancellable> = []

    /// `cli`: the `docker` to ask, nil when none may be — an isolated run
    /// asks only a scenario's stub.
    init(
        docker: DockerModel, cli: @escaping @MainActor (DockerEndpoint?) -> DockerCLI? = DockerImageUpdates.defaultCLI, parallel: Int = 4,
        now: @escaping () -> Date = Date.init
    ) {
        self.docker = docker
        self.cli = cli
        self.parallel = max(1, parallel)
        self.now = now
        // The emitted list: @Published fires before it lands. An empty one
        // while the engine is away is a disconnect's: what was known stays.
        docker.$images
            .sink { [weak self] images in
                guard let self else { return }
                if images.isEmpty, self.docker.engine == nil || !self.docker.connection.isRunning { return }
                self.setLocal(images)
            }
            .store(in: &subscriptions)
        // Each project's services' names, kept as they are seen — not only
        // when one is checked: a pull from the Images section moves a tag
        // too.
        docker.$projects
            .sink { [weak self] projects in self?.fold(projects) }
            .store(in: &subscriptions)
        // Another engine has other images; the registries' answers stay.
        docker.$endpoint.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.local.isEmpty { self.local = [:] }
                if !self.imageIDs.isEmpty { self.imageIDs = [:] }
                if !self.unproven.isEmpty { self.unproven = [] }
            }
            .store(in: &subscriptions)
        // Back after a disconnect, or a pull, a tag, a removal: the local
        // side read again — only once something has been checked, and only
        // when no section reads them already. `load` folds a burst into one
        // more read.
        docker.$connection.map(\.isRunning).removeDuplicates().dropFirst()
            .sink { [weak self] running in
                guard running else { return }
                self?.reread()
            }
            .store(in: &subscriptions)
        docker.events.filter { $0.Type == "image" }
            .sink { [weak self] _ in self?.reread() }
            .store(in: &subscriptions)
    }

    static let defaultCLI: @MainActor (DockerEndpoint?) -> DockerCLI? = { endpoint in
        !AppEnvironment.isIsolated || DockerCLI.override != nil ? DockerCLI(endpoint: endpoint) : nil
    }

    private func reread() {
        guard !checks.isEmpty, !docker.isWanted(.images) else { return }
        docker.load(.images)
    }

    private func setLocal(_ images: [ImageSummary]) {
        let digests = Self.localDigests(images)
        let ids = Self.taggedImages(images)
        let unproven = Self.unprovenTags(images, containerd: docker.info?.containerdStore == true)
        if digests != local { local = digests }
        if ids != imageIDs { imageIDs = ids }
        if unproven != self.unproven { self.unproven = unproven }
        confirm(Array(checks.keys))
    }

    /// For every tag of a named image, the digests its `RepoDigests` record
    /// for the tag's own repository. In the classic store, what the tag
    /// named when it came from its registry — a tag with none was built or
    /// tagged here. In the containerd store every named image has one, its
    /// own ID (`unprovenTags`).
    nonisolated static func localDigests(_ images: [ImageSummary]) -> [String: Set<String>] {
        var found: [String: Set<String>] = [:]
        for image in images where !image.isDangling {
            let digests = (image.RepoDigests ?? []).compactMap(DockerImageReference.digested)
            for tag in image.tags {
                guard let reference = DockerImageReference(tag), let key = reference.key else { continue }
                found[key, default: []].formUnion(digests.filter { $0.repository == reference.repository }.map(\.digest))
            }
        }
        return found
    }

    /// The tags whose repo digests don't say they were pulled: all of them
    /// in the containerd store (`/info` says so), and any image's whose
    /// repo digest is its own ID — only that store makes one so.
    nonisolated static func unprovenTags(_ images: [ImageSummary], containerd: Bool) -> Set<String> {
        var found = Set<String>()
        for image in images where !image.isDangling {
            guard containerd || (image.RepoDigests ?? []).contains(where: { DockerImageReference.digested($0)?.digest == image.Id }) else { continue }
            for tag in image.tags {
                if let key = DockerImageReference(tag)?.key { found.insert(key) }
            }
        }
        return found
    }

    /// Which image each tag names, by key.
    nonisolated static func taggedImages(_ images: [ImageSummary]) -> [String: String] {
        var found: [String: String] = [:]
        for image in images {
            for tag in image.tags {
                if let key = DockerImageReference(tag)?.key { found[key] = image.Id }
            }
        }
        return found
    }

    /// Each service's image, by name, for the services it has now:
    /// `recorded` (what it was seen as), the files' `image:` for a project
    /// before it runs, then what its lasting containers say they were made
    /// from — unless that is an ID (the engine says one once the tag names
    /// another image) or a digest, which can't move. Built services too:
    /// `built(of:)` says which those are.
    nonisolated static func references(of project: ComposeProject, recorded: [String: String]) -> [String: String] {
        let services = Set(project.services.map(\.name))
        var references = recorded.filter { services.contains($0.key) }
        for service in project.services {
            if let image = service.spec?.image, DockerImageReference(image)?.key != nil { references[service.name] = image }
            for container in service.containers where !container.isOneOff {
                let image = container.Image
                guard !image.isEmpty, image != container.ImageID, !image.hasPrefix("sha256:"), !image.contains("@") else { continue }
                references[service.name] = image
            }
        }
        return references
    }

    /// The services a project's files build: a plan's say so themselves.
    nonisolated static func specBuilt(_ project: ComposeProject) -> Set<String> {
        Set(project.services.filter { $0.spec?.buildContext != nil }.map(\.name))
    }

    /// Where a tag stands; a name that doesn't parse, one pinned by
    /// digest, or one a project's files build is `.local`.
    func state(of reference: String) -> DockerImageUpdateState {
        guard let key = DockerImageReference(reference)?.key, !builtKeys.contains(key) else { return .local }
        return .of(local: local[key], check: checks[key], checking: checking.contains(key), known: isKnown(key))
    }

    /// Whether a project's files build the tag.
    func isBuilt(_ reference: String) -> Bool { DockerImageReference(reference)?.key.map(builtKeys.contains) == true }

    /// Whether the tag's repo digests say it came from its registry.
    private func isKnown(_ key: String) -> Bool {
        !unproven.contains(key) || pulledKeys.contains(key) || !(confirmed[key] ?? []).isDisjoint(with: local[key] ?? [])
    }

    /// Why an image has nothing to ask its registry; nil when it has.
    func uncheckable(_ image: ImageSummary) -> String? {
        let digests = Self.localDigests([image])
        if image.tags.contains(where: { digests[DockerImageReference($0)?.key ?? ""]?.isEmpty == false && !isBuilt($0) }) { return nil }
        return image.tags.contains(where: isBuilt) ? "Its project's files build it: no registry to ask." : "Built or tagged here: no registry to ask."
    }

    /// The answer for a tag, if it was asked.
    func check(of reference: String) -> DockerImageCheck? { DockerImageReference(reference)?.key.flatMap { checks[$0] } }

    // MARK: Projects

    /// The engine's projects as it lists them: each one's references kept
    /// for its services now; one it no longer lists forgotten. Not while
    /// it is away — its empty list is a disconnect's.
    private func fold(_ projects: [ComposeProject]) {
        guard docker.engine != nil, docker.connection.isRunning else { return }
        let names = Set(projects.map(\.name))
        for gone in listedProjects.subtracting(names) { projectReferences[gone] = nil }
        listedProjects = names
        for project in projects {
            let references = Self.references(of: project, recorded: projectReferences[project.name] ?? [:])
            if projectReferences[project.name] != references { projectReferences[project.name] = references }
        }
        refreshProjectKeys()
    }

    /// The project's services' references as they are now, kept for when
    /// its containers no longer say them; `built`: the services its files
    /// build, when they were read. The ones it doesn't build, back.
    @discardableResult
    func record(_ project: ComposeProject, built: Set<String>? = nil) -> [String: String] {
        projectReferences[project.name] = Self.references(of: project, recorded: projectReferences[project.name] ?? [:])
        if let built {
            builtServices[project.name] = built.union(Self.specBuilt(project))
        } else if project.planned {
            builtServices[project.name] = Self.specBuilt(project)
        }
        refreshProjectKeys()
        return references(of: project)
    }

    /// Its services' references, as `record` would give them, without
    /// keeping anything: what a view draws. Not what its files build.
    func references(of project: ComposeProject) -> [String: String] {
        let built = built(of: project)
        return Self.references(of: project, recorded: projectReferences[project.name] ?? [:]).filter { !built.contains($0.key) }
    }

    /// The services its files build, as far as they were read.
    func built(of project: ComposeProject) -> Set<String> { (builtServices[project.name] ?? []).union(Self.specBuilt(project)) }

    /// The tags the projects' files build, and those they pull: known
    /// only for a project whose files were read.
    private func refreshProjectKeys() {
        var built = Set<String>()
        var pulled = Set<String>()
        for (project, references) in projectReferences {
            guard let services = builtServices[project] else { continue }
            for (service, reference) in references {
                guard let key = DockerImageReference(reference)?.key else { continue }
                if services.contains(service) { built.insert(key) } else { pulled.insert(key) }
            }
        }
        pulled.subtract(built)
        if built != builtKeys { builtKeys = built }
        if pulled != pulledKeys { pulledKeys = pulled }
    }

    func summary(of project: ComposeProject) -> DockerProjectUpdates {
        var summary = DockerProjectUpdates()
        var dates: [Date] = []
        for (service, reference) in references(of: project).sorted(by: { $0.key < $1.key }) {
            let key = DockerImageReference(reference)?.key
            if let at = key.flatMap({ checks[$0] })?.at { dates.append(at) }
            var entry = DockerProjectUpdates.Entry(service: service, reference: DockerImageReference(reference)?.familiar ?? reference)
            switch state(of: reference) {
            case .available: summary.available.append(entry)
            case .differs: summary.differs.append(entry)
            case .current:
                summary.current.append(entry)
                let named = key.flatMap { imageIDs[$0] }
                let containers = project.services.first { $0.name == service }?.containers.filter { !$0.isOneOff } ?? []
                let behind = containers.contains { container in
                    named.map { container.ImageID != nil && container.ImageID != $0 } ?? container.imageMovedOn
                }
                if behind { summary.recreate.append(service) }
            case .failed(let why):
                entry.reason = why
                summary.failed.append(entry)
            case .local, .notInRegistry, .unchecked, .checking: break
            }
        }
        summary.checkedAt = dates.min()
        return summary
    }

    /// The images a tag of which has a newer image in its registry.
    func images(withUpdates images: [ImageSummary]) -> [ImageSummary] {
        images.filter { image in image.tags.contains { state(of: $0) == .available } }
    }

    /// What the header counts, an image once: an update, else a registry
    /// with another image, else a failure, else not asked yet.
    func counts(of images: [ImageSummary]) -> DockerImageUpdateCounts {
        var counts = DockerImageUpdateCounts()
        for image in images {
            let states = image.tags.map(state(of:))
            if states.contains(.available) {
                counts.available += 1
            } else if states.contains(.differs) {
                counts.differs += 1
            } else if states.contains(where: \.isFailure) {
                counts.failed += 1
            } else if states.contains(where: { $0 == .unchecked || $0 == .checking }) {
                counts.unchecked += 1
            }
        }
        return counts
    }

    /// `1 update`, `3 updates`, `No updates`, then ` · 1 differs`,
    /// ` · 1 couldn't be checked`, ` · 28 not checked`. "Up to date" only
    /// when every image there was to ask is current.
    nonisolated static func headline(_ counts: DockerImageUpdateCounts) -> String {
        let settled = counts.differs == 0 && counts.failed == 0 && counts.unchecked == 0
        var parts = [counts.available == 0 ? (settled ? "Up to date" : "No updates") : counts.available == 1 ? "1 update" : String(counts.available) + " updates"]
        if counts.differs > 0 { parts.append(String(counts.differs) + (counts.differs == 1 ? " differs" : " differ")) }
        if counts.failed > 0 { parts.append(String(counts.failed) + " couldn't be checked") }
        if counts.unchecked > 0 { parts.append(String(counts.unchecked) + " not checked") }
        return parts.joined(separator: " · ")
    }

    // MARK: Asking

    struct Outcome: Equatable {
        /// Tags whose registries were asked.
        var asked: Int
        /// Names with nothing to ask: built or tagged here, not here, pinned.
        var skipped: Int
        /// What stopped the whole check.
        var failure: String?
        /// Stopped by the person (`cancel`).
        var cancelled = false
    }

    /// Asks each of `references`' registries once — a tag with several
    /// names once, one built here never — `parallel` at a time; a registry
    /// that didn't answer isn't asked again in it. Nil when a check runs
    /// already.
    @discardableResult
    func check(_ references: [String]) async -> Outcome? {
        guard !running else { return nil }
        guard let cli = cli(docker.endpoint) else {
            return Outcome(
                asked: 0, skipped: 0,
                failure: AppEnvironment.isIsolated
                    ? "This run asks no registry." : "docker isn't on this Mac: Check for Updates asks registries with docker buildx.")
        }
        guard let engine = docker.engine else { return Outcome(asked: 0, skipped: 0, failure: "Docker isn't running.") }
        running = true
        let task = Task { await self.ask(references, cli: cli, engine: engine) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        if !checking.isEmpty { checking = [] }
        running = false
        return outcome
    }

    /// Stops the check: what was asked stays, the questions on their way
    /// are dropped (their processes ended).
    func cancel() { task?.cancel() }

    private func ask(_ references: [String], cli: DockerCLI, engine: DockerEngine) async -> Outcome {
        // What is here now, not what the list read last.
        do {
            setLocal(try await engine.images())
        } catch {
            return Outcome(asked: 0, skipped: 0, failure: "Docker didn't list its images: \(error.localizedDescription)")
        }
        guard !Task.isCancelled else { return Outcome(asked: 0, skipped: 0, cancelled: true) }
        var seen = Set<String>()
        var targets: [Target] = []
        var skipped = 0
        for text in references {
            guard let reference = DockerImageReference(text), let key = reference.key else {
                skipped += 1
                continue
            }
            guard seen.insert(key).inserted else { continue }
            guard local[key]?.isEmpty == false, !builtKeys.contains(key) else {
                skipped += 1
                continue
            }
            targets.append(Target(key: key, reference: reference.familiar, registry: reference.domain))
        }
        guard !targets.isEmpty else { return Outcome(asked: 0, skipped: skipped) }
        checking = Set(targets.map(\.key))
        total = targets.count
        done = 0
        let ask = Self.asker(cli)
        var asked = 0
        var failure: String?
        var silent: [String: String] = [:]
        var pending = targets.makeIterator()
        // The next worth asking: one of a registry that didn't answer gets
        // the same answer — behind a firewall each would wait out its 30 s.
        func nextTarget() -> Target? {
            while let target = pending.next() {
                guard let why = silent[target.registry] else { return target }
                record(target, failure: why)
                done += 1
            }
            return nil
        }
        await withTaskGroup(of: (Target, Result<DockerRegistryDigest, DockerImageUpdateFailure>).self) { group in
            for _ in 0..<parallel {
                guard let target = nextTarget() else { break }
                group.addTask { (target, await ask(target)) }
            }
            // `next()`, not `for await`: one is added as one ends. After
            // "no buildx", or Stop, the rest are cancelled and their
            // answers left.
            while let next = await group.next() {
                guard failure == nil, !Task.isCancelled else { continue }
                let (target, result) = next
                switch result {
                case .success(let remote):
                    checking.remove(target.key)
                    checks[target.key] = DockerImageCheck(reference: target.reference, remote: remote, at: now())
                    confirm([target.key])
                case .failure(.absent(let why)):
                    record(target, failure: why, absent: true)
                case .failure(.unreachable(let why)):
                    silent[target.registry] = why
                    record(target, failure: why)
                case .failure(.reason(let why)):
                    record(target, failure: why)
                case .failure(.cancelled):
                    continue
                case .failure(.noBuildx):
                    failure = "Check for Updates needs docker buildx (imagetools). Docker Desktop and OrbStack ship it; elsewhere: brew install docker-buildx."
                    group.cancelAll()
                    continue
                }
                asked += 1
                done += 1
                if let target = nextTarget() { group.addTask { (target, await ask(target)) } }
            }
        }
        if asked > 0 { lastRun = now() }
        return Outcome(asked: asked, skipped: skipped, failure: failure, cancelled: Task.isCancelled)
    }

    private func record(_ target: Target, failure: String, absent: Bool = false) {
        checking.remove(target.key)
        checks[target.key] = DockerImageCheck(reference: target.reference, failure: failure, absent: absent, at: now())
    }

    /// The repo digests an answer names, kept: they are the registry's.
    private func confirm(_ keys: [String]) {
        var confirmed = self.confirmed
        for key in keys {
            guard let remote = checks[key]?.remote, let here = local[key] else { continue }
            let named = here.filter { remote.names(any: [$0]) }
            if !named.isEmpty { confirmed[key, default: []].formUnion(named) }
        }
        if confirmed != self.confirmed { self.confirmed = confirmed }
    }

    /// One tag to ask about.
    struct Target: Sendable {
        var key: String
        var reference: String
        var registry: String
    }

    /// The work of one tag, made here rather than in a closure of the main
    /// actor's: that one would be isolated to it (CLAUDE.md).
    nonisolated static func asker(_ cli: DockerCLI) -> @Sendable (Target) async -> Result<DockerRegistryDigest, DockerImageUpdateFailure> {
        { target in await inspect(target.reference, registry: target.registry, cli: cli) }
    }

    /// `docker buildx imagetools inspect <ref>`, its default output: a
    /// `--format` makes buildx fetch every platform's manifest and config.
    nonisolated static func inspect(_ reference: String, registry: String, cli: DockerCLI) async -> Result<DockerRegistryDigest, DockerImageUpdateFailure> {
        do {
            let output = try await cli.run(["buildx", "imagetools", "inspect", reference], timeout: 30)
            guard let digest = DockerRegistryDigest.parse(output) else { return .failure(.reason("buildx's answer couldn't be read.")) }
            return .success(digest)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as GitError {
            return .failure(Task.isCancelled ? .cancelled : DockerImageUpdateFailure.of(error.stderr, reference: reference, registry: registry))
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .reason(error.localizedDescription))
        }
    }

    /// Every answer forgotten: a scenario's end, so what follows reads no
    /// images for them.
    func forget() {
        checks = [:]
        confirmed = [:]
        projectReferences = [:]
        builtServices = [:]
        refreshProjectKeys()
        lastRun = nil
        done = 0
        total = 0
    }
}
