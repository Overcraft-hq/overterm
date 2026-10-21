import Foundation
import TreeSitterKit

/// YAML read into what JSONSerialization would give for the same data —
/// dictionaries, arrays, strings, numbers, booleans, NSNull — by the
/// tree-sitter grammar the editor already carries, so an OpenAPI document
/// in YAML needs no parser of its own. Anchors and aliases resolve; tags
/// are ignored. A document the grammar can't read whole is nil, not a
/// guess.
enum YAMLReader {
    static func parse(_ text: String) -> Any? {
        guard let language = EditorLanguage.named("yaml") else { return nil }
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        ts_parser_set_language(parser, language.grammar)
        let bytes = Array(text.utf8)
        guard
            let tree = bytes.withUnsafeBufferPointer({ buffer in
                buffer.baseAddress.flatMap { base in
                    base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { ts_parser_parse_string(parser, nil, $0, UInt32(buffer.count)) }
                }
            })
        else { return nil }
        defer { ts_tree_delete(tree) }
        let root = ts_tree_root_node(tree)
        guard !ts_node_has_error(root) else { return nil }
        var reader = Reader(bytes: bytes)
        // stream → the first document → its node.
        guard let document = reader.namedChildren(root).first(where: { reader.type($0) == "document" }) else { return nil }
        guard let node = reader.namedChildren(document).first(where: { ["block_node", "flow_node"].contains(reader.type($0)) }) else {
            return NSNull()
        }
        return reader.value(node)
    }

    private struct Reader {
        let bytes: [UInt8]
        var anchors: [String: Any] = [:]

        func type(_ node: TSNode) -> String { String(cString: ts_node_type(node)) }

        func text(_ node: TSNode) -> String {
            let start = Int(ts_node_start_byte(node))
            let end = min(Int(ts_node_end_byte(node)), bytes.count)
            guard start < end else { return "" }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func namedChildren(_ node: TSNode) -> [TSNode] {
            (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) }
        }

        func field(_ node: TSNode, _ name: String) -> TSNode? {
            let child = name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) }
            return ts_node_is_null(child) ? nil : child
        }

        mutating func value(_ node: TSNode) -> Any {
            switch type(node) {
            case "block_node", "flow_node":
                var anchor: String?
                var result: Any = NSNull()
                for child in namedChildren(node) {
                    switch type(child) {
                    case "anchor": anchor = namedChildren(child).first.map(text) ?? String(text(child).dropFirst())
                    case "tag", "comment": continue
                    case "alias":
                        let name = namedChildren(child).first.map(text) ?? String(text(child).dropFirst())
                        result = anchors[name] ?? NSNull()
                    default: result = value(child)
                    }
                }
                if let anchor { anchors[anchor] = result }
                return result
            case "block_mapping", "flow_mapping":
                var map: [String: Any] = [:]
                for pair in namedChildren(node) where ["block_mapping_pair", "flow_pair"].contains(type(pair)) {
                    let key = field(pair, "key").map { keyString(value($0)) } ?? ""
                    let item = field(pair, "value").map { value($0) } ?? NSNull()
                    // `<<: *base` merges the aliased map in, its own keys winning.
                    if key == "<<", let merged = item as? [String: Any] {
                        map.merge(merged) { current, _ in current }
                    } else {
                        map[key] = item
                    }
                }
                return map
            case "block_sequence":
                return namedChildren(node).filter { type($0) == "block_sequence_item" }.map { item -> Any in
                    namedChildren(item).first(where: { ["block_node", "flow_node"].contains(type($0)) }).map { value($0) } ?? NSNull()
                }
            case "flow_sequence":
                return namedChildren(node).compactMap { child -> Any? in
                    switch type(child) {
                    case "flow_node": return value(child)
                    case "flow_pair":
                        // [a: 1] is a sequence of one single-pair map.
                        let key = field(child, "key").map { keyString(value($0)) } ?? ""
                        return [key: field(child, "value").map { value($0) } ?? NSNull()]
                    default: return nil
                    }
                }
            case "plain_scalar":
                return plain(namedChildren(node).first.map { (type($0), text($0)) } ?? ("string_scalar", text(node)))
            case "double_quote_scalar":
                return YAMLReader.unescapeDouble(String(text(node).dropFirst().dropLast()))
            case "single_quote_scalar":
                return String(text(node).dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            case "block_scalar":
                return YAMLReader.blockScalar(text(node))
            default:
                return text(node)
            }
        }

        func keyString(_ key: Any) -> String {
            switch key {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            case is NSNull: "null"
            default: "\(key)"
            }
        }

        func plain(_ scalar: (type: String, text: String)) -> Any {
            let text = scalar.text.trimmingCharacters(in: .whitespaces)
            switch scalar.type {
            case "null_scalar": return NSNull()
            case "boolean_scalar": return ["true", "True", "TRUE", "yes", "Yes", "on", "On"].contains(text)
            case "integer_scalar":
                if let value = Int(text) { return value }
                if text.hasPrefix("0x"), let value = Int(text.dropFirst(2), radix: 16) { return value }
                if text.hasPrefix("0o"), let value = Int(text.dropFirst(2), radix: 8) { return value }
                return text
            case "float_scalar":
                switch text.lowercased() {
                case ".inf", "+.inf": return Double.infinity
                case "-.inf": return -Double.infinity
                case ".nan": return Double.nan
                default: return Double(text) ?? text
                }
            default:
                // Multi-line plain scalars fold their line breaks into spaces.
                return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
        }
    }

    static func unescapeDouble(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else {
                out.append(char)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "\\": out.append("\\")
            case "u", "x", "U":
                let count = next == "x" ? 2 : next == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<count { if let c = iterator.next() { hex.append(c) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.append(Character(scalar)) }
            case "\n": continue
            default: out.append(next)
            }
        }
        return out
    }

    /// `|` keeps line breaks, `>` folds them; `-` strips the final one, `+`
    /// keeps them all. The indent is the first content line's.
    static func blockScalar(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }
        let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let folded = header.hasPrefix(">")
        let chomp: Character? = header.contains("-") ? "-" : header.contains("+") ? "+" : nil
        let indent = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count } ?? 0
        let body = lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : $0.trimmingCharacters(in: .whitespaces) }
        var result: String
        if folded {
            result = ""
            var previousBlank = true
            for line in body {
                if line.isEmpty {
                    result += "\n"
                    previousBlank = true
                } else {
                    if !previousBlank && !result.isEmpty { result += " " }
                    result += line
                    previousBlank = false
                }
            }
        } else {
            result = body.joined(separator: "\n")
        }
        switch chomp {
        case "-": return result.trimmingCharacters(in: .newlines)
        case "+": return result + "\n"
        default:
            while result.hasSuffix("\n") { result.removeLast() }
            return result + "\n"
        }
    }
}
