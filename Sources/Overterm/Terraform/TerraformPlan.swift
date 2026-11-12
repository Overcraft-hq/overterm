import Foundation

/// A value of a plan, masked at decode (analysis 5.6 rule 2): what
/// Terraform marks sensitive is `.sensitive` — the value itself never
/// reaches the model — and what isn't known until apply is `.unknown`.
/// Pure.
indirect enum TerraformValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case list([TerraformValue])
    case object([String: TerraformValue])
    case sensitive
    case unknown

    /// One line of it, strings cut at `cut` characters: what an agent and
    /// a row read. A sensitive value is `(sensitive)`, never its length.
    func said(cut: Int = 200, depth: Int = 0) -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value
        case .string(let value): return "\"" + TerraformPlanText.cut(TerraformPlanText.escaped(value), to: cut) + "\""
        case .sensitive: return "(sensitive)"
        case .unknown: return "(known after apply)"
        case .list(let items):
            guard depth < 3 else { return "[…]" }
            let shown = items.prefix(8).map { $0.said(cut: cut, depth: depth + 1) }
            return "[" + shown.joined(separator: ", ") + (items.count > 8 ? ", … \(items.count - 8) more" : "") + "]"
        case .object(let fields):
            guard depth < 3 else { return "{…}" }
            let keys = fields.keys.sorted()
            let shown = keys.prefix(8).map { "\($0) = \(fields[$0]!.said(cut: cut, depth: depth + 1))" }
            return "{" + shown.joined(separator: ", ") + (keys.count > 8 ? ", … \(keys.count - 8) more" : "") + "}"
        }
    }
}

/// The attribute names whose values are secret though no provider marked
/// them (analysis 5.6 rule 4): narrower than `Secrets.isSecret`, whose
/// substring match on `KEY`, `AUTH`, `SESSION`, `TOKEN` would hide
/// `key_name`, `public_key`, `kms_key_id`, `ssh_keys`, `session_name` and
/// `auth_mode` — exactly what a reviewer must see change. Pure.
enum TerraformSecretNames {
    static let names: Set<String> = [
        "password", "secret", "private_key", "client_secret", "token", "connection_string", "sas_token", "secret_key", "access_key",
        "secret_access_key", "auth_token", "api_key", "master_password", "admin_password",
    ]
    static let suffixes = ["_password", "_pem", "_secret", "_token"]

    static func isSecret(_ name: String) -> Bool {
        let name = name.lowercased()
        return names.contains(name) || suffixes.contains { name.hasSuffix($0) }
    }

    /// What goes to an agent: also `Secrets.isSecret`'s broad match, where
    /// hiding too much costs little (`private_key_id`, `session_key`).
    static func forAgents(_ name: String) -> Bool { isSecret(name) || Secrets.isSecret(name) }
}

/// A plan's JSON (`terraform show -json <plan>`), decoded through an
/// allow-list (analysis 5.6 rule 1): what is kept is named below, and
/// everything else — `variables`' values, `planned_values`, `prior_state`'s
/// values, `configuration`'s `constant_value`s, `relevant_attributes`, a
/// check's problems, any key a later Terraform adds — is dropped as it is
/// read, so a new field can't leak by default. Every kept value is masked
/// by Terraform's `*_sensitive` mirrors, then by `TerraformSecretNames`,
/// and every kept string goes through `scrub` (`Secrets`' rules). The raw
/// data is not kept. Pure.
struct TerraformPlan: Equatable, Sendable {
    enum Action: String, Sendable, CaseIterable {
        case create, update, delete, replace, read, noop, forget
    }

    struct ResourceChange: Equatable, Sendable {
        var address: String
        var previousAddress: String?
        var module: String?
        var mode: String
        var type: String
        var name: String
        var index: String?
        var provider: String
        /// Terraform's `actions`, as it wrote them.
        var actions: [String]
        var reason: String?
        /// `replace_paths`, each a path of names and indexes.
        var replacePaths: [[String]]
        var importingID: String?
        var before: TerraformValue?
        var after: TerraformValue?
        /// The attribute paths whose values differ — read from the raw
        /// values before they were masked, kept as paths only.
        var changedPaths: [String]

        var action: Action {
            switch Set(actions) {
            case ["create"]: .create
            case ["update"]: .update
            case ["delete"]: .delete
            case ["delete", "create"]: .replace
            case ["read"]: .read
            case ["forget"]: .forget
            case ["create", "forget"]: .replace
            default: actions.contains("delete") ? .delete : .noop
            }
        }

