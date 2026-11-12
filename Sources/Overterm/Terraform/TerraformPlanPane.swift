import Combine
import Foundation

/// The right slot's Terraform tab (analysis 6.1, 6.3): the run shown —
/// its progress and log while it runs, then the plan as data — with the
/// filter and chips, the rows open, and what the cause chains need: the
/// root's files' lines and the branch's added lines. One per window.
///
/// The rows and their chains are kept here, built again only when the
/// plan, the filter, the chips or the sources change — never in a view's
/// body: a 2,000-resource plan's rows built on every redraw, under rows
/// that each observed the whole pane, was every visible row drawn again
/// for a keystroke in the filter.
@MainActor
final class TerraformPlanPaneModel: ObservableObject {
    @Published private(set) var run: TerraformPlanRun?
    @Published var filter = "" { didSet { if filter != oldValue { rebuild() } } }
    @Published var chips: Set<TerraformPlanRows.Chip> = [] { didSet { if chips != oldValue { rebuild() } } }
    @Published var expanded: Set<String> = []
    /// The row the keys act on (Section 7), by id.
    @Published var selected: String?
    /// The changes pane's added lines by file, relative to the checkout:
    /// what is uncommitted and untracked, beside the run's own reading of
    /// the branch (`TerraformPlanRun.changedLines`).
    @Published var changedLines: [String: Set<Int>] = [:] { didSet { if changedLines != oldValue { recause() } } }
    /// Where the root's variables and locals come from, read once a plan lands.
    @Published private(set) var sources = TerraformCauseChain.Sources()
    /// The rows as the filter and chips leave them.
    @Published private(set) var rows: [TerraformPlanRow] = []
    /// Each risky row's chain, by row id.
    @Published private(set) var chains: [String: [TerraformCauseChain.Link]] = [:]
    /// Asks the view for the filter field's focus (`/`).
    @Published private(set) var filterFocus = 0
    /// Asks the list's key view for the keyboard: a row was pressed.
    @Published private(set) var keyboard = 0
    private var watching: AnyCancellable?
    private var reading: Task<Void, Never>?

    func show(_ run: TerraformPlanRun) {
        guard run !== self.run else { return }
        self.run = run
        filter = ""
        chips = []
        expanded = []
        selected = nil
        sources = TerraformCauseChain.Sources()
        rebuild()
        // The run's phase moving on: the rows, and the sources once it planned.
        watching = run.$phase
            .removeDuplicates()
            .sink { [weak self, weak run] phase in
                guard let self, let run, phase == .planned || phase == .noChanges else { return }
                DispatchQueue.main.async {
                    guard self.run === run else { return }
                    self.rebuild()
                    self.readSources(of: run)
                }
            }
    }

    func clear() {
        run = nil
        rows = []
        chains = [:]
        selected = nil
        watching = nil
        reading?.cancel()
    }

    /// What "changed in this branch" reads: the branch's lines since the
    /// merge base, and what the changes pane has uncommitted.
    var effectiveChangedLines: [String: Set<Int>] { TerraformChangedLines.merged(run?.changedLines ?? [:], changedLines) }

    /// A row's cause chain (3.1): replace and delete rows.
    func causes(_ row: TerraformPlanRow) -> [TerraformCauseChain.Link] { chains[row.id] ?? [] }

    /// The causes by address, said: Copy summary's, over the whole plan.
    func causeTexts() -> [String: String] {
        guard let plan = run?.plan else { return [:] }
        return TerraformCauseChain.texts(plan: plan, sources: sources, changed: effectiveChangedLines)
    }

    /// The block of `address` in the root's files: "Open block" (`o`).
    func block(of address: String) -> TerraformCauseChain.Location? {
        let bare = address.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        return sources.blocks[bare]
    }

    func toggle(_ row: TerraformPlanRow) {
        selected = row.id
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
    }

    func toggle(_ chip: TerraformPlanRows.Chip) {
        if chips.contains(chip) { chips.remove(chip) } else { chips.insert(chip) }
    }

    func takeKeyboard() { keyboard += 1 }

    var selectedRow: TerraformPlanRow? { selected.flatMap { id in rows.first { $0.id == id } } }

