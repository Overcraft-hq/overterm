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
    /// `change_summary`: the CLI's own counts; `operation` `plan` or `apply`.
    case summary(add: Int, change: Int, remove: Int, importing: Int, operation: String)
    case diagnostic(TerraformDiagnostic)
    /// Any other line, by its `@message` (`log`, `init_output`, `outputs`…).
    case message(type: String, level: String, text: String)
    /// Not JSON at all: crash output, a panic.
    case raw(String)
    /// A `ui` major this doesn't read.
    case unknownMajor(String)

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
