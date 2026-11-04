import Foundation

/// An object as `kubectl get -o yaml` writes it: keys in order (kubectl's
/// YAML goes through a map, so its keys come sorted — `apiVersion`, `kind`,
/// `metadata`, `spec`, `status`), sequences not indented under their key,
/// a string quoted only where YAML would read it as something else, a
/// string of several lines as a block. Pure.
enum KubeYAML {
    /// The JSON object (as `JSONSerialization` reads it) as YAML text,
    /// ending in a newline.
    static func text(_ value: Any) -> String {
        var out = ""
        switch value {
        case let map as [String: Any] where !map.isEmpty: mapping(map, indent: 0, into: &out)
        case let list as [Any] where !list.isEmpty: sequence(list, indent: 0, into: &out)
        default: out = scalar(value, indent: 0) + "\n"
        }
        return out
    }

    private static func pad(_ indent: Int) -> String { String(repeating: " ", count: indent) }

    private static func mapping(_ map: [String: Any], indent: Int, into out: inout String) {
        for key in map.keys.sorted() {
            out += pad(indent) + quotedIfNeeded(key) + ":"
            value(map[key]!, indent: indent, into: &out)
        }
    }

    /// A value after its key's colon: inline when it is a scalar or empty,
    /// else on the lines below — a mapping indented, a sequence not.
    private static func value(_ value: Any, indent: Int, into out: inout String) {
        switch value {
        case let map as [String: Any] where !map.isEmpty:
            out += "\n"
            mapping(map, indent: indent + 2, into: &out)
        case let list as [Any] where !list.isEmpty:
            out += "\n"
            sequence(list, indent: indent, into: &out)
        default:
            out += " " + scalar(value, indent: indent + 2) + "\n"
        }
    }

    private static func sequence(_ list: [Any], indent: Int, into out: inout String) {
        for item in list {
            switch item {
            case let map as [String: Any] where !map.isEmpty:
                // `- first: …`, the rest of its keys under the first.
                var nested = ""
                mapping(map, indent: indent + 2, into: &nested)
                out += pad(indent) + "- " + nested.dropFirst(indent + 2)
            case let inner as [Any] where !inner.isEmpty:
                var nested = ""
                sequence(inner, indent: indent + 2, into: &nested)
                out += pad(indent) + "- " + nested.dropFirst(indent + 2)
            default:
                out += pad(indent) + "- " + scalar(item, indent: indent + 2) + "\n"
            }
        }
    }

    /// One scalar: `null`, a bool, a number as JSON had it, a string —
    /// plain where it reads back as itself, a block where it has lines.
    static func scalar(_ value: Any, indent: Int) -> String {
        switch value {
        case is NSNull: return "null"
        case let map as [String: Any] where map.isEmpty: return "{}"
        case let list as [Any] where list.isEmpty: return "[]"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let string as String: return self.string(string, indent: indent)
        default: return self.string("\(value)", indent: indent)
        }
    }

