import Foundation

/// `terraform state list`'s answer: one address a line (analysis 2.4,
/// stage 2c). What the state view shows first — 0.16 s for 2,000 — while
/// `show -json` reads the values. Pure.
enum TerraformStateList {
    /// The most addresses kept: a state of any size lists, the rest said.
    static let maxAddresses = 20_000

    /// The addresses, as Terraform printed them, scrubbed and with
    /// non-printables escaped; blank lines and anything that isn't one dropped.
    static func parse(_ output: String) -> (addresses: [String], capped: Bool) {
        var addresses: [String] = []
        var capped = false
        for line in output.split(whereSeparator: \.isNewline) {
            let address = line.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty, address.contains("."), !address.hasPrefix("-"), address.count <= 1024 else { continue }
            guard addresses.count < maxAddresses else {
                capped = true
                break
            }
            addresses.append(TerraformPlanText.escaped(TerraformPlan.scrub(address)))
        }
        return (addresses, capped)
    }

    /// A resource's module from its address (`module.acme.module.b.aws_x.y[0]`
    /// is `module.acme.module.b`), nil for the root module's.
    static func module(of address: String) -> String? {
        var parts: [String] = []
        var rest = Substring(address)
        while rest.hasPrefix("module.") {
            let afterKeyword = rest.dropFirst("module.".count)
            // The call's name, then its key when it has one (`["eu"]`, `[0]`).
            guard let dot = Self.topLevelDot(in: afterKeyword) else { break }
            parts.append("module." + afterKeyword[..<dot])
            rest = afterKeyword[afterKeyword.index(after: dot)...]
        }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    /// The first `.` outside brackets and quotes.
    private static func topLevelDot(in text: Substring) -> Substring.Index? {
        var depth = 0
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\\" {
                    index = text.index(after: index)
                    if index == text.endIndex { break }
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth = max(0, depth - 1)
            } else if character == ".", depth == 0 {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// A state's JSON (`terraform show -json` with no file: the current
/// workspace's state), decoded through an allow-list (analysis 2.4, 5.6
/// rules 1–3, 9): per resource its address, module, mode, type, name,
/// index, provider, whether it is tainted or deposed, what it depends on,
/// and its `values` masked by `sensitive_values`, then by
/// `TerraformSecretNames`, then — a value marked sensitive anywhere is
/// masked everywhere it appears — by `TerraformSensitiveValues`, every
/// kept string through `scrub`; per output its name, its type in words,
/// whether it is sensitive, and its value only when it isn't. Everything
/// else — `schema_version`, any key a later Terraform adds — is dropped as
/// it is read; the raw data is not kept. There is no `state show -json`:
/// one resource is read from this. `output -json` and `output NAME`, which
/// print sensitive values, are never run. Pure.
struct TerraformState: Equatable, Sendable {
    struct Resource: Equatable, Sendable, Identifiable {
        var address: String
        /// Its module's address, nil for the root module's.
        var module: String?
        var mode: String
        var type: String
        var name: String
        var index: String?
        var provider: String
        /// Its attributes, masked: nil when the state has none.
        var values: TerraformValue?
        /// `terraform taint`'d, or a create that failed half way: replaced by the next apply.
        var tainted: Bool
        /// A deposed object's key (`create_before_destroy` left it).
        var deposed: String?
        var dependsOn: [String]

        var id: String { deposed.map { address + " (deposed \($0))" } ?? address }
        var isData: Bool { mode == "data" }
    }

    struct Output: Equatable, Sendable, Identifiable {
        var name: String
        /// Its type as HCL says it: `string`, `list(string)`, `object({…})`.
        var type: String
        var sensitive: Bool
        /// Only when it isn't sensitive — never otherwise, not even its length.
        var value: TerraformValue?

        var id: String { name }
    }

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case unknownFormat(String)

        var description: String {
            switch self {
            case .notJSON: "not a state's JSON"
            case .unknownFormat(let version): "a state format Overterm doesn't read (format_version \(version))"
            }
        }
    }

    var formatVersion: String
    var terraformVersion: String?
    var resources: [Resource] = []
    var outputs: [Output] = []
    /// More resources than `maxResources`: the rest left out, said.
    var capped = false

    static let maxResources = 20_000
    static let maxModuleDepth = 16

    /// The modules, in order: the root module's (nil) first, then by address.
    var modules: [String?] {
        let named = Set(resources.compactMap(\.module)).sorted()
        return (resources.contains { $0.module == nil } ? [nil] : []) + named.map { Optional($0) }
    }

    func resource(_ address: String) -> Resource? { resources.first { $0.address == address && $0.deposed == nil } ?? resources.first { $0.address == address } }

    // MARK: Decode

    /// `secretName`: the attribute names masked though unmarked —
    /// `TerraformSecretNames.isSecret` for the person's view, `forAgents`
    /// for what an agent reads (5.6 rule 4).
    static func decode(_ data: Data, scrub: @escaping (String) -> String = TerraformPlan.scrub, secretName: (String) -> Bool = TerraformSecretNames.isSecret)
        throws -> TerraformState
    {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { throw DecodeError.notJSON }
        return try decode(object, scrub: scrub, secretName: secretName)
    }

    static func decode(_ object: [String: Any], scrub given: @escaping (String) -> String = TerraformPlan.scrub, secretName: (String) -> Bool = TerraformSecretNames.isSecret)
        throws -> TerraformState
    {
        let format = object["format_version"] as? String ?? ""
        guard format.split(separator: ".").first == "1" else { throw DecodeError.unknownFormat(format.isEmpty ? "none" : format) }
        // Every value marked sensitive anywhere — an output, an attribute
        // under its mirror — is masked wherever it appears: a sensitive
        // variable copied into `terraform_data`'s `output`, then into an
        // output nobody marked, is still that value (redacted before
        // `scrub`, which could alter it past finding).
        let secrets = TerraformSensitiveValues(sensitiveValues(in: object))
        let scrub: (String) -> String = { text in given(secrets.isEmpty ? text : secrets.redact(text)) }
        let leaf: (String) -> TerraformValue = { text in secrets.isSecret(text) ? .sensitive : .string(given(text)) }
        var state = TerraformState(formatVersion: format, terraformVersion: (object["terraform_version"] as? String).map(scrub))
        guard let values = object["values"] as? [String: Any] else { return state }
        if let outputs = values["outputs"] as? [String: Any] {
            state.outputs = outputs.keys.sorted().prefix(TerraformPlan.maxItems).compactMap { name in
                guard let output = outputs[name] as? [String: Any] else { return nil }
                let sensitive = output["sensitive"] as? Bool ?? true
                // A type is structure — attribute names, `string`: escaped and
                // redacted, never `scrub`bed (its `password=string` would read as one).
                let type = TerraformPlanText.escaped(secrets.isEmpty ? typeName(output["type"]) : secrets.redact(typeName(output["type"])))
                return Output(
                    name: scrub(name), type: type, sensitive: sensitive,
                    value: sensitive
                        ? nil
                        : TerraformPlan.value(output["value"], sensitive: nil, name: name, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName)
                            ?? .null)
            }
        }
        if let root = values["root_module"] as? [String: Any] {
            collect(root, depth: 0, into: &state, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName)
        }
        return state
    }

    private static func collect(
        _ module: [String: Any], depth: Int, into state: inout TerraformState, scrub: (String) -> String, leaf: (String) -> TerraformValue,
        secrets: TerraformSensitiveValues, secretName: (String) -> Bool
    ) {
        guard depth <= maxModuleDepth else { return }
        let moduleAddress = (module["address"] as? String).map(scrub)
        for resource in module["resources"] as? [[String: Any]] ?? [] {
            guard state.resources.count < maxResources else {
                state.capped = true
                return
            }
            let index: String? = {
                switch resource["index"] {
                case let number as NSNumber: return number.stringValue
                case let string as String: return "\"" + scrub(string) + "\""
                default: return nil
                }
            }()
            state.resources.append(
                Resource(
                    address: TerraformPlanText.escaped(scrub(resource["address"] as? String ?? "?")), module: moduleAddress,
                    mode: resource["mode"] as? String == "data" ? "data" : "managed", type: scrub(resource["type"] as? String ?? "?"),
                    name: scrub(resource["name"] as? String ?? "?"), index: index, provider: scrub(resource["provider_name"] as? String ?? "?"),
                    values: TerraformPlan.value(
                        resource["values"], sensitive: resource["sensitive_values"], scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName),
                    tainted: resource["tainted"] as? Bool ?? false, deposed: (resource["deposed_key"] as? String).map(scrub),
                    dependsOn: (resource["depends_on"] as? [Any] ?? []).prefix(64).compactMap { ($0 as? String).map(scrub) }))
        }
        for child in module["child_modules"] as? [[String: Any]] ?? [] {
            collect(child, depth: depth + 1, into: &state, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName)
            if state.capped { return }
        }
    }

    /// The strings a state marks sensitive: a sensitive output's value,
    /// every attribute under a resource's `sensitive_values` mirror.
    /// Numbers by their text. Only what is hunted for; never kept.
    static func sensitiveValues(in object: [String: Any]) -> Set<String> {
        var found: Set<String> = []
        func collect(_ raw: Any?, _ mirror: Any?, marked: Bool, depth: Int) {
            guard found.count < TerraformPlan.maxSecrets, depth < TerraformPlan.maxDepth, let raw, !(raw is NSNull) else { return }
            let here = marked || TerraformPlan.isMarked(mirror)
            guard here || mirror is [Any] || mirror is [String: Any] else { return }
            switch raw {
            case let string as String:
                if here, !string.isEmpty { found.insert(string) }
            case let number as NSNumber:
                if here, CFGetTypeID(number) != CFBooleanGetTypeID() { found.insert(number.stringValue) }
            case let list as [Any]:
                let marks = mirror as? [Any]
                for (index, item) in list.prefix(TerraformPlan.maxItems).enumerated() {
                    collect(item, marks.flatMap { index < $0.count ? $0[index] : nil }, marked: here, depth: depth + 1)
                }
            case let fields as [String: Any]:
                let marks = mirror as? [String: Any]
                if !here, let marks {
                    for (key, mark) in marks.prefix(TerraformPlan.maxItems) { collect(fields[key], mark, marked: false, depth: depth + 1) }
                } else {
                    for (key, item) in fields.prefix(TerraformPlan.maxItems) { collect(item, marks?[key], marked: here, depth: depth + 1) }
                }
            default:
                break
            }
        }
        guard let values = object["values"] as? [String: Any] else { return found }
        for (_, output) in values["outputs"] as? [String: Any] ?? [:] {
            guard let output = output as? [String: Any] else { continue }
            // An output that doesn't say is taken as sensitive.
            collect(output["value"], nil, marked: output["sensitive"] as? Bool ?? true, depth: 0)
        }
        var modules: [([String: Any], Int)] = (values["root_module"] as? [String: Any]).map { [($0, 0)] } ?? []
        var resources = 0
        while let (module, depth) = modules.popLast() {
            for resource in module["resources"] as? [[String: Any]] ?? [] {
                resources += 1
                guard resources <= maxResources else { return found }
                collect(resource["values"], resource["sensitive_values"], marked: false, depth: 0)
            }
            if depth < maxModuleDepth {
                modules += (module["child_modules"] as? [[String: Any]] ?? []).map { ($0, depth + 1) }
            }
        }
        return found
    }

    /// A cty type as HCL writes it: `"string"`, `["list","string"]` →
    /// `list(string)`, `["object",{"a":"string"}]` → `object({a=string})`.
    static func typeName(_ type: Any?, depth: Int = 0) -> String {
        guard depth < 6 else { return "…" }
        switch type {
        case let name as String: return name
        case let parts as [Any]:
            guard let kind = parts.first as? String else { return "?" }
            let rest = parts.dropFirst()
            switch kind {
            case "list", "set", "map": return "\(kind)(\(typeName(rest.first, depth: depth + 1)))"
            case "tuple":
                let items = (rest.first as? [Any] ?? []).prefix(6).map { typeName($0, depth: depth + 1) }
                return "tuple([" + items.joined(separator: ", ") + ((rest.first as? [Any])?.count ?? 0 > 6 ? ", …" : "") + "])"
            case "object":
                let fields = rest.first as? [String: Any] ?? [:]
                let keys = fields.keys.sorted()
                let shown = keys.prefix(6).map { "\($0)=\(typeName(fields[$0], depth: depth + 1))" }
                return "object({" + shown.joined(separator: ", ") + (keys.count > 6 ? ", …" : "") + "})"
            default: return kind
            }
        default: return "?"
        }
    }

    /// This state as an agent reads it (5.6 rule 4): every value masked
    /// by the broad names too (`Secrets.isSecret`), an output so named
    /// sensitive.
    func forAgents() -> TerraformState {
        var state = self
        state.resources = resources.map { resource in
            var resource = resource
            resource.values = resource.values?.masked(by: TerraformSecretNames.forAgents)
            return resource
        }
        state.outputs = outputs.map { output in
            var output = output
            if TerraformSecretNames.forAgents(output.name) {
                output.sensitive = true
                output.value = nil
            } else {
                output.value = output.value?.masked(by: TerraformSecretNames.forAgents)
            }
            return output
        }
        return state
    }
}

/// The state view's rows (analysis 2.4, 6.3): resources grouped by
/// module, the root module's first, filtered by text over the address
/// and type. Pure.
enum TerraformStateRows {
    struct Group: Equatable, Sendable, Identifiable {
        /// The module's address; nil for the root module.
        var module: String?
        var addresses: [String]
        var id: String { module ?? "" }
        var title: String { module ?? "root module" }
    }

    /// `addresses` (from `state list`, or the decoded state's) grouped by module.
    static func groups(_ addresses: [String], filter: String = "") -> [Group] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String?] = []
        var byModule: [String: [String]] = [:]
        for address in addresses where needle.isEmpty || address.lowercased().contains(needle) {
            let module = TerraformStateList.module(of: address)
            let key = module ?? ""
            if byModule[key] == nil { order.append(module) }
            byModule[key, default: []].append(address)
        }
        let sorted = order.sorted { a, b in
            switch (a, b) {
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?): return a < b
            }
        }
        return sorted.map { Group(module: $0, addresses: byModule[$0 ?? ""] ?? []) }
    }

    /// Groups already made, as `filter` leaves them: the addresses that
    /// contain it, ignoring case, a group left out once empty — no module
    /// walked again. No filter: the groups themselves.
    static func filtered(_ groups: [Group], filter: String) -> [Group] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let addresses = group.addresses.filter { $0.range(of: needle, options: .caseInsensitive) != nil }
            return addresses.isEmpty ? nil : Group(module: group.module, addresses: addresses)
        }
    }

    /// One resource's attributes as lines (`name = value`), sorted, each
    /// value one line, masked as the model has it.
    static func attributes(_ resource: TerraformState.Resource, cut: Int = 200) -> [(name: String, value: String)] {
        guard case .object(let fields)? = resource.values else { return resource.values.map { [("value", $0.said(cut: cut))] } ?? [] }
        return fields.keys.sorted().map { key in (TerraformPlanText.escaped(key), fields[key]!.said(cut: cut)) }
    }
}

