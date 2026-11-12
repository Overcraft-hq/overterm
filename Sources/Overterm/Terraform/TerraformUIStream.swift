import Foundation

/// One line of Terraform's machine-readable UI (`plan -json`, `init
/// -json`; analysis 4.15): `@level`, `@message`, `type`, `ui` "1.3". A
/// minor bump adds fields; an unknown major refuses ("this Terraform's
/// output is a version Overterm doesn't read"); a line that isn't JSON
/// (a panic) is kept as raw text. What is kept is named here — a
/// diagnostic through `TerraformValidation`'s allow-list (never a
/// snippet's values), every string scrubbed; the rest of a line is
/// dropped as it is read. The resource list and the counts never come
/// from here: `planned_change` omits no-ops (4.15), so they are
/// `show -json`'s. Pure.
enum TerraformUIMessage: Equatable, Sendable {
    /// `version`: the binary's version and the UI's.
    case version(terraform: String, ui: String)
    /// `planned_change`: an address and its action.
    case plannedChange(address: String, action: String)
    /// `refresh_start`, `refresh_complete`.
    case refresh(address: String, done: Bool)
    /// `resource_drift`.
    case drift(address: String, action: String)
    /// `apply_start`, `apply_progress`, `apply_complete`, `apply_errored`
    /// (stage 2a): a resource's step, by its address and the hook's action
    /// — a replace has two, `delete` and `create`, in either order. Never
    /// `apply_complete`'s `id_value`: an object's ID can be anything.
    case apply(address: String, action: String, step: ApplyStep, elapsed: Int?)
    /// `provision_*`: a provisioner's output under its resource, scrubbed.
    case provision(address: String, provisioner: String, step: ApplyStep, output: String?)
    /// `change_summary`: the CLI's own counts; `operation` `plan` or `apply`.
    case summary(add: Int, change: Int, remove: Int, importing: Int, operation: String)
    case diagnostic(TerraformDiagnostic)
    /// Any other line, by its `@message` (`log`, `init_output`, `outputs`…).
    case message(type: String, level: String, text: String)
    /// Not JSON at all: crash output, a panic.
    case raw(String)
    /// A `ui` major this doesn't read.
    case unknownMajor(String)

    enum ApplyStep: String, Sendable {
        case start, progress, complete, errored
    }

    static let supportedMajor = "1"
    /// A line past this is kept cut: a stream is an agent's or a cloud's, of any size.
    static let maxLine = 64 << 10