    /// A string several lines long is a literal block (`|`, `|-` without a
    /// last newline) unless a line of it ends in a space, it starts with
    /// one, or it has a tab or a carriage return — which a plain block
    /// can't keep; then it is quoted.
    private static func string(_ text: String, indent: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, !text.contains("\r"), !text.contains("\t"), text.first != " ", !text.hasSuffix("\n\n"),
            !lines.contains(where: { $0.hasSuffix(" ") })
        {
            let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad(indent) + $0 }
            return (text.hasSuffix("\n") ? "|" : "|-") + "\n" + lines.joined(separator: "\n")
        }
        return quotedIfNeeded(text)
    }

    /// Plain, or double-quoted with JSON's escapes when YAML would read it
    /// as something else: empty, a number, a bool or null in any of YAML's
    /// spellings, a leading indicator, `: ` or ` #` inside, edge spaces.
    static func quotedIfNeeded(_ text: String) -> String {
        needsQuotes(text) ? quoted(text) : text
    }

    static func needsQuotes(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if first == " " || last == " " || first == "\t" { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            // `-x`, `:x`, `?x` are plain to YAML; alone, or before a space, they aren't.
            guard "-?:".contains(first), text.count > 1, text.dropFirst().first != " " else { return true }
        }
        if text.contains(": ") || text.contains(" #") || last == ":" { return true }
        if text.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) }) { return true }
        let lower = text.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", ".nan", ".inf", "-.inf", "+.inf"].contains(lower) { return true }
        return looksNumeric(text)
    }

    /// What YAML 1.1 (go-yaml's) reads as a number: ints in any base,
    /// floats, `1_000`, sexagesimal `1:20`.
    private static func looksNumeric(_ text: String) -> Bool {
        let patterns = [
            #"^[-+]?(0|[1-9][0-9_]*)$"#, #"^[-+]?0[0-7_]+$"#, #"^[-+]?0x[0-9a-fA-F_]+$"#, #"^[-+]?0b[01_]+$"#, #"^[-+]?0o[0-7_]+$"#,
            #"^[-+]?([0-9][0-9_]*)?\.[0-9_]*([eE][-+]?[0-9]+)?$"#, #"^[-+]?[0-9][0-9_]*[eE][-+]?[0-9]+$"#, #"^[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?$"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil && text != "." && text != "_" }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// What the YAML tab leaves out by default, as Lens and `kubectl neat` do:
/// `metadata.managedFields` (4–5 KB a pod, the spike found) and the
/// `kubectl.kubernetes.io/last-applied-configuration` annotation (the whole
/// object again, as last applied). A toggle puts them back — except on a
/// Secret, whose values the annotation can carry: there it never shows,
/// and `data` and `stringData` are masked whatever the toggle. An env
/// value whose name looks secret is masked on any kind, inside the
/// last-applied annotation too. Pure.
enum KubeObjectStrip {
    static let lastApplied = "kubectl.kubernetes.io/last-applied-configuration"
    static let mask = "***"

    /// The object as the YAML tab shows it.
    static func shown(_ object: [String: Any], full: Bool) -> [String: Any] {
        var object = object
        let secret = isSecret(object)
        if var metadata = object["metadata"] as? [String: Any] {
            if !full { metadata["managedFields"] = nil }
            if var annotations = metadata["annotations"] as? [String: Any], annotations[lastApplied] != nil {
                if !full || secret {
                    annotations[lastApplied] = nil
                } else {
                    annotations[lastApplied] = maskingLastApplied(annotations[lastApplied])
                }
                metadata["annotations"] = annotations.isEmpty ? nil : annotations
            }
            object["metadata"] = metadata
        }
        if secret {
            for key in ["data", "stringData"] {
                if let values = object[key] as? [String: Any] { object[key] = values.mapValues { _ in mask } }
            }
        }
        return maskingEnv(object) as? [String: Any] ?? object
    }

    /// Every container's `env` (a pod's, a template's, at any depth): a
    /// value whose name looks secret (`DB_PASSWORD`, `API_TOKEN`) masked,
    /// a URL's password too — Docker's inspect does the same
    /// (`DockerSecrets`). A value from a Secret (`valueFrom.secretKeyRef`)
    /// is only a name there, and stays.
    static func maskingEnv(_ value: Any) -> Any {
        switch value {
        case var map as [String: Any]:
            for (key, inner) in map {
                if key == "env", let entries = inner as? [[String: Any]] {
                    map[key] = entries.map { entry -> [String: Any] in
                        guard let name = entry["name"] as? String, let text = entry["value"] as? String else { return entry }
                        var entry = entry
                        entry["value"] = DockerSecrets.masked(name, text)
                        return entry
                    }
                } else {
                    map[key] = maskingEnv(inner)
                }
            }
            return map
        case let list as [Any]: return list.map(maskingEnv)
        default: return value
        }
    }

    /// The last-applied annotation, shown: the manifest as applied, as
    /// JSON — its env values masked as the object's own are, written again
    /// only when something was. One that isn't JSON is masked whole: what
    /// it says can't be read, so it can't be shown.
    static func maskingLastApplied(_ value: Any?) -> String {
        guard let text = value as? String, let data = text.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return mask }
        let masked = maskingEnv(parsed)
        if (masked as AnyObject).isEqual(parsed as AnyObject) { return text }
        guard JSONSerialization.isValidJSONObject(masked),
            let encoded = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .withoutEscapingSlashes]),
            let out = String(data: encoded, encoding: .utf8)
        else { return mask }
        return out
    }

    /// Whether `full` would show anything more.
    static func hasHidden(_ object: [String: Any]) -> Bool {
        guard let metadata = object["metadata"] as? [String: Any] else { return false }
        if metadata["managedFields"] != nil { return true }
        return !isSecret(object) && (metadata["annotations"] as? [String: Any])?[lastApplied] != nil
    }

    static func isSecret(_ object: [String: Any]) -> Bool {
        object["kind"] as? String == "Secret" && (object["apiVersion"] as? String ?? "v1") == "v1"
    }
}
