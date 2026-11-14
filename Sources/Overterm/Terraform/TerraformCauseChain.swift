import Foundation

/// Why a resource is replaced, down to the line this branch changed
/// (analysis 3.1): `replace_paths` names the forcing attribute;
/// `configuration…expressions.<attr>.references` what it reads; a variable
/// resolves to the var file line that sets it (the last one a run loads
/// wins) or its default, a local to its line; the diff's added lines say
/// which of those this branch changed. Replace and delete rows only — the
/// floor. Pure.
///
/// ```
/// ± random_pet.acme   replaced
///     ← prefix                 (replace_paths)
///     ← var.acme_name          (references)
///     ← envs/acme-prod.tfvars:3   changed in this branch
/// ```
enum TerraformCauseChain {
    /// A line of a file, relative to the checkout (the diff's spelling).
    struct Location: Equatable, Hashable, Sendable {
        var file: String
        var line: Int
        var said: String { "\(file):\(line)" }
    }

    /// Where a root's variables and locals get their values, read from its
    /// files by `make`.
    struct Sources: Equatable, Sendable {
        /// A variable's `default` line (its block's when it has none).
        var defaults: [String: Location] = [:]
        /// The line of the var file that sets it last, in the run's order.
        var assignments: [String: Location] = [:]
        var locals: [String: Location] = [:]
        /// Resources and modules by address: their block's first line.
        var blocks: [String: Location] = [:]

        /// From the root's `.tf` files and the var files the run loads, in
        /// the order it loads them (`terraform.tfvars`, `*.auto.tfvars`
        /// alphabetically, then each `-var-file`): paths relative to the checkout.
        static func make(config: [(path: String, text: String)], varFiles: [(path: String, text: String)]) -> Sources {
            var sources = Sources()
            for file in config {
                let text = file.text as NSString
                for block in TerraformBlocks.scan(file.text).blocks {
                    switch block.type {
                    case "variable":
                        guard let name = block.labels.first else { continue }
                        let range = block.attributes.first { $0.name == "default" }?.nameRange ?? block.nameRange
                        sources.defaults[name] = Location(file: file.path, line: line(of: range.location, in: text))
                    case "locals":
                        for attribute in block.attributes {
                            sources.locals[attribute.name] = Location(file: file.path, line: line(of: attribute.nameRange.location, in: text))
                        }
                    default:
                        if let address = TerraformConfigIndex.address(of: block), block.type == "resource" || block.type == "module" || block.type == "data" {
                            sources.blocks[address] = Location(file: file.path, line: line(of: block.range.location, in: text))
                        }
                    }
                }
            }
            for file in varFiles where !file.path.hasSuffix(".json") {
                let text = file.text as NSString
                for attribute in TerraformBlocks.scan(file.text).attributes {
                    sources.assignments[attribute.name] = Location(file: file.path, line: line(of: attribute.nameRange.location, in: text))
                }
            }
            return sources
        }

        static func line(of offset: Int, in text: NSString) -> Int {
            var line = 1
            var index = 0
            let end = min(offset, text.length)
            while index < end {
                if text.character(at: index) == 0x0A { line += 1 }
                index += 1
            }
            return line
        }
    }

    /// One step of a chain.
    struct Link: Equatable, Sendable {
        var text: String
        /// What it says comes from: kind of step.
        var kind: Kind
        var location: Location?
        /// This branch changed that line.
        var changed = false

        enum Kind: String, Sendable { case attribute, reference, line, reason }
    }

    static let maxPaths = 3
    static let maxReferences = 3

    /// The chain of `change`: its forcing attributes, what each reads, the
    /// lines those come from, `changed` the diff's added lines by file.
    static func chain(
        for change: TerraformPlan.ResourceChange, plan: TerraformPlan, sources: Sources, changed: [String: Set<Int>]
    ) -> [Link] {
        guard change.action == .replace || change.action == .delete || change.action == .forget else { return [] }
        var links: [Link] = []
        let address = TerraformPlanText.configAddress(change)
        for path in change.replacePaths.prefix(maxPaths) {
            let attribute = path.first ?? "?"
            links.append(Link(text: path.joined(separator: "."), kind: .attribute))
            for reference in (plan.references[address]?[attribute] ?? []).prefix(maxReferences) {
                links.append(Link(text: reference, kind: .reference))
                if let location = location(of: reference, in: sources) {
                    links.append(Link(text: location.said, kind: .line, location: location, changed: changed[location.file]?.contains(location.line) == true))
                }
            }
        }
        if links.isEmpty, let reason = change.reason, let words = TerraformPlanText.reasonWords[reason] {
            links.append(Link(text: words, kind: .reason))
        }
        return links
    }

    /// Where a reference's value comes from: `var.x` the var file line that
    /// sets it, else its default; `local.x` its line. Others (a resource's
    /// attribute) have none here.
    static func location(of reference: String, in sources: Sources) -> Location? {
        let parts = reference.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let name = parts[1].split(separator: "[").first.map(String.init) ?? parts[1]
        switch parts[0] {
        case "var": return sources.assignments[name] ?? sources.defaults[name]
        case "local": return sources.locals[name]
        default: return nil
        }
    }

    /// The chain as one line: `← length ← var.acme_db_length ← envs/prod/prod.tfvars:7  changed in this branch`.
    static func said(_ links: [Link]) -> String {
        links.map { "← " + $0.text + ($0.changed ? "  changed in this branch" : "") }.joined(separator: " ")
    }

    /// Every replace's and delete's chain, said, by address: Copy
    /// summary's, the plan view's and an agent's (`tf_plan_summary`,
    /// `tf_run_status`) alike — over the whole plan, whatever is filtered.
    static func texts(plan: TerraformPlan, sources: Sources, changed: [String: Set<Int>]) -> [String: String] {
        var texts: [String: String] = [:]
        for change in plan.resourceChanges where change.isRisky {
            let links = chain(for: change, plan: plan, sources: sources, changed: changed)
            if !links.isEmpty { texts[change.address] = said(links) }
        }
        return texts
    }
}
