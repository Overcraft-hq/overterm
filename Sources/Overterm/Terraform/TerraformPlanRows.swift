import Foundation

/// The plan view's rows (analysis 6.3): drift first, yellow; then replace,
/// delete, forget and actions, red; creates and updates folded ×N where
/// the same change repeats; moves and imports, each a no-op with its
/// marker; data sources read, folded at the bottom. Filtered by `/` text
/// over the address and the action chips. Pure, from the masked model.
struct TerraformPlanRow: Equatable, Sendable, Identifiable {
    enum Section: String, Sendable, CaseIterable {
        case drift, risky, actions, changes, moved, imported, reads
    }

    var id: String
    var section: Section
    /// `±`, `-`, `⊘`, `+`, `~`, `→`, `⇣`, `⚠`, `⚡`, `≡`.
    var symbol: String
    var address: String
    /// What happens, in words: `replace (delete, then create) · can't change in place`.
    var what: String
    /// The changes folded into it: one, or ×N.
    var members: [TerraformPlan.ResourceChange] = []
    var action: TerraformPlan.ActionInvocation?

    var count: Int { max(1, members.count) }
    var first: TerraformPlan.ResourceChange? { members.first }
}

enum TerraformPlanRows {
    /// The chips (6.3): which actions show.
    enum Chip: String, CaseIterable, Sendable {
        case replace, delete, update, create

        func matches(_ action: TerraformPlan.Action) -> Bool {
            switch self {
            case .replace: action == .replace
            case .delete: action == .delete || action == .forget
            case .update: action == .update
            case .create: action == .create
            }
        }
    }

    static func build(_ plan: TerraformPlan, filter: String = "", chips: Set<Chip> = []) -> [TerraformPlanRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func shown(_ change: TerraformPlan.ResourceChange) -> Bool {
            if !needle.isEmpty, !change.address.lowercased().contains(needle), !(change.previousAddress?.lowercased().contains(needle) ?? false) {
                return false
            }
            return chips.isEmpty || chips.contains { $0.matches(change.action) }
        }
        var rows: [TerraformPlanRow] = []
        for (index, change) in plan.drift.enumerated() where needle.isEmpty || change.address.lowercased().contains(needle) {
            rows.append(
                TerraformPlanRow(
                    id: "drift.\(index).\(change.address)", section: .drift, symbol: "⚠", address: change.address,
                    what: driftWords(change), members: [change]))
        }
        let risky = plan.resourceChanges.filter { $0.isRisky && shown($0) }.sorted { rank($0) < rank($1) }
        for change in risky {
            rows.append(
                TerraformPlanRow(
                    id: "risky.\(change.address)", section: .risky, symbol: symbol(change.action), address: change.address, what: words(change),
                    members: [change]))
        }
        if chips.isEmpty || chips.contains(.delete) || chips.contains(.replace) {
            for action in plan.actions where needle.isEmpty || action.address.lowercased().contains(needle) {
                rows.append(
                    TerraformPlanRow(
                        id: "action.\(action.address)", section: .actions, symbol: "⚡", address: action.address,
                        what: "invoke \(action.type)" + (action.trigger.map { " · " + $0 } ?? ""), action: action))
            }
        }
        let changes = plan.resourceChanges.filter { ($0.action == .create || $0.action == .update) && shown($0) }
        for group in TerraformPlanText.fold(changes) {
            let first = group[0]
            var what = first.action == .create ? "create" : "update"
            if first.action == .update, !first.changedPaths.isEmpty { what += " · " + first.changedPaths.prefix(4).joined(separator: ", ") }
            if group.count > 1 { what += "   (\(group.count) resources, same change)" }
            if first.isMove { what += " · moved from \(first.previousAddress ?? "?")" }
            if let id = first.importingID { what += " · import ← \(id)" }
            rows.append(
                TerraformPlanRow(
                    id: "change.\(first.address)", section: .changes, symbol: first.action == .create ? "+" : "~",
                    address: first.address, what: what, members: group))
        }
        let quiet = plan.resourceChanges.filter { $0.action == .noop && shown($0) }
        if chips.isEmpty {
            for change in quiet where change.isMove {
                rows.append(
                    TerraformPlanRow(
                        id: "moved.\(change.address)", section: .moved, symbol: "→", address: change.address,
                        what: "moved from \(change.previousAddress ?? "?")", members: [change]))
            }
            for change in quiet where change.isImport && !change.isMove {
                rows.append(
                    TerraformPlanRow(
                        id: "imported.\(change.address)", section: .imported, symbol: "⇣", address: change.address,
                        what: "import ← \(change.importingID ?? "?")", members: [change]))
            }
            let reads = plan.resourceChanges.filter { $0.action == .read && shown($0) }
            if !reads.isEmpty {
                rows.append(
                    TerraformPlanRow(
                        id: "reads", section: .reads, symbol: "≡", address: reads.count == 1 ? reads[0].address : "\(reads.count) data sources",
                        what: "read during apply", members: reads))
            }
        }
        return rows
    }

