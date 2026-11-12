import Combine
import Foundation

/// A review tab's Terraform section (stage 2f, analysis 2.9): the roots
/// what is reviewed touches, read from the checkout that has its head —
/// else from the review's own, with "Check Out in a New Worktree…" — and,
/// beside each, the latest plan of that root there. It reads only while
/// its review is on screen and loaded (one `git ls-files`, the touched
/// roots' files), and it never plans by itself (5.5): Plan is a press,
/// and always asks.
@MainActor
final class TerraformReviewModel: ObservableObject {
    enum State: Equatable {
        case idle, reading, read
    }

    @Published private(set) var state = State.idle
    @Published private(set) var roots: [TerraformReview.Root] = []
    /// The checkout with the reviewed head, when one has it: where Plan runs.
    @Published private(set) var head: TerraformReview.Head?
    /// The checkout read: the head's, else the review's own.
    @Published private(set) var readCheckout: URL?
    /// The section open or folded — the review tab's own.
    @Published var expanded = true
    /// A worktree being made for it ("Check Out in a New Worktree…").
    @Published var checkingOut = false
    /// The read checkout's cards, by path — what Plan is given, the head's only.
    private(set) var cards: [String: TerraformRootCard] = [:]
    /// Each touched root's local modules' risks (`TerraformReview.moduleRisks`).
    private(set) var moduleRisks: [String: [TerraformRunRisk]] = [:]
    /// Each touched root's modules whose code wasn't read.
    private(set) var unreadModules: [String: Int] = [:]
    /// What the review's head is (a commit when known): Plan checks the
    /// head's checkout is still at it.
    private(set) var wanted: TerraformReview.Wanted?
    /// The paths read: Plan reads them again, the checkout's files as they are then.
    private(set) var changed: [String] = []
    /// The review loaded while another showed: read when it shows.
    var missed = false
    /// How many times it was read: a scenario checks it reads only while shown.
    private(set) var reads = 0
    var cancellables: Set<AnyCancellable> = []
    private var reading: Task<Void, Never>?

    /// Reads `changed`'s roots in `checkout` — the head's when `head` says
    /// one has it. Bounded as the panel's read is (`assemble`).
    func read(changed: [String], checkout: URL, head: TerraformReview.Head?, wanted: TerraformReview.Wanted? = nil) {
        reads += 1
        missed = false
        reading?.cancel()
        self.head = head
        self.wanted = wanted
        self.changed = changed
        readCheckout = checkout
        if roots.isEmpty { state = .reading }
        reading = Task { [weak self] in
            let read = await Self.fresh(changed: changed, checkout: checkout)
            guard let self, !Task.isCancelled else { return }
            self.land(read)
            self.state = .read
        }
    }

    /// The read checkout's roots and modules as they are now — what Plan
    /// asks with, never what was read when the review loaded (a pull, an
    /// edit, an agent's commit since).
    func reread() async -> Read? {
        guard let checkout = readCheckout else { return nil }
        let read = await Self.fresh(changed: changed, checkout: checkout)
        land(read)
        return read
    }

    private func land(_ read: Read) {
        cards = Dictionary(read.cards.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        moduleRisks = read.moduleRisks
        unreadModules = read.unreadModules
        roots = read.roots
    }

    private static func fresh(changed: [String], checkout: URL) async -> Read {
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let shell = AppEnvironment.guardsTerraform ? [:] : (ShellEnvironment.known() ?? [:])
        let listing = await TerraformRootScan.list(checkout)
        return await TerraformPanelModel.blocking {
            Self.assemble(checkout: checkout, listing: listing, changed: changed, settings: settings, identities: identities, awsProfile: shell["AWS_PROFILE"])
        }
    }

    /// Post to Pull Request is pressable: the head is what is reviewed and
    /// a touched root has a plan there (which of them may be posted is
    /// weighed at the press, `TerraformReview.postable`).
    func canPost(_ registry: TerraformRunRegistry) -> Bool {
        guard let head, head.isReviewed else { return false }
        return roots.contains { registry.latest(checkout: head.checkout.url, root: $0.path)?.plan != nil }
    }

    /// Nothing to show: Terraform off, or a review with no files.
    func clear() {
        reading?.cancel()
        roots = []
        cards = [:]
        moduleRisks = [:]
        unreadModules = [:]
        head = nil
        wanted = nil
        state = .idle
    }

    struct Read: Sendable {
        var roots: [TerraformReview.Root] = []
        var cards: [TerraformRootCard] = []
        var moduleRisks: [String: [TerraformRunRisk]] = [:]
        var unreadModules: [String: Int] = [:]
    }

    /// How many modules' code is read for a review's risks, at most.
    nonisolated static let maxModules = 200

    /// The touched roots of `checkout`'s listing with the reviewed files
    /// added: blocking file reads, the panel's bounds.
    nonisolated static func assemble(
        checkout: URL, listing: TerraformRootScan.Listing?, changed: [String], settings: TerraformClassSettings,
        identities: Set<TerraformStateIdentity>, awsProfile: String?
    ) -> Read {
        let terraformFiles = changed.filter { TerraformRootGuess.isTerraformName(($0 as NSString).lastPathComponent) }
        // Nothing Terraform's changed and nothing listed: no section.
        guard listing != nil || !terraformFiles.isEmpty else { return Read() }
        let folders = TerraformReview.listing(listing?.folders ?? [:], adding: terraformFiles)
        let assembled = TerraformPanelModel.assemble(
            checkout: checkout, listing: TerraformRootScan.Listing(folders: folders, capped: listing?.capped ?? false), worktrees: [],
            settings: settings, identities: identities, awsProfile: awsProfile, changed: changed)
        let present = Set(
            assembled.roots.map(\.path).filter { path in
                FileManager.default.fileExists(atPath: (path.isEmpty ? checkout : checkout.appendingPathComponent(path)).path)
            })
        var read = Read()
        read.roots = TerraformReview.touched(cards: assembled.roots, modules: assembled.modules, changed: changed, present: present)
        let touched = Set(read.roots.map(\.path))
        read.cards = assembled.roots.filter { touched.contains($0.path) }
        // Each touched root's modules, through other modules too: their code runs in its plan.
        // Past the cap, or not in this checkout: not read, and said (the question can't call them harmless).
        var configs: [String: TerraformConfigFacts] = [:]
        let called = assembled.modules.filter { !Set($0.callers).isDisjoint(with: touched) }
        for module in called.prefix(maxModules) {
            let url = module.path.isEmpty ? checkout : checkout.appendingPathComponent(module.path, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            configs[module.path] = TerraformConfigFacts.read(TerraformRootFacts.configTexts(in: url))
        }
        for root in touched {
            let calls = called.filter { $0.callers.contains(root) }
            let modules = calls.compactMap { module in configs[module.path].map { (path: module.path, config: $0) } }
            read.moduleRisks[root] = TerraformReview.moduleRisks(modules)
            if calls.count > modules.count { read.unreadModules[root] = calls.count - modules.count }
        }
        return read
    }
}