        /// Destroy first (`["delete", "create"]`) or create first.
        var createsFirst: Bool { actions == ["create", "delete"] }
        var isMove: Bool { previousAddress != nil && previousAddress != address }
        var isImport: Bool { importingID != nil }
        /// Replace, delete, forget: first, red (6.3).
        var isRisky: Bool { [.replace, .delete, .forget].contains(action) }

        /// The rows folded into one ×N (2.2): same type, same actions, same
        /// paths changed and forcing, the index aside.
        var foldKey: String {
            let base = index.map { _ in address.replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression) } ?? address
            return [base, actions.joined(separator: ","), changedPaths.joined(separator: ","), replacePaths.map { $0.joined(separator: ".") }.joined(separator: ",")]
                .joined(separator: "\u{0}")
        }
    }

    struct OutputChange: Equatable, Sendable {
        var name: String
        var actions: [String]
        var sensitive: Bool
        /// Its value after, only when neither mirror marks it.
        var after: TerraformValue?
    }

    struct Variable: Equatable, Sendable {
        var name: String
        var sensitive: Bool
        var ephemeral: Bool
    }

    struct ActionInvocation: Equatable, Sendable {
        var address: String
        var type: String
        var trigger: String?
        /// Its configuration, masked by `config_sensitive`.
        var config: TerraformValue?
    }

    struct Check: Equatable, Sendable {
        var address: String
        var status: String
    }

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case unknownFormat(String)

        var description: String {
            switch self {
            case .notJSON: "not a plan's JSON"
            case .unknownFormat(let version): "a plan format Overterm doesn't read (format_version \(version))"
            }
        }
    }

    var formatVersion: String
    var terraformVersion: String?
    var applyable: Bool
    var complete: Bool
    var errored: Bool
    var timestamp: String?
    var resourceChanges: [ResourceChange] = []
    var drift: [ResourceChange] = []
    var outputs: [OutputChange] = []
    var variables: [Variable] = []
    var actions: [ActionInvocation] = []
    var checks: [Check] = []
    /// `prior_state`'s `terraform_version`: none on an empty workspace (spike 16).
    var priorStateVersion: String?
    var hasPriorState = false
    /// What each resource's attributes read, by address then attribute,
    /// from `configuration` (only `references`, never a `constant_value`):
    /// the first links of a cause chain (3.1).
    var references: [String: [String: [String]]] = [:]
    /// Top-level keys this decoder doesn't know (4.15): the plan is only
    /// partly understood.
    var unknownKeys: [String] = []

    var partlyUnderstood: Bool { !unknownKeys.isEmpty }

    /// The top-level keys read (or knowingly dropped).
    static let knownKeys: Set<String> = [
        "format_version", "terraform_version", "variables", "planned_values", "resource_drift", "resource_changes", "output_changes", "prior_state",
        "configuration", "relevant_attributes", "checks", "timestamp", "applyable", "complete", "errored", "action_invocations", "deferred_changes",
        "deferred_action_invocations",
    ]

    /// Bounds: a plan is an agent's or a cloud's, of any size.
    static let maxResources = 20_000
    static let maxDepth = 32
    static let maxItems = 2_000

    // MARK: Decode

    /// `secretName`: the attribute names masked though unmarked —
    /// `TerraformSecretNames` for the person's view, `forAgents` for what
    /// an agent reads (5.6 rule 4).
    static func decode(_ data: Data, scrub: (String) -> String, secretName: (String) -> Bool = TerraformSecretNames.isSecret) throws -> TerraformPlan {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { throw DecodeError.notJSON }
        return try decode(object, scrub: scrub, secretName: secretName)
    }

    /// `secrets`: the plan's sensitive values when the caller read them
    /// already (`TerraformValueMask`, an apply's); else read here.
    static func decode(
        _ object: [String: Any], scrub: (String) -> String, secretName: (String) -> Bool = TerraformSecretNames.isSecret,
        secrets known: TerraformSensitiveValues? = nil
    ) throws -> TerraformPlan {
        let format = object["format_version"] as? String ?? ""
        guard format.split(separator: ".").first == "1" else { throw DecodeError.unknownFormat(format.isEmpty ? "none" : format) }
        // A value Terraform marks sensitive anywhere in the plan is masked
        // everywhere it appears: a sensitive variable's value copied into
        // an attribute nothing marks (`terraform_data`'s `output` keeps
        // its `input` unmarked in state) is still that value.
        // Redacted before `scrub`: a secret the scrubber altered would no
        // longer be found. A leaf equal to one is masked whole, whatever
        // its length or type; only a longer one is hunted inside strings.
        let secrets = known ?? TerraformSensitiveValues(sensitiveValues(in: object))
        return try withoutActuallyEscaping(scrub) { given in
            // Keys and short values repeat across a plan's resources (every
            // `tags`, `input`, `label0`): each is scrubbed once.
            var redacted: [String: String] = [:]
            var plain: [String: TerraformValue] = [:]
            var kept = 0
            let scrub: (String) -> String = { bridged in
                var text = bridged
                text.makeContiguousUTF8()
                if let known = redacted[text] { return known }
                let done = secrets.isEmpty ? given(text) : given(secrets.redact(text))
                if redacted.count < memoEntries, kept < memoBytes {
                    redacted[text] = done
                    kept += text.utf8.count
                }
                return done
            }
            // A value's string, once per distinct string: masked whole when
            // it is, or holds, a sensitive value; else scrubbed.
            let leaf: (String) -> TerraformValue = { bridged in
                var text = bridged
                text.makeContiguousUTF8()
                if let known = plain[text] { return known }
                let done: TerraformValue = secrets.isSecret(text) ? .sensitive : .string(given(text))
                if plain.count < memoEntries, kept < memoBytes {
                    plain[text] = done
                    kept += text.utf8.count
                }
                return done
            }
            return try decodeMasked(object, format: format, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName)
        }
    }

    /// What `decode` remembers of `scrub`'s answers: this many strings,
    /// this many bytes of them.
    static let memoEntries = 100_000
    static let memoBytes = 16 << 20

    private static func decodeMasked(
        _ object: [String: Any], format: String, scrub: (String) -> String, leaf: (String) -> TerraformValue, secrets: TerraformSensitiveValues,
        secretName: (String) -> Bool
    ) throws -> TerraformPlan {
        var plan = TerraformPlan(
            formatVersion: format, terraformVersion: (object["terraform_version"] as? String).map(scrub), applyable: object["applyable"] as? Bool ?? false,
            complete: object["complete"] as? Bool ?? true, errored: object["errored"] as? Bool ?? false,
            timestamp: (object["timestamp"] as? String).map(scrub))
        plan.unknownKeys = object.keys.filter { !knownKeys.contains($0) }.sorted().map(scrub)
        plan.resourceChanges = (object["resource_changes"] as? [[String: Any]] ?? []).prefix(maxResources).map { change($0, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName) }
        plan.drift = (object["resource_drift"] as? [[String: Any]] ?? []).prefix(maxResources).map { change($0, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName) }
        if let outputs = object["output_changes"] as? [String: Any] {
            plan.outputs = outputs.keys.sorted().compactMap { name in
                guard let change = outputs[name] as? [String: Any] else { return nil }
                let sensitive = isMarked(change["before_sensitive"]) || isMarked(change["after_sensitive"])
                return OutputChange(
                    name: scrub(name), actions: strings(change["actions"]), sensitive: sensitive,
                    after: sensitive
                        ? nil
                        : value(
                            change["after"], sensitive: change["after_sensitive"], unknown: change["after_unknown"], name: name, scrub: scrub, leaf: leaf,
                            secrets: secrets, secretName: secretName))
            }
        }
        if let prior = object["prior_state"] as? [String: Any] {
            plan.hasPriorState = true
            plan.priorStateVersion = (prior["terraform_version"] as? String).map(scrub)
        }
        if let configuration = object["configuration"] as? [String: Any], let root = configuration["root_module"] as? [String: Any] {
            if let variables = root["variables"] as? [String: Any] {
                plan.variables = variables.keys.sorted().map { name in
                    let variable = variables[name] as? [String: Any] ?? [:]
                    return Variable(name: scrub(name), sensitive: variable["sensitive"] as? Bool ?? false, ephemeral: variable["ephemeral"] as? Bool ?? false)
                }
            }
            collectReferences(root, module: nil, into: &plan.references, scrub: scrub, depth: 0)
        }
        plan.actions = (object["action_invocations"] as? [[String: Any]] ?? []).prefix(maxItems).map { invocation in
            let trigger = (invocation["lifecycle_action_trigger"] as? [String: Any]).map { trigger in
                [trigger["action_trigger_event"] as? String, (trigger["triggering_resource_address"] as? String).map { "of " + $0 }].compactMap { $0 }
                    .joined(separator: " ")
            }
            return ActionInvocation(
                address: scrub(invocation["address"] as? String ?? "?"), type: scrub(invocation["type"] as? String ?? "?"), trigger: trigger.map(scrub),
                config: value(
                    invocation["config_values"], sensitive: invocation["config_sensitive"], unknown: invocation["config_unknown"], scrub: scrub, leaf: leaf,
                    secrets: secrets, secretName: secretName))
        }
        plan.checks = (object["checks"] as? [[String: Any]] ?? []).prefix(maxItems).compactMap { check in
            let address = (check["address"] as? [String: Any])?["to_display"] as? String
            guard let address, let status = check["status"] as? String else { return nil }
            return Check(address: scrub(address), status: scrub(status))
        }
        return plan
    }

    private static func change(
        _ object: [String: Any], scrub: (String) -> String, leaf: (String) -> TerraformValue, secrets: TerraformSensitiveValues, secretName: (String) -> Bool
    ) -> ResourceChange {
        let change = object["change"] as? [String: Any] ?? [:]
        let index: String? = {
            switch object["index"] {
            case let number as NSNumber: return number.stringValue
            case let string as String: return "\"" + scrub(string) + "\""
            default: return nil
            }
        }()
        let replacePaths = (change["replace_paths"] as? [[Any]] ?? []).prefix(maxItems).map { path in
            path.map { step -> String in
                if let number = step as? NSNumber { return number.stringValue }
                return scrub(step as? String ?? "?")
            }
        }
        var changed: [String] = []
        differences(change["before"], change["after"], unknown: change["after_unknown"], path: "", into: &changed, depth: 0)
        return ResourceChange(
            address: scrub(object["address"] as? String ?? "?"), previousAddress: (object["previous_address"] as? String).map(scrub),
            module: (object["module_address"] as? String).map(scrub), mode: object["mode"] as? String ?? "managed", type: scrub(object["type"] as? String ?? "?"),
            name: scrub(object["name"] as? String ?? "?"), index: index, provider: scrub(object["provider_name"] as? String ?? "?"),
            actions: strings(change["actions"]), reason: (object["action_reason"] as? String).map(scrub), replacePaths: Array(replacePaths),
            importingID: ((change["importing"] as? [String: Any])?["id"] as? String).map(scrub),
            before: value(change["before"], sensitive: change["before_sensitive"], scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName),
            after: value(
                change["after"], sensitive: change["after_sensitive"], unknown: change["after_unknown"], scrub: scrub, leaf: leaf, secrets: secrets,
                secretName: secretName),
            changedPaths: Array(changed.prefix(200)).map(scrub))
    }

    private static func strings(_ value: Any?) -> [String] { (value as? [Any] ?? []).compactMap { $0 as? String } }

    /// A mirror that marks the whole value (`true`).
    static func isMarked(_ mirror: Any?) -> Bool { (mirror as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false }

    /// `raw` masked by its `sensitive` mirror, its `unknown` one, and its
    /// attribute's `name`; nil for an absent value (a delete's `after`).
    /// `leaf`: what scrubs a value's string (`scrub` without the redaction:
    /// a leaf is checked against `secrets` whole first, and masked whole).
    static func value(
        _ raw: Any?, sensitive: Any?, unknown: Any? = nil, name: String? = nil, scrub: (String) -> String, leaf: (String) -> TerraformValue,
        secrets: TerraformSensitiveValues = .none, secretName: (String) -> Bool = TerraformSecretNames.isSecret
    ) -> TerraformValue? {
        if isMarked(sensitive) { return .sensitive }
        if isMarked(unknown) { return .unknown }
        guard let raw, !(raw is NSNull) else { return nil }
        return masked(raw, sensitive: sensitive, unknown: unknown, name: name, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName, depth: 0)
    }

    private static func masked(
        _ raw: Any, sensitive: Any?, unknown: Any?, name: String?, scrub: (String) -> String, leaf: (String) -> TerraformValue, secrets: TerraformSensitiveValues,
        secretName: (String) -> Bool, depth: Int
    ) -> TerraformValue {
        if isMarked(sensitive) { return .sensitive }
        if isMarked(unknown) { return .unknown }
        guard depth < maxDepth else { return .string("…") }
        switch raw {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            // A sensitive number (a PIN, an account) copied where nothing marks it.
            return name.map(secretName) == true || secrets.isSecret(number.stringValue) ? .sensitive : .number(number.stringValue)
        case let string as String:
            if name.map(secretName) == true { return .sensitive }
            // Equal to, or holding, a value marked sensitive elsewhere: the
            // whole leaf is — `leaf` decides, once per distinct string, on
            // native UTF-8 (one bridged from JSONSerialization walks slowly).
            return leaf(string)
        case let list as [Any]:
            let marks = sensitive as? [Any]
            let unknowns = unknown as? [Any]
            return .list(
                list.prefix(maxItems).enumerated().map { index, item in
                    masked(
                        item, sensitive: marks.flatMap { index < $0.count ? $0[index] : nil }, unknown: unknowns.flatMap { index < $0.count ? $0[index] : nil },
                        name: name, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName, depth: depth + 1)
                })
        case let object as [String: Any]:
            let marks = sensitive as? [String: Any]
            let unknowns = unknown as? [String: Any]
            var fields: [String: TerraformValue] = [:]
            for key in object.keys.sorted().prefix(maxItems) {
                fields[scrub(key)] = masked(
                    object[key]!, sensitive: marks?[key], unknown: unknowns?[key], name: key, scrub: scrub, leaf: leaf, secrets: secrets, secretName: secretName,
                    depth: depth + 1)
            }
            // Attributes known only after apply have no value in `after`.
            for (key, mark) in unknowns ?? [:] where object[key] == nil && isMarked(mark) { fields[scrub(key)] = .unknown }
            return .object(fields)
        default:
            return .null
        }
    }

    /// The paths where `before` and `after` differ, compared raw — only
    /// the paths are kept. An attribute known after apply counts as changed.
    private static func differences(_ before: Any?, _ after: Any?, unknown: Any?, path: String, into found: inout [String], depth: Int) {
        guard found.count < 200 else { return }
        if isMarked(unknown) {
            if !path.isEmpty { found.append(path) }
            return
        }
        if depth < maxDepth, let a = before as? [String: Any], let b = after as? [String: Any] {
            let unknowns = unknown as? [String: Any]
            for key in Set(a.keys).union(b.keys).union(unknowns.map { Array($0.keys) } ?? []).sorted() {
                differences(a[key], b[key], unknown: unknowns?[key], path: path.isEmpty ? key : path + "." + key, into: &found, depth: depth + 1)
            }
            return
        }
        if depth < maxDepth, let a = before as? [Any], let b = after as? [Any], a.count == b.count {
            let unknowns = unknown as? [Any]
            for index in a.indices {
                differences(a[index], b[index], unknown: unknowns.flatMap { index < $0.count ? $0[index] : nil }, path: "\(path)[\(index)]", into: &found, depth: depth + 1)
            }
            return
        }
        guard before != nil || after != nil, !path.isEmpty else { return }
        let same: Bool
        if let a = before as? NSObject, let b = after as? NSObject { same = a.isEqual(b) } else { same = (before == nil || before is NSNull) && (after == nil || after is NSNull) }
        if !same { found.append(path) }
    }

    private static func collectReferences(
        _ module: [String: Any], module prefix: String?, into references: inout [String: [String: [String]]], scrub: (String) -> String, depth: Int
    ) {
        guard depth < 8 else { return }
        for resource in (module["resources"] as? [[String: Any]] ?? []).prefix(maxItems) {
            guard let address = resource["address"] as? String, let expressions = resource["expressions"] as? [String: Any] else { continue }
            var attributes: [String: [String]] = [:]
            for (attribute, expression) in expressions {
                guard let refs = (expression as? [String: Any])?["references"] as? [String], !refs.isEmpty else { continue }
                attributes[scrub(attribute)] = refs.prefix(20).map(scrub)
            }
            let full = prefix.map { $0 + "." + address } ?? address
            if !attributes.isEmpty { references[scrub(full)] = attributes }
        }
        for (name, call) in module["module_calls"] as? [String: Any] ?? [:] {
            guard let call = call as? [String: Any], let child = call["module"] as? [String: Any] else { continue }
            collectReferences(child, module: (prefix.map { $0 + "." } ?? "") + "module." + name, into: &references, scrub: scrub, depth: depth + 1)
        }
    }

    /// What runs over every kept string: credentials in text, URLs' passwords.
    static func scrub(_ text: String) -> String { TerraformValidation.scrub(text) }

    static let redaction = "••••••"
    /// A value shorter than this isn't hunted for inside other strings
    /// (`a`, `1`, `true` are everywhere); a leaf equal to it is still masked.
    static let minimumSecret = 4
    /// Bounds the values collected: a plan of 20,000 `random_password`s still has every one.
    static let maxSecrets = 50_000

    /// The strings a plan marks sensitive, wherever it marks them: a
    /// resource's or a drift's `before`/`after` under its mirrors, an
    /// output's value when either mirror marks it, a variable whose
    /// configuration says `sensitive`, an action's `config_values` under
    /// `config_sensitive`. Numbers by their text. Only what is hunted for;
    /// never kept.
    static func sensitiveValues(in object: [String: Any]) -> Set<String> {
        var found: Set<String> = []
        func collect(_ raw: Any?, _ mirror: Any?, marked: Bool, depth: Int) {
            guard found.count < maxSecrets, depth < maxDepth, let raw, !(raw is NSNull) else { return }
            let here = marked || isMarked(mirror)
            // Nothing marked here and no mirror to go down: nothing below is.
            guard here || mirror is [Any] || mirror is [String: Any] else { return }
            switch raw {
            case let string as String:
                if here, !string.isEmpty { found.insert(string) }
            case let number as NSNumber:
                if here, CFGetTypeID(number) != CFBooleanGetTypeID() { found.insert(number.stringValue) }
            case let list as [Any]:
                let marks = mirror as? [Any]
                for (index, item) in list.prefix(maxItems).enumerated() {
                    collect(item, marks.flatMap { index < $0.count ? $0[index] : nil }, marked: here, depth: depth + 1)
                }
            case let fields as [String: Any]:
                let marks = mirror as? [String: Any]
                if !here, let marks {
                    // Only where the mirror goes: the rest is unmarked.
                    for (key, mark) in marks.prefix(maxItems) { collect(fields[key], mark, marked: false, depth: depth + 1) }
                } else {
                    for (key, item) in fields.prefix(maxItems) { collect(item, marks?[key], marked: here, depth: depth + 1) }
                }
            default:
                break
            }
        }
        for key in ["resource_changes", "resource_drift"] {
            for change in (object[key] as? [[String: Any]] ?? []).prefix(maxResources) {
                let inner = change["change"] as? [String: Any] ?? [:]
                collect(inner["before"], inner["before_sensitive"], marked: false, depth: 0)
                collect(inner["after"], inner["after_sensitive"], marked: false, depth: 0)
            }
        }
        for (_, change) in object["output_changes"] as? [String: Any] ?? [:] {
            guard let change = change as? [String: Any] else { continue }
            let sensitive = isMarked(change["before_sensitive"]) || isMarked(change["after_sensitive"])
            collect(change["before"], change["before_sensitive"], marked: sensitive, depth: 0)
            collect(change["after"], change["after_sensitive"], marked: sensitive, depth: 0)
        }
        let configured = ((object["configuration"] as? [String: Any])?["root_module"] as? [String: Any])?["variables"] as? [String: Any] ?? [:]
        for (name, value) in object["variables"] as? [String: Any] ?? [:] {
            guard (configured[name] as? [String: Any])?["sensitive"] as? Bool == true else { continue }
            collect((value as? [String: Any])?["value"], nil, marked: true, depth: 0)
        }
        for invocation in (object["action_invocations"] as? [[String: Any]] ?? []).prefix(maxItems) {
            collect(invocation["config_values"], invocation["config_sensitive"], marked: false, depth: 0)
        }
        return found
    }

    // MARK: Counts

    struct Counts: Equatable, Sendable {
        var create = 0, update = 0, delete = 0, replace = 0, forget = 0, moved = 0, imported = 0, drift = 0, actions = 0, reads = 0

        /// `+5 ~1 -3 ±2 →4 ⇣1 ⚠1 ⚡1`: the summary bar (2.2).
        var bar: String {
            var parts = ["+\(create)", "~\(update)", "-\(delete)", "±\(replace)"]
            if forget > 0 { parts.append("⊘\(forget)") }
            if moved > 0 { parts.append("→\(moved)") }
            if imported > 0 { parts.append("⇣\(imported)") }
            if drift > 0 { parts.append("⚠\(drift)") }
            if actions > 0 { parts.append("⚡\(actions)") }
            return parts.joined(separator: " ")
        }

        /// The CLI's own sentence, so the numbers match: a replace is one
        /// add and one destroy there.
        var sentence: String {
            var parts: [String] = []
            if imported > 0 { parts.append("\(imported) to import") }
            parts += ["\(create + replace) to add", "\(update) to change", "\(delete + replace) to destroy"]
            var sentence = "Plan: " + parts.joined(separator: ", ") + "."
            if forget > 0 { sentence += " \(forget) to forget." }
            if actions > 0 { sentence += " Actions: \(actions) to invoke." }
            return sentence
        }
    }

    var counts: Counts {
        var counts = Counts()
        for change in resourceChanges {
            if change.isMove { counts.moved += 1 }
            if change.isImport { counts.imported += 1 }
            switch change.action {
            case .create: counts.create += 1
            case .update: counts.update += 1
            case .delete: counts.delete += 1
            case .replace: counts.replace += 1
            case .forget: counts.forget += 1
            case .read: counts.reads += 1
            case .noop: break
            }
        }
        counts.drift = drift.count
        counts.actions = actions.count
        return counts
    }
}

