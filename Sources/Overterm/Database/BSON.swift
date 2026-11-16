import Foundation

/// BSON, as MongoDB's wire carries it — pure, so it is tested without a
/// server: values, documents in their order, bytes both ways, and each
/// value said as mongosh writes it (which the console reads back).
indirect enum BSONValue: Equatable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, Data)
    case undefined
    case objectId(ObjectID)
    case bool(Bool)
    /// Milliseconds since 1970, UTC.
    case date(Int64)
    case null
    case regex(pattern: String, options: String)
    case javascript(String)
    case symbol(String)
    case int32(Int32)
    /// MongoDB's internal one: seconds (high) and an ordinal (low).
    case timestamp(UInt64)
    case int64(Int64)
    case decimal128(Decimal128)
    case minKey, maxKey

    /// The type's name as `$type` and mongosh name it.
    var typeName: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary(let subtype, _): subtype == 4 ? "uuid" : "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .date: "date"
        case .null: "null"
        case .regex: "regex"
        case .javascript: "javascript"
        case .symbol: "symbol"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }

    var document: BSONDocument? { if case .document(let d) = self { d } else { nil } }
    var array: [BSONValue]? { if case .array(let a) = self { a } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }

    /// A number, whatever its width: ok, n, cursor ids, counts.
    var int: Int? {
        switch self {
        case .int32(let n): Int(n)
        case .int64(let n): Int(n)
        case .double(let d) where d.isFinite && d == d.rounded() && abs(d) < 9e15: Int(d)
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .int32, .int64, .double: int.map { $0 != 0 }
        default: nil
        }
    }
}

/// Twelve bytes: a time, a random value, a counter.
struct ObjectID: Equatable, Hashable, Sendable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        self.bytes = bytes
    }

    init?(hex: String) {
        guard hex.count == 24 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<12 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        bytes = out
    }

    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    // What drivers make an `_id` of: seconds, five random bytes for this
    // process, a counter from a random start.
    private static let process: [UInt8] = (0..<5).map { _ in UInt8.random(in: 0...255) }
    nonisolated(unsafe) private static var counter = UInt32.random(in: 0...0xFFFFFF)
    private static let lock = NSLock()

    static func generate(now: Date = Date()) -> ObjectID {
        let seconds = UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970))
        let count = lock.withLock {
            counter = (counter &+ 1) & 0xFFFFFF
            return counter
        }
        var bytes = [UInt8(seconds >> 24), UInt8(seconds >> 16 & 0xFF), UInt8(seconds >> 8 & 0xFF), UInt8(seconds & 0xFF)]
        bytes += process
        bytes += [UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        return ObjectID(bytes: bytes)!
    }
}

/// IEEE 754-2008's decimal128, BID encoded as BSON has it: read for its
/// text, made from one (`NumberDecimal("1.50")`).
struct Decimal128: Equatable, Sendable {
    var high: UInt64
    var low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    private static let bias = 6176