    static func rank(_ change: TerraformPlan.ResourceChange) -> Int {
        switch change.action {
        case .replace: 0
        case .delete: 1
        case .forget: 2
        default: 3
        }
    }

    static func symbol(_ action: TerraformPlan.Action) -> String {
        switch action {
        case .create: "+"
        case .update: "~"
        case .delete: "-"
        case .replace: "±"
        case .forget: "⊘"
        case .read: "≡"
        case .noop: "·"
        }
    }

    /// `replace (delete, then create) · can't change in place`.
    static func words(_ change: TerraformPlan.ResourceChange) -> String {
        var what: String
        switch change.action {
        case .replace: what = change.createsFirst ? "replace (create, then delete)" : "replace (delete, then create)"
        case .delete: what = "delete"
        case .forget: what = "forget: kept in the cloud, out of state"
        default: what = change.action.rawValue
        }
        if let reason = change.reason { what += " · " + (TerraformPlanText.reasonWords[reason] ?? reason) }
        if !change.replacePaths.isEmpty {
            what += " · " + change.replacePaths.prefix(3).map { $0.joined(separator: ".") }.joined(separator: ", ") + " forces it"
        }
        return what
    }

    static func driftWords(_ change: TerraformPlan.ResourceChange) -> String {
        switch change.action {
        case .delete: "deleted outside Terraform"
        case .update: "changed outside Terraform" + (change.changedPaths.isEmpty ? "" : " · " + change.changedPaths.prefix(4).joined(separator: ", "))
        default: "\(change.action.rawValue) outside Terraform"
        }
    }
}

/// One resource's attributes, before → after (6.3's detail): walked with
/// what is known only after apply and the sensitive marks (••••••, never
/// a value, even on hover); the forcing attributes marked; unchanged ones
/// counted, folded; a long string — a policy, a script, JSON in a string,
/// pretty-printed first — diffed by line (`LineDiff`). Pure.
enum TerraformAttributeDiff {
    struct Line: Equatable, Sendable, Identifiable {
        var path: String
        var before: String?
        var after: String?
        var forces: Bool
        /// A long string's lines, diffed: nil for a short value.
        var text: [TextLine]? = nil
        var id: String { path }
    }

