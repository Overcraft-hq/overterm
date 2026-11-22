import Foundation

/// JSON-RPC as language servers speak it over stdio: each message a JSON
/// body behind a `Content-Length` header. Pure — the process side is
/// `LanguageServer`.
package enum JSONRPC {
    /// `body` behind its header, ready to write.
    package static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    /// Turns what a server writes, in whatever chunks the pipe hands over,
    /// back into whole message bodies. A read can end mid-header, mid-body,
    /// or carry several messages; all of that is kept until it completes.
    package struct FrameDecoder {
        private var buffer = Data()
        /// The body length of the header already read, while its body is
        /// still arriving — so a big body isn't searched for headers again
        /// on every chunk.
        private var bodyLength: Int?

        /// A header this long without its blank line is not a header: the
        /// server printed something else to stdout. It is dropped.
        package static let maxHeaderBytes = 64 * 1024
        /// A body claimed bigger than this is a corrupt header, not a message.
        package static let maxBodyBytes = 256 * 1024 * 1024

        private static let separator = Data("\r\n\r\n".utf8)

        package init() {}

        /// Bytes received and not yet part of a whole message.
        package var pendingByteCount: Int { buffer.count }

        package mutating func feed(_ chunk: Data) -> [Data] {
            buffer.append(chunk)
            var messages: [Data] = []
            while true {
                if let length = bodyLength {
                    guard buffer.count >= length else { break }
                    messages.append(Data(buffer.prefix(length)))
                    buffer = Data(buffer.dropFirst(length))
                    bodyLength = nil
                    continue
                }
                guard let separator = buffer.range(of: Self.separator) else {
                    if buffer.count > Self.maxHeaderBytes { buffer = Data() }
                    break
                }
                let header = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
                buffer = Data(buffer[separator.upperBound...])
                // A header without a length (or with a nonsense one) frames
                // nothing; skip it and look for the next.
                if let length = Self.contentLength(in: header), length <= Self.maxBodyBytes { bodyLength = length }
            }
            return messages
        }

        /// `Content-Length`'s value; the header name is case-insensitive, and
        /// anything else in the header (Content-Type, stray log lines) is ignored.
        package static func contentLength(in header: String) -> Int? {
            for line in header.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
                if let value = Int(parts[1].trimmingCharacters(in: .whitespaces)), value >= 0 { return value }
            }
            return nil
        }
    }
}

/// Any JSON value, for what goes out — request params, replies — without a
/// struct per message. Sendable, unlike what JSONSerialization hands back.
package enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// What JSONSerialization produced, made Sendable — a server request's
    /// id, echoed back in the reply.
    package init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            // NSNumber also boxes Bool; CFBoolean tells which it is.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .null
        }
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    package init(nilLiteral: ()) { self = .null }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(integerLiteral value: Int) { self = .int(value) }
    package init(stringLiteral value: String) { self = .string(value) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A value read as the MCP inspector and the API client read it.
extension JSONValue {
    package subscript(_ key: String) -> JSONValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }
    package var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    package var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    package var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    /// Indented, keys sorted: as the inspector shows a value.
    package var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