    /// "1.50", "-0.001", "1E+3", "NaN", "Infinity"; nil when it isn't one
    /// or needs more than 34 digits.
    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if s.first == "-" || s.first == "+" {
            negative = s.first == "-"
            s = s.dropFirst()
        }
        let lower = s.lowercased()
        if lower == "nan" {
            self.init(high: 0x7C00_0000_0000_0000, low: 0)
            return
        }
        if lower == "inf" || lower == "infinity" {
            self.init(high: (negative ? 0xF800_0000_0000_0000 : 0x7800_0000_0000_0000), low: 0)
            return
        }
        var digits = ""
        var exponent = 0
        var seenPoint = false
        var index = s.startIndex
        while index < s.endIndex, s[index].isNumber || s[index] == "." {
            if s[index] == "." {
                if seenPoint { return nil }
                seenPoint = true
            } else {
                digits.append(s[index])
                if seenPoint { exponent -= 1 }
            }
            index = s.index(after: index)
        }
        if index < s.endIndex {
            guard s[index] == "e" || s[index] == "E", let e = Int(s[s.index(after: index)...]) else { return nil }
            exponent += e
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII) else { return nil }
        while digits.count > 1, digits.first == "0" { digits.removeFirst() }
        guard digits.count <= 34 else { return nil }
        guard exponent + Self.bias >= 0, exponent + Self.bias <= 12287 else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for digit in digits {
            // (high, low) * 10 + digit, in 128 bits.
            let value = UInt64(digit.wholeNumberValue!)
            let lowTimes = low.multipliedFullWidth(by: 10)
            let (newLow, carry) = lowTimes.low.addingReportingOverflow(value)
            low = newLow
            high = high &* 10 &+ lowTimes.high &+ (carry ? 1 : 0)
        }
        let biased = UInt64(exponent + Self.bias)
        high |= biased << 49
        if negative { high |= 1 << 63 }
        self.init(high: high, low: low)
    }

    var text: String {
        let negative = high >> 63 == 1
        let sign = negative ? "-" : ""
        let combination = (high >> 58) & 0x1F
        if combination == 0x1F { return "NaN" }
        if combination == 0x1E { return sign + "Infinity" }
        var exponent: Int
        var coefficientHigh: UInt64
        if (high >> 61) & 0x3 == 0x3 {
            // The large form never makes a canonical value: zero.
            exponent = Int((high >> 47) & 0x3FFF) - Self.bias
            coefficientHigh = 0
            return sign + (exponent == 0 ? "0" : "0E\(exponent >= 0 ? "+" : "")\(exponent)")
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - Self.bias
            coefficientHigh = high & 0x1_FFFF_FFFF_FFFF
        }
        // The coefficient's digits, by dividing 128 bits by 10.
        var digits: [Character] = []
        var h = coefficientHigh
        var l = low
        repeat {
            let (qh, rh) = h.quotientAndRemainder(dividingBy: 10)
            let (ql, rl) = UInt64(10).dividingFullWidth((high: rh, low: l))
            digits.append(Character(String(rl)))
            h = qh
            l = ql
        } while h != 0 || l != 0
        let coefficient = String(digits.reversed())
        let adjusted = exponent + coefficient.count - 1
        if exponent <= 0, adjusted >= -6 {
            if exponent == 0 { return sign + coefficient }
            let places = -exponent
            if coefficient.count > places {
                let point = coefficient.index(coefficient.endIndex, offsetBy: -places)
                return sign + coefficient[..<point] + "." + coefficient[point...]
            }
            return sign + "0." + String(repeating: "0", count: places - coefficient.count) + coefficient
        }
        var out = String(coefficient.prefix(1))
        if coefficient.count > 1 { out += "." + coefficient.dropFirst() }
        return sign + out + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }
}

/// A document: its fields in the order they were written — a command's
/// name must come first, and a sort's keys mean their order.
struct BSONDocument: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    var fields: [(key: String, value: BSONValue)] = []

    init(_ fields: [(String, BSONValue)] = []) { self.fields = fields.map { (key: $0.0, value: $0.1) } }
    init(dictionaryLiteral elements: (String, BSONValue)...) { self.init(elements) }

    static func == (a: BSONDocument, b: BSONDocument) -> Bool {
        a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    var keys: [String] { fields.map(\.key) }
    var isEmpty: Bool { fields.isEmpty }

    subscript(key: String) -> BSONValue? {
        get { fields.first { $0.key == key }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.key == key }) {
                if let newValue { fields[index].value = newValue } else { fields.remove(at: index) }
            } else if let newValue {
                fields.append((key: key, value: newValue))
            }
        }
    }

    // MARK: Bytes

    func encoded() -> Data {
        var out = Data()
        BSON.write(self, into: &out)
        return out
    }

    static func decode(_ data: Data) throws -> BSONDocument {
        var reader = BSON.Reader(bytes: [UInt8](data))
        return try reader.document()
    }
}

enum BSON {
    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    static func write(_ document: BSONDocument, into out: inout Data) {
        let start = out.count
        out.append(contentsOf: [0, 0, 0, 0])
        for (key, value) in document.fields { write(key, value, into: &out) }
        out.append(0)
        patchLength(at: start, in: &out)
    }