    /// One line of a long string's diff.
    struct TextLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case same, removed, added, gap }
        var kind: Kind
        var text: String

        var said: String {
            switch kind {
            case .same: "  " + text
            case .removed: "- " + text
            case .added: "+ " + text
            case .gap: "  …"
            }
        }
    }

    /// A string this long, or of several lines, or JSON, is diffed by line.
    static let longString = 80
    static let maxTextLines = 120
    static let context = 2

    static let masked = "••••••"

    /// The changed attributes' lines (at most `limit`) and how many are unchanged.
    static func lines(_ change: TerraformPlan.ResourceChange, limit: Int = 200) -> (lines: [Line], unchanged: Int) {
        let forcing = Set(change.replacePaths.map { $0.joined(separator: ".") })
        let before = flatten(change.before)
        let after = flatten(change.after)
        let changed = Set(change.changedPaths)
        var lines: [Line] = []
        var unchanged = 0
        let beforeText = strings(change.before)
        let afterText = strings(change.after)
        for path in Set(before.keys).union(after.keys).sorted() {
            let a = before[path]
            let b = after[path]
            let differs = a != b || changed.contains(path) || changed.contains { $0.hasPrefix(path + ".") || $0.hasPrefix(path + "[") }
            guard differs else {
                unchanged += 1
                continue
            }
            guard lines.count < limit else { break }
            var line = Line(path: path, before: a, after: b, forces: forcing.contains(path) || forcing.contains { path.hasPrefix($0 + ".") })
            if let old = beforeText[path], let new = afterText[path], isLong(old) || isLong(new) { line.text = textDiff(old, new) }
            lines.append(line)
        }
        return (lines, unchanged)
    }

    /// A value's leaves by path, said: strings cut, a sensitive one
    /// `masked`, an unknown one "known after apply".
    static func flatten(_ value: TerraformValue?, path: String = "", depth: Int = 0, into found: inout [String: String]) {
        guard let value else { return }
        switch value {
        case .object(let fields) where depth < 12 && !fields.isEmpty:
            for (key, field) in fields { flatten(field, path: path.isEmpty ? key : path + "." + key, depth: depth + 1, into: &found) }
        case .list(let items) where depth < 12 && !items.isEmpty && items.count <= 64:
            for (index, item) in items.enumerated() { flatten(item, path: "\(path)[\(index)]", depth: depth + 1, into: &found) }
        case .sensitive:
            if !path.isEmpty { found[path] = masked }
        case .unknown:
            if !path.isEmpty { found[path] = "known after apply" }
        default:
            if !path.isEmpty { found[path] = value.said(cut: 400) }
        }
    }

    static func flatten(_ value: TerraformValue?) -> [String: String] {
        var found: [String: String] = [:]
        flatten(value, into: &found)
        return found
    }

    /// A value's string leaves by path, whole — the masked model's, so a
    /// sensitive one is no string here.
    static func strings(_ value: TerraformValue?) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ value: TerraformValue, _ path: String, _ depth: Int) {
            switch value {
            case .object(let fields) where depth < 12:
                for (key, field) in fields { walk(field, path.isEmpty ? key : path + "." + key, depth + 1) }
            case .list(let items) where depth < 12 && items.count <= 64:
                for (index, item) in items.enumerated() { walk(item, "\(path)[\(index)]", depth + 1) }
            case .string(let text) where !path.isEmpty:
                found[path] = text
            default:
                break
            }
        }
        if let value { walk(value, "", 0) }
        return found
    }

    static func isLong(_ text: String) -> Bool { text.count > longString || text.contains("\n") || pretty(text) != nil }

    /// JSON in a string, pretty-printed with its keys sorted; nil when it isn't JSON.
    static func pretty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), trimmed.utf8.count <= 1 << 20,
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `before` against `after` by line, JSON pretty-printed first: the
    /// changed lines with `context` around them, the rest a gap.
    static func textDiff(_ before: String, _ after: String) -> [TextLine] {
        let a = pretty(before) ?? before
        let b = pretty(after) ?? after
        let old = a.components(separatedBy: "\n")
        let new = b.components(separatedBy: "\n")
        func cut(_ line: String) -> String { TerraformPlanText.cut(TerraformPlanText.escaped(line), to: 400) }
        var lines: [TextLine] = []
        var shownNew = 0
        for block in LineDiff.blocks(base: a, current: b) {
            let from = max(shownNew, block.bLow - context)
            if from > shownNew { lines.append(TextLine(kind: .gap, text: "")) }
            for index in from..<block.bLow where index < new.count { lines.append(TextLine(kind: .same, text: cut(new[index]))) }
            for index in block.aLow..<block.aHigh where index < old.count { lines.append(TextLine(kind: .removed, text: cut(old[index]))) }
            for index in block.bLow..<block.bHigh where index < new.count { lines.append(TextLine(kind: .added, text: cut(new[index]))) }
            let to = min(new.count, block.bHigh + context)
            for index in block.bHigh..<max(block.bHigh, to) { lines.append(TextLine(kind: .same, text: cut(new[index]))) }
            shownNew = max(shownNew, to)
            if lines.count >= maxTextLines { break }
        }
        if shownNew < new.count, !lines.isEmpty { lines.append(TextLine(kind: .gap, text: "")) }
        return Array(lines.prefix(maxTextLines))
    }
}

extension TerraformValue {
    /// The same value with every attribute `secret` names masked too: the
    /// plan a person reads is masked by `TerraformSecretNames`; what an
    /// agent reads also by `Secrets.isSecret`'s broader match (5.6 rule 4).
    func masked(by secret: (String) -> Bool, name: String? = nil, depth: Int = 0) -> TerraformValue {
        if let name, secret(name), self != .null, self != .unknown { return .sensitive }
        guard depth < 32 else { return self }
        switch self {
        case .object(let fields):
            return .object(fields.reduce(into: [:]) { $0[$1.key] = $1.value.masked(by: secret, name: $1.key, depth: depth + 1) })
        case .list(let items):
            return .list(items.map { $0.masked(by: secret, name: name, depth: depth + 1) })
        default:
            return self
        }
    }
}

extension TerraformPlan {
    /// This plan as an agent reads it (5.6 rule 4): every value masked
    /// again by `TerraformSecretNames.forAgents`.
    func forAgents() -> TerraformPlan {
        var plan = self
        func mask(_ change: ResourceChange) -> ResourceChange {
            var change = change
            change.before = change.before?.masked(by: TerraformSecretNames.forAgents)
            change.after = change.after?.masked(by: TerraformSecretNames.forAgents)
            return change
        }
        plan.resourceChanges = resourceChanges.map(mask)
        plan.drift = drift.map(mask)
        plan.outputs = outputs.map { output in
            var output = output
            if TerraformSecretNames.forAgents(output.name) {
                output.sensitive = true
                output.after = nil
            } else {
                output.after = output.after?.masked(by: TerraformSecretNames.forAgents)
            }
            return output
        }
        plan.actions = actions.map { action in
            var action = action
            action.config = action.config?.masked(by: TerraformSecretNames.forAgents)
            return action
        }
        return plan
    }
}