    static func decode(_ line: String, scrub: (String) -> String = TerraformPlan.scrub) -> TerraformUIMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.utf8.count <= maxLine * 16,
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return .raw(scrub(String(trimmed.prefix(maxLine)))) }
        let type = object["type"] as? String ?? ""
        let text = scrub(String((object["@message"] as? String ?? "").prefix(maxLine)))
        func address(_ key: String) -> String? {
            ((object[key] as? [String: Any])?["resource"] as? [String: Any])?["addr"] as? String
        }
        switch type {
        case "version":
            let ui = object["ui"] as? String ?? ""
            guard ui.split(separator: ".").first.map(String.init) == supportedMajor else { return .unknownMajor(scrub(ui)) }
            return .version(terraform: scrub(object["terraform"] as? String ?? "?"), ui: scrub(ui))
        case "planned_change":
            let change = object["change"] as? [String: Any]
            return .plannedChange(address: scrub(address("change") ?? "?"), action: scrub(change?["action"] as? String ?? "?"))
        case "resource_drift":
            let change = object["change"] as? [String: Any]
            return .drift(address: scrub(address("change") ?? "?"), action: scrub(change?["action"] as? String ?? "?"))
        case "apply_start", "apply_progress", "apply_complete", "apply_errored":
            let hook = object["hook"] as? [String: Any]
            let step = ApplyStep(rawValue: String(type.dropFirst("apply_".count))) ?? .progress
            return .apply(
                address: scrub(address("hook") ?? "?"), action: scrub(hook?["action"] as? String ?? "?"), step: step,
                elapsed: (hook?["elapsed_seconds"] as? NSNumber)?.intValue)
        case "provision_start", "provision_progress", "provision_complete", "provision_errored":
            let hook = object["hook"] as? [String: Any]
            let step: ApplyStep =
                switch type {
                case "provision_start": .start
                case "provision_complete": .complete
                case "provision_errored": .errored
                default: .progress
                }
            return .provision(
                address: scrub(address("hook") ?? "?"), provisioner: scrub(hook?["provisioner"] as? String ?? "?"), step: step,
                output: (hook?["output"] as? String).map { scrub(String($0.prefix(4_096))) })
        case "refresh_start", "refresh_complete":
            return .refresh(address: scrub(address("hook") ?? "?"), done: type == "refresh_complete")
        case "change_summary":
            let changes = object["changes"] as? [String: Any] ?? [:]
            func count(_ key: String) -> Int { (changes[key] as? NSNumber)?.intValue ?? 0 }
            return .summary(
                add: count("add"), change: count("change"), remove: count("remove"), importing: count("import"),
                operation: scrub(changes["operation"] as? String ?? "?"))
        case "diagnostic":
            guard let diagnostic = object["diagnostic"] as? [String: Any] else { return .message(type: type, level: "error", text: text) }
            return .diagnostic(TerraformValidation.decodeDiagnostic(diagnostic, scrub: scrub))
        default:
            return .message(type: scrub(type), level: scrub(object["@level"] as? String ?? "info"), text: text)
        }
    }

    /// The line the raw log shows for it.
    var logLine: String {
        switch self {
        case .version(let terraform, _): "Terraform \(terraform)"
        case .plannedChange(let address, let action): "\(address): plan to \(action)"
        case .refresh(let address, let done): done ? "\(address): refresh complete" : "\(address): refreshing state…"
        case .drift(let address, let action): "\(address): changed outside Terraform (\(action))"
        case .apply(let address, let action, let step, let elapsed):
            switch step {
            case .start: "\(address): \(Self.progressive(action))…"
            case .progress: "\(address): still \(Self.progressive(action))… [\(elapsed ?? 0)s elapsed]"
            case .complete: "\(address): \(Self.done(action)) after \(elapsed ?? 0)s"
            case .errored: "\(address): \(action) failed after \(elapsed ?? 0)s"
            }
        case .provision(let address, let provisioner, let step, let output):
            switch step {
            case .start: "\(address): provisioning with '\(provisioner)'…"
            case .progress: "\(address) (\(provisioner)): \(output ?? "")"
            case .complete: "\(address): \(provisioner) done"
            case .errored: "\(address): \(provisioner) failed"
            }
        case .summary(let add, let change, let remove, let importing, let operation):
            "\(operation == "apply" ? "Apply" : "Plan"): \(importing > 0 ? "\(importing) to import, " : "")\(add) to add, \(change) to change, \(remove) to destroy."
        case .diagnostic(let diagnostic):
            "\(diagnostic.severity == .error ? "Error" : "Warning"): \(diagnostic.summary)" + (diagnostic.detail.isEmpty ? "" : " — " + diagnostic.detail)
        case .message(_, _, let text): text
        case .raw(let text): text
        case .unknownMajor(let ui): "This Terraform's output is a version Overterm doesn't read (ui \(ui)): run it in a terminal."
        }
    }
}

extension TerraformUIMessage {
    /// "Creating", as the CLI says a hook's action going.
    static func progressive(_ action: String) -> String {
        switch action {
        case "create": "Creating"
        case "update": "Modifying"
        case "delete": "Destroying"
        case "read": "Reading"
        case "noop": "Checking"
        default: action.capitalized
        }
    }

    /// "Creation complete".
    static func done(_ action: String) -> String {
        switch action {
        case "create": "Creation complete"
        case "update": "Modifications complete"
        case "delete": "Destruction complete"
        case "read": "Read complete"
        default: action.capitalized + " complete"
        }
    }
}