/// The state as text for an agent (`tf_state_list`, `tf_state_show`,
/// `tf_outputs`, analysis 5.10): addresses by module, one resource's
/// masked attributes, outputs with their type and — only when not
/// sensitive — their value. Strings cut at 200 characters. Pure.
enum TerraformStateText {
    static func list(_ addresses: [String], capped: Bool, root: String, limit: Int = 2_000) -> String {
        var lines = ["State of \(TerraformPlanText.escaped(root)): \(addresses.count) resource\(addresses.count == 1 ? "" : "s")\(capped ? " (more left out)" : "")."]
        var budget = limit
        for group in TerraformStateRows.groups(addresses) {
            guard budget > 0 else {
                lines.append("… (more left out)")
                break
            }
            lines.append("")
            lines.append(group.title + ":")
            for address in group.addresses {
                guard budget > 0 else { break }
                budget -= 1
                lines.append("  " + TerraformPlanText.escaped(address))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func resource(_ resource: TerraformState.Resource, root: String) -> String {
        var lines = ["\(TerraformPlanText.escaped(resource.address)) in \(TerraformPlanText.escaped(root)) (\(resource.isData ? "data source, " : "")\(resource.type), \(resource.provider))"]
        if resource.tainted { lines.append("Tainted: the next apply replaces it.") }
        if let deposed = resource.deposed { lines.append("Deposed object \(deposed): left by a create-before-destroy; the next apply deletes it.") }
        let attributes = TerraformStateRows.attributes(resource)
        if attributes.isEmpty { lines.append("No attributes in the state.") }
        for attribute in attributes.prefix(400) { lines.append("  \(attribute.name) = \(attribute.value)") }
        if attributes.count > 400 { lines.append("  … \(attributes.count - 400) more") }
        if !resource.dependsOn.isEmpty { lines.append("Depends on: " + resource.dependsOn.prefix(20).map(TerraformPlanText.escaped).joined(separator: ", ")) }
        lines.append("Masked by Terraform's sensitive marks and Overterm's rules: a value marked sensitive is never shown.")
        return lines.joined(separator: "\n")
    }

    static func outputs(_ outputs: [TerraformState.Output], root: String) -> String {
        guard !outputs.isEmpty else { return "\(TerraformPlanText.escaped(root)) has no outputs in its state." }
        var lines = ["Outputs of \(TerraformPlanText.escaped(root)) (\(outputs.count)):"]
        for output in outputs.prefix(500) {
            let head = "  \(TerraformPlanText.escaped(output.name)) (\(output.type))"
            if output.sensitive || output.value == nil {
                lines.append(head + ": sensitive — never shown")
            } else {
                lines.append(head + " = " + (output.value ?? .null).said(cut: TerraformPlanText.cutLength))
            }
        }
        lines.append("A sensitive output's value is never given, and no tool reads one.")
        return lines.joined(separator: "\n")
    }
}