extension TerraformPlanText {
    /// `action_reason` in words (6.3).
    static let reasonWords: [String: String] = [
        "replace_because_cannot_update": "can't change in place",
        "replace_because_tainted": "tainted",
        "replace_by_request": "-replace asked for it",
        "replace_by_triggers": "replace_triggered_by",
        "delete_because_no_resource_config": "its block is gone from the configuration",
        "delete_because_wrong_repetition": "count or for_each changed",
        "delete_because_count_index": "its count index is gone",
        "delete_because_each_key": "its for_each key is gone",
        "delete_because_no_module": "its module call is gone",
        "delete_because_no_move_target": "a moved block's target is gone",
        "read_because_config_unknown": "its configuration is known only after apply",
        "read_because_dependency_pending": "a dependency changes first",
        "read_because_check_nested": "a check block reads it",
    ]

    /// "Copy summary" (2.2, 5.6 rule 8): the bar, the CLI's sentence, the
    /// risky rows with their causes, drift and actions — from the masked
    /// model, never `terraform show`'s text. For a pull request's comment.
    static func copySummary(
        _ plan: TerraformPlan, root: String, workspace: String, branch: String?, causes: [String: String] = [:], limit: Int = 60
    ) -> String {
        let counts = plan.counts
        var lines = ["Terraform plan · \(escaped(root)) · workspace \(escaped(workspace))" + (branch.map { " · \(escaped($0))" } ?? "")]
        lines.append("\(counts.bar)   \(counts.sentence)")
        if !plan.hasPriorState { lines.append("No prior state: everything in it is created anew.") }
        if plan.errored { lines.append("The plan errored.") }
        if !plan.complete { lines.append("Partial: not every change is in it.") }
        let rows = TerraformPlanRows.build(plan)
        let risky = rows.filter { $0.section == .risky || $0.section == .actions }
        if !risky.isEmpty {
            lines.append("")
            for row in risky.prefix(limit) {
                lines.append("\(row.symbol) \(escaped(row.address))  \(row.what)")
                if let cause = causes[row.address], !cause.isEmpty { lines.append("    " + cause) }
            }
            if risky.count > limit { lines.append("… \(risky.count - limit) more") }
        }
        let drift = rows.filter { $0.section == .drift }
        if !drift.isEmpty {
            lines.append("")
            lines.append("Changed outside Terraform:")
            for row in drift.prefix(limit) { lines.append("⚠ \(escaped(row.address))  \(row.what)") }
        }
        lines.append("")
        lines.append("Masked by Terraform's sensitive marks and Overterm's rules.")
        return lines.joined(separator: "\n")
    }

    /// One resource's masked diff, for an agent (`tf_plan_resource`).
    static func resource(_ change: TerraformPlan.ResourceChange, plan: TerraformPlan, cause: String? = nil) -> String {
        var lines = ["\(TerraformPlanRows.symbol(change.action)) \(escaped(change.address))  \(TerraformPlanRows.words(change))"]
        if let previous = change.previousAddress, previous != change.address { lines.append("Moved from \(escaped(previous)).") }
        if let id = change.importingID { lines.append("Imported from \(escaped(cut(id))).") }
        lines.append("Provider: \(escaped(change.provider))")
        if let cause, !cause.isEmpty { lines.append("Why: " + cause) }
        let diff = TerraformAttributeDiff.lines(change)
        for line in diff.lines {
            if let text = line.text {
                lines.append("  \(escaped(line.path)):" + (line.forces ? "   forces replacement" : ""))
                lines += text.prefix(60).map { "    " + $0.said }
                continue
            }
            let before = line.before.map { cut(escaped($0)) } ?? "(none)"
            let after = line.after.map { cut(escaped($0)) } ?? "(none)"
            lines.append("  \(escaped(line.path)): \(before) → \(after)" + (line.forces ? "   forces replacement" : ""))
        }
        if diff.unchanged > 0 { lines.append("  \(diff.unchanged) unchanged attribute\(diff.unchanged == 1 ? "" : "s")") }
        lines.append("Values marked sensitive show as ••••••; never their value.")
        return lines.joined(separator: "\n")
    }
}