    private static func patchLength(at start: Int, in out: inout Data) {
        let length = UInt32(out.count - start)
        out.replaceSubrange(start..<(start + 4), with: withUnsafeBytes(of: length.littleEndian, Array.init))
    }

    private static func cstring(_ text: String, into out: inout Data) {
        // A key or a regex can't hold a NUL: it would end it.
        out.append(contentsOf: Array(text.utf8).filter { $0 != 0 })
        out.append(0)
    }

    private static func string(_ text: String, into out: inout Data) {
        let bytes = Array(text.utf8)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count + 1).littleEndian, Array.init))
        out.append(contentsOf: bytes)
        out.append(0)
    }

    private static func little<T: FixedWidthInteger>(_ value: T, into out: inout Data) {
        out.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    private static func write(_ key: String, _ value: BSONValue, into out: inout Data) {
        func head(_ type: UInt8) {
            out.append(type)
            cstring(key, into: &out)
        }
        switch value {
        case .double(let d):
            head(0x01)
            little(d.bitPattern, into: &out)
        case .string(let s):
            head(0x02)
            string(s, into: &out)
        case .document(let d):
            head(0x03)
            write(d, into: &out)
        case .array(let items):
            head(0x04)
            write(BSONDocument(items.enumerated().map { (String($0.offset), $0.element) }), into: &out)
        case .binary(let subtype, let data):
            head(0x05)
            little(UInt32(data.count), into: &out)
            out.append(subtype)
            out.append(data)
        case .undefined: head(0x06)
        case .objectId(let id):
            head(0x07)
            out.append(contentsOf: id.bytes)
        case .bool(let b):
            head(0x08)
            out.append(b ? 1 : 0)
        case .date(let ms):
            head(0x09)
            little(ms, into: &out)
        case .null: head(0x0A)
        case .regex(let pattern, let options):
            head(0x0B)
            cstring(pattern, into: &out)
            // Its flags in alphabetical order, as the spec asks.
            cstring(String(options.sorted()), into: &out)
        case .javascript(let code):
            head(0x0D)
            string(code, into: &out)
        case .symbol(let s):
            head(0x0E)
            string(s, into: &out)
        case .int32(let n):
            head(0x10)
            little(n, into: &out)
        case .timestamp(let t):
            head(0x11)
            little(t, into: &out)
        case .int64(let n):
            head(0x12)
            little(n, into: &out)
        case .decimal128(let d):
            head(0x13)
            little(d.low, into: &out)
            little(d.high, into: &out)
        case .minKey: head(0xFF)
        case .maxKey: head(0x7F)
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, at + count <= bytes.count else { throw DecodeError(description: "BSON ends early") }
            defer { at += count }
            return bytes[at..<(at + count)]
        }

        mutating func little<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let slice = try take(MemoryLayout<T>.size)
            var value: T = 0
            for (shift, byte) in slice.enumerated() { value |= T(truncatingIfNeeded: byte) << (shift * 8) }
            return value
        }

        mutating func cstring() throws -> String {
            guard let end = bytes[at...].firstIndex(of: 0) else { throw DecodeError(description: "a name with no end") }
            defer { at = end + 1 }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        mutating func string() throws -> String {
            let length = Int(try little(Int32.self))
            guard length >= 1 else { throw DecodeError(description: "a string of length \(length)") }
            let slice = try take(length)
            return String(decoding: slice.dropLast(), as: UTF8.self)
        }

        mutating func document() throws -> BSONDocument {
            let start = at
            let length = Int(try little(Int32.self))
            guard length >= 5, start + length <= bytes.count else { throw DecodeError(description: "a document of length \(length)") }
            let end = start + length - 1
            var document = BSONDocument()
            while at < end {
                let type = try take(1).first!
                let key = try cstring()
                document.fields.append((key: key, value: try value(type)))
            }
            guard at == end, bytes[end] == 0 else { throw DecodeError(description: "a document that doesn't end where it says") }
            at = end + 1
            return document
        }

        mutating func value(_ type: UInt8) throws -> BSONValue {
            switch type {
            case 0x01: return .double(Double(bitPattern: try little(UInt64.self)))
            case 0x02: return .string(try string())
            case 0x03: return .document(try document())
            case 0x04: return .array(try document().fields.map(\.value))
            case 0x05:
                let length = Int(try little(Int32.self))
                let subtype = try take(1).first!
                var data = Data(try take(length))
                // The old binary subtype carries its length twice.
                if subtype == 0x02, data.count >= 4 { data = data.dropFirst(4) }
                return .binary(subtype: subtype, Data(data))
            case 0x06: return .undefined
            case 0x07: return .objectId(ObjectID(bytes: Array(try take(12)))!)
            case 0x08: return .bool(try take(1).first! != 0)
            case 0x09: return .date(try little(Int64.self))
            case 0x0A: return .null
            case 0x0B: return .regex(pattern: try cstring(), options: try cstring())
            case 0x0C:
                // DBPointer, long deprecated: its name and id, said as text.
                let name = try string()
                let id = ObjectID(bytes: Array(try take(12)))!
                return .string("DBPointer(\(name), \(id.hex))")
            case 0x0D: return .javascript(try string())
            case 0x0E: return .symbol(try string())
            case 0x0F:
                // Code with scope: the code is what can be shown.
                _ = try little(Int32.self)
                let code = try string()
                _ = try document()
                return .javascript(code)
            case 0x10: return .int32(try little(Int32.self))
            case 0x11: return .timestamp(try little(UInt64.self))
            case 0x12: return .int64(try little(Int64.self))
            case 0x13:
                let low = try little(UInt64.self)
                return .decimal128(Decimal128(high: try little(UInt64.self), low: low))
            case 0xFF: return .minKey
            case 0x7F: return .maxKey
            default: throw DecodeError(description: String(format: "an unknown BSON type 0x%02x", type))
            }
        }
    }
}