/// The plan as text for an agent (`tf_plan_summary`, analysis 3.5):
/// counts, then every replace, delete and forget with its reason and what
/// forces it, actions, updates folded ×N with the attribute paths that
/// change, moves, imports, drift, outputs and variables by name. Only the
/// masked model is read; strings cut at 200 characters. Pure.
enum TerraformPlanText {
    static let cutLength = 200

    static func cut(_ text: String, to length: Int = cutLength) -> String {
        text.count <= length ? text : String(text.prefix(length)) + "…"
    }

    /// Non-printables escaped (a `for_each` key may hold bidi or
    /// zero-width characters, 5.4): a control character, a direction mark
    /// or override, a zero-width one as its code point.
    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let hidden =
                value < 0x20 || (0x7F...0x9F).contains(value) || (0x200B...0x200F).contains(value) || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value) || value == 0xFEFF || value == 0x061C
            out += hidden ? String(format: "\\u{%04X}", value) : String(scalar)
        }
        return out
    }

    /// `causes`: each risky row's cause chain, said, by address (3.1, 3.5).
    static func summary(_ plan: TerraformPlan, root: String, file: String?, causes: [String: String] = [:], limit: Int = 400) -> String {
        let counts = plan.counts
        var lines: [String] = []
        var head = "Plan of \(escaped(root))"
        if let file { head += " (\(escaped(file)))" }
        if let version = plan.terraformVersion { head += ", made by Terraform \(version)" }
        if let timestamp = plan.timestamp { head += " at \(timestamp)" }
        lines.append(head + ".")
        lines.append("\(counts.bar)   \(counts.sentence)")
        if plan.errored { lines.append("The plan errored: it can't be applied.") }
        if !plan.complete { lines.append("Partial: not every change is in it (-target, or deferred changes).") }
        if !plan.hasPriorState { lines.append("No prior state: everything in it is created anew.") }
        if plan.partlyUnderstood { lines.append("Partly understood: Overterm doesn't read \(plan.unknownKeys.joined(separator: ", ")) — left out.") }
        var budget = limit
        func add(_ line: String) {
            guard budget > 0 else { return }
            budget -= 1
            lines.append(budget == 0 ? "… (more left out)" : line)
        }
        let risky = plan.resourceChanges.filter(\.isRisky)
        if !risky.isEmpty || !plan.actions.isEmpty {
            lines.append("")
            lines.append("Destroys, replaces and forgets first:")
            for change in risky.sorted(by: { rank($0) < rank($1) }) {
                add(riskyLine(change, plan: plan))
                if let cause = causes[change.address], !cause.isEmpty { add("    why: " + cut(escaped(cause), to: 600)) }
            }
            for action in plan.actions {
                var line = "⚡ \(escaped(action.address)) (\(escaped(action.type)))"
                if let trigger = action.trigger { line += " — \(escaped(trigger))" }
                if let config = action.config { line += "; config \(config.said(cut: cutLength))" }
                add(line)
            }
        }
        let updates = fold(plan.resourceChanges.filter { $0.action == .update || $0.action == .create })
        if !updates.isEmpty {
            lines.append("")
            lines.append("Creates and updates:")
            for group in updates {
                let first = group[0]
                let symbol = first.action == .create ? "+" : "~"
                var line = "\(symbol) \(escaped(first.address))"
                if group.count > 1 { line += " ×\(group.count) (\(escaped(group.map(\.address).joined(separator: ", "))))" }
                if first.action == .update, !first.changedPaths.isEmpty { line += " — " + escaped(first.changedPaths.prefix(12).joined(separator: ", ")) }
                add(cut(line, to: 600))
            }
        }
        let moves = plan.resourceChanges.filter(\.isMove)
        if !moves.isEmpty {
            lines.append("")
            lines.append("Moved:")
            for change in moves { add("→ \(escaped(change.address)) ← \(escaped(change.previousAddress ?? "?"))") }
        }
        let imports = plan.resourceChanges.filter(\.isImport)
        if !imports.isEmpty {
            lines.append("")
            lines.append("Imported:")
            for change in imports { add("⇣ \(escaped(change.address)) ← \(escaped(cut(change.importingID ?? "?")))") }
        }
        if !plan.drift.isEmpty {
            lines.append("")
            lines.append("Changed outside Terraform (drift):")
            for change in plan.drift {
                add("⚠ \(escaped(change.address)) \(change.action.rawValue)" + (change.changedPaths.isEmpty ? "" : " — " + escaped(change.changedPaths.prefix(12).joined(separator: ", "))))
            }
        }
        let reads = plan.resourceChanges.filter { $0.action == .read }
        if !reads.isEmpty { lines.append("Data sources read during apply: \(reads.count).") }
        if !plan.outputs.isEmpty {
            lines.append("")
            lines.append(
                "Outputs: "
                    + plan.outputs.map { output in
                        let action = output.actions.joined(separator: ",")
                        if output.sensitive { return "\(escaped(output.name)) \(action) (sensitive)" }
                        return "\(escaped(output.name)) \(action)" + (output.after.map { " = " + $0.said(cut: cutLength) } ?? "")
                    }.joined(separator: "; "))
        }
        if !plan.variables.isEmpty {
            lines.append(
                "Variables (names only): "
                    + plan.variables.map { $0.name + ($0.sensitive ? " (sensitive)" : "") + ($0.ephemeral ? " (ephemeral)" : "") }.joined(separator: ", "))
        }
        if !plan.checks.isEmpty {
            let failing = plan.checks.filter { $0.status != "pass" }
            lines.append(failing.isEmpty ? "Checks: \(plan.checks.count) pass." : "Checks not passing: " + failing.map { "\($0.address) \($0.status)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("Masked by Terraform's sensitive marks and Overterm's rules: a value marked sensitive is never shown.")
        return lines.joined(separator: "\n")
    }

    private static func rank(_ change: TerraformPlan.ResourceChange) -> Int {
        switch change.action {
        case .replace: 0
        case .delete: 1
        default: 2
        }
    }

    static func riskyLine(_ change: TerraformPlan.ResourceChange, plan: TerraformPlan) -> String {
        let symbol: String
        let what: String
        switch change.action {
        case .replace:
            symbol = "±"
            what = change.createsFirst ? "replace (create, then delete)" : "replace (delete, then create)"
        case .forget:
            symbol = "⊘"
            what = "forget: kept in the cloud, out of state"
        default:
            symbol = "-"
            what = "delete"
        }
        var line = "\(symbol) \(escaped(change.address))  \(what)"
        if let reason = change.reason { line += " — \(reason)" }
        if !change.replacePaths.isEmpty {
            let forcing = change.replacePaths.prefix(4).map { path -> String in
                let attribute = path.first ?? "?"
                let refs = plan.references[configAddress(change)]?[attribute] ?? []
                return ([path.joined(separator: ".")] + refs.prefix(3)).joined(separator: " ← ")
            }
            line += "; forced by " + escaped(forcing.joined(separator: "; "))
        }
        return cut(line, to: 600)
    }

    /// A resource's address in `configuration`: without its instance key.
    static func configAddress(_ change: TerraformPlan.ResourceChange) -> String {
        change.index == nil ? change.address : change.address.replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
    }

    /// Rows with the same change folded, in first-seen order.
    static func fold(_ changes: [TerraformPlan.ResourceChange]) -> [[TerraformPlan.ResourceChange]] {
        var order: [String] = []
        var groups: [String: [TerraformPlan.ResourceChange]] = [:]
        for change in changes {
            let key = change.foldKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(change)
        }
        return order.map { groups[$0]! }
    }
}