    /// The selection moved by `step` rows, kept inside the list.
    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        let index = selected.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        selected = rows[next].id
    }

    // MARK: Keys

    /// A key on the plan's list (Section 7): ↑ ↓ move, ↩ the detail, `o`
    /// open the block, `a` Ask Why, `/` the filter, ⌫ discard the plan;
    /// ⌘C copies the address (`copyAddress`). False: not the plan's.
    enum Key: Equatable, Sendable {
        case up, down, detail, open, askWhy, filter, discard, escape
    }

    /// A key down as the list reads it: arrows, Return and Delete by
    /// their codes, letters by what is typed. Pure.
    nonisolated static func key(keyCode: UInt16, characters: String?) -> Key? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .detail
        case 51, 117: return .discard
        case 53: return .escape
        default: break
        }
        switch characters {
        case "o": return .open
        case "a": return .askWhy
        case "/": return .filter
        case "j": return .down
        case "k": return .up
        default: return nil
        }
    }

    func press(_ key: Key, actions: TerraformPlanActions) -> Bool {
        guard let run else { return false }
        switch key {
        case .up: move(-1)
        case .down: move(1)
        case .escape:
            guard selected != nil else { return false }
            selected = nil
        case .detail:
            guard let row = selectedRow else { return false }
            toggle(row)
        case .open:
            guard let row = selectedRow, let location = block(of: row.address) else { return false }
            actions.open(run.checkout.appendingPathComponent(location.file), location.line)
        case .askWhy:
            guard case .failed = run.phase else { return false }
            actions.askWhy(run)
        case .filter:
            filterFocus += 1
        case .discard:
            guard !run.isGoing else { return false }
            actions.discard(run)
        }
        return true
    }

    /// ⌘C on the list: the selected row's address.
    func copyAddress() -> String? { selectedRow?.address }

    // MARK: Rows and chains

    private func rebuild() {
        guard let plan = run?.plan else {
            if !rows.isEmpty { rows = [] }
            chains = [:]
            return
        }
        rows = TerraformPlanRows.build(plan, filter: filter, chips: chips)
        if let selected, !rows.contains(where: { $0.id == selected }) { self.selected = nil }
        recause()
    }

    private func recause() {
        guard let plan = run?.plan else { return }
        let changed = effectiveChangedLines
        var chains: [String: [TerraformCauseChain.Link]] = [:]
        for row in rows where row.section == .risky {
            guard let change = row.first else { continue }
            let links = TerraformCauseChain.chain(for: change, plan: plan, sources: sources, changed: changed)
            if !links.isEmpty { chains[row.id] = links }
        }
        if chains != self.chains { self.chains = chains }
    }

    /// The root's `.tf` files and the var files the run loaded, read off
    /// the main thread, bounded (`TerraformConfigIndex`'s budget).
    private func readSources(of run: TerraformPlanRun) {
        let folder = run.card.folder
        let prefix = run.card.path.isEmpty ? "" : run.card.path + "/"
        let varFiles = run.autoVarFiles + run.varFiles
        reading?.cancel()
        reading = Task { [weak self] in
            let sources = await TerraformPanelModel.blocking { () -> TerraformCauseChain.Sources in
                Self.sources(folder: folder, prefix: prefix, varFiles: varFiles)
            }
            guard let self, !Task.isCancelled, self.run === run else { return }
            self.sources = sources
            self.recause()
        }
    }

    nonisolated static func sources(folder: URL, prefix: String, varFiles: [String]) -> TerraformCauseChain.Sources {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var config: [(path: String, text: String)] = []
        var budget = TerraformConfigIndex.byteLimit
        for name in names.prefix(TerraformConfigIndex.fileLimit) where TerraformConfigIndex.isModuleFile(folder.appendingPathComponent(name)) {
            guard let data = TerraformRootFacts.smallFile(folder.appendingPathComponent(name), limit: TerraformConfigIndex.fileByteLimit),
                data.count <= budget
            else { continue }
            budget -= data.count
            config.append((prefix + name, String(decoding: data, as: UTF8.self)))
        }
        var vars: [(path: String, text: String)] = []
        for name in varFiles where TerraformCommands.isVarFile(name) {
            guard let data = TerraformRootFacts.smallFile(folder.appendingPathComponent(name), limit: 1 << 20) else { continue }
            vars.append((prefix + name, String(decoding: data, as: UTF8.self)))
        }
        return TerraformCauseChain.Sources.make(config: config, varFiles: vars)
    }

    /// The added lines of the diff's files: what "changed in this branch" reads.
    static func addedLines(_ diffs: [String: DiffModel.FileDiff]) -> [String: Set<Int>] {
        var lines: [String: Set<Int>] = [:]
        for (path, diff) in diffs where TerraformRootGuess.isTerraformName((path as NSString).lastPathComponent) {
            let added = diff.lines.compactMap { $0.kind == .added ? $0.newNumber : nil }
            if !added.isEmpty { lines[path] = Set(added) }
        }
        return lines
    }
}