// MARK: Said as mongosh says it

extension BSONValue {
    /// The value as the console would take it back: `ObjectId("…")`,
    /// `ISODate("…")`, `{ a: 1 }` with its keys quoted as JSON.
    var shell: String { BSONText.shell(self) }

    /// For a cell of the grid: a string as itself, a date as its ISO time,
    /// anything else as `shell`. nil for a null.
    var cell: String? {
        switch self {
        case .null, .undefined: nil
        case .string(let s), .symbol(let s): s
        case .date(let ms): BSONText.iso(ms)
        default: shell
        }
    }
}

enum BSONText {
    static func iso(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func number(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        return String(d)
    }

    static func shell(_ value: BSONValue) -> String {
        switch value {
        case .double(let d): return number(d)
        case .string(let s), .symbol(let s): return quoted(s)
        case .document(let d):
            guard !d.isEmpty else { return "{}" }
            return "{ " + d.fields.map { quoted($0.key) + ": " + shell($0.value) }.joined(separator: ", ") + " }"
        case .array(let items): return "[" + items.map(shell).joined(separator: ", ") + "]"
        case .binary(let subtype, let data):
            if subtype == 4, data.count == 16 { return "UUID(\"\(uuid(data))\")" }
            return "BinData(\(subtype), \"\(data.base64EncodedString())\")"
        case .undefined: return "undefined"
        case .objectId(let id): return "ObjectId(\"\(id.hex)\")"
        case .bool(let b): return b ? "true" : "false"
        case .date(let ms): return "ISODate(\"\(iso(ms))\")"
        case .null: return "null"
        case .regex(let pattern, let options): return "/\(pattern.replacingOccurrences(of: "/", with: "\\/"))/\(options)"
        case .javascript(let code): return "Code(\(quoted(code)))"
        case .int32(let n): return String(n)
        case .timestamp(let t): return "Timestamp({ t: \(t >> 32), i: \(t & 0xFFFF_FFFF) })"
        case .int64(let n): return "NumberLong(\"\(n)\")"
        case .decimal128(let d): return "NumberDecimal(\"\(d.text)\")"
        case .minKey: return "MinKey()"
        case .maxKey: return "MaxKey()"
        }
    }

    static func uuid(_ data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}
