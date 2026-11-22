import Foundation

/// Protocol Buffers without generated code — pure, so it is tested without
/// a server: the wire format; the descriptors a server's reflection or
/// `protoc --descriptor_set_out` gives; and a message as JSON (proto3's
/// JSON mapping) to bytes and back, by its descriptor. What a gRPC request's
/// messages are, typed as JSON the way Bruno and grpcurl take them.
package enum Protobuf {
    package struct Failure: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    // MARK: The wire

    package enum WireType: Int {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
    }

    package struct Reader {
        package let data: [UInt8]
        package var at = 0

        package init(_ data: Data) { self.data = [UInt8](data) }

        package var atEnd: Bool { at >= data.count }

        package mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < data.count {
                let byte = data[at]
                at += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { throw Failure(message: "A varint longer than ten bytes.") }
            }
            throw Failure(message: "The message ends in the middle of a varint.")
        }

        package mutating func fixed32() throws -> UInt32 {
            guard at + 4 <= data.count else { throw Failure(message: "The message ends in the middle of a fixed32.") }
            defer { at += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * UInt32($1)) }
        }

        package mutating func fixed64() throws -> UInt64 {
            guard at + 8 <= data.count else { throw Failure(message: "The message ends in the middle of a fixed64.") }
            defer { at += 8 }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[at + $1]) << (8 * UInt64($1)) }
        }

        package mutating func bytes() throws -> Data {
            let length = Int(try varint())
            guard length >= 0, at + length <= data.count else { throw Failure(message: "A field claims more bytes than the message has.") }
            defer { at += length }
            return Data(data[at..<(at + length)])
        }

        /// The next field's number and wire type; nil at the end.
        package mutating func tag() throws -> (number: Int, wire: WireType)? {
            guard !atEnd else { return nil }
            let key = try varint()
            guard let wire = WireType(rawValue: Int(key & 7)) else { throw Failure(message: "An unknown wire type \(key & 7).") }
            return (Int(key >> 3), wire)
        }

        package mutating func skip(_ wire: WireType) throws {
            switch wire {
            case .varint: _ = try varint()
            case .fixed64: _ = try fixed64()
            case .fixed32: _ = try fixed32()
            case .lengthDelimited: _ = try bytes()
            case .startGroup, .endGroup: throw Failure(message: "Groups aren't read.")
            }
        }
    }

    package struct Writer {
        package private(set) var data = Data()

        package mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            data.append(UInt8(value))
        }

        package mutating func tag(_ number: Int, _ wire: WireType) { varint(UInt64(number) << 3 | UInt64(wire.rawValue)) }

        package mutating func fixed32(_ value: UInt32) { for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) } }
        package mutating func fixed64(_ value: UInt64) { for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) } }

        package mutating func bytes(_ value: Data) {
            varint(UInt64(value.count))
            data.append(value)
        }

        package mutating func field(_ number: Int, bytes value: Data) {
            tag(number, .lengthDelimited)
            bytes(value)
        }

        package mutating func field(_ number: Int, string value: String) { field(number, bytes: Data(value.utf8)) }
    }

    package static func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }
    package static func unzigzag(_ value: UInt64) -> Int64 { Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }

    // MARK: Descriptors

    package struct Field: Equatable, Sendable {
        package var name: String
        package var jsonName: String
        package var number: Int
        package var repeated: Bool
        package var type: Int
        /// A message's or an enum's full name, `.` first.
        package var typeName: String
        package var oneofIndex: Int?
        package var proto3Optional: Bool

        package var isMessage: Bool { type == 11 }
        package var isEnum: Bool { type == 14 }
        /// Numbers packed in one length-delimited field when repeated (proto3's default).
        package var isPackable: Bool { ![9, 11, 12, 10].contains(type) }
    }

    package struct Message: Equatable, Sendable {
        package var fullName: String
        package var fields: [Field]
        package var isMapEntry: Bool
        package var oneofs: [String]
    }

    package struct Enum: Equatable, Sendable {
        package var fullName: String
        package var values: [(name: String, number: Int)]

        package static func == (a: Enum, b: Enum) -> Bool { a.fullName == b.fullName && a.values.map(\.name) == b.values.map(\.name) }
    }

    package struct Method: Equatable, Sendable, Hashable {
        package var name: String
        package var input: String
        package var output: String
        package var clientStreaming: Bool
        package var serverStreaming: Bool

        /// Bruno's `methodType`.
        package var kind: String {
            switch (clientStreaming, serverStreaming) {
            case (false, false): "unary"
            case (true, false): "client-streaming"
            case (false, true): "server-streaming"
            case (true, true): "bidi-streaming"
            }
        }
    }

    package struct Service: Equatable, Sendable {
        package var fullName: String
        package var methods: [Method]
    }

    package struct File: Equatable, Sendable {
        package var name: String
        package var package: String
        package var dependencies: [String]
        package var messages: [Message]
        package var enums: [Enum]
        package var services: [Service]
    }

    /// A FileDescriptorProto's bytes, read.
    package static func file(_ data: Data) throws -> File {
        var reader = Reader(data)
        var file = File(name: "", package: "", dependencies: [], messages: [], enums: [], services: [])
        var messageBytes: [Data] = []
        var enumBytes: [Data] = []
        var serviceBytes: [Data] = []
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (1, .lengthDelimited): file.name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, .lengthDelimited): file.package = String(decoding: try reader.bytes(), as: UTF8.self)
            case (3, .lengthDelimited): file.dependencies.append(String(decoding: try reader.bytes(), as: UTF8.self))
            case (4, .lengthDelimited): messageBytes.append(try reader.bytes())
            case (5, .lengthDelimited): enumBytes.append(try reader.bytes())
            case (6, .lengthDelimited): serviceBytes.append(try reader.bytes())
            default: try reader.skip(wire)
            }
        }
        let scope = file.package.isEmpty ? "" : "." + file.package
        for bytes in messageBytes { try message(bytes, scope: scope, into: &file) }
        for bytes in enumBytes { file.enums.append(try enumeration(bytes, scope: scope)) }
        for bytes in serviceBytes { file.services.append(try service(bytes, scope: scope)) }
        return file
    }

    /// A FileDescriptorSet's files — what `protoc --descriptor_set_out` writes.
    package static func fileSet(_ data: Data) throws -> [File] {
        var reader = Reader(data)
        var files: [File] = []
        while let (number, wire) = try reader.tag() {
            if number == 1, wire == .lengthDelimited { files.append(try file(try reader.bytes())) } else { try reader.skip(wire) }
        }
        return files
    }

    private static func message(_ data: Data, scope: String, into file: inout File) throws {
        var reader = Reader(data)
        var name = ""
        var fieldBytes: [Data] = []
        var nested: [Data] = []
        var enums: [Data] = []
        var oneofs: [String] = []
        var isMapEntry = false
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (1, .lengthDelimited): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, .lengthDelimited): fieldBytes.append(try reader.bytes())
            case (3, .lengthDelimited): nested.append(try reader.bytes())
            case (4, .lengthDelimited): enums.append(try reader.bytes())
            case (7, .lengthDelimited):
                // MessageOptions: map_entry is its field 7.
                var options = Reader(try reader.bytes())
                while let (option, optionWire) = try options.tag() {
                    if option == 7, optionWire == .varint { isMapEntry = try options.varint() != 0 } else { try options.skip(optionWire) }
                }
            case (8, .lengthDelimited):
                var oneof = Reader(try reader.bytes())
                var oneofName = ""
                while let (field, fieldWire) = try oneof.tag() {
                    if field == 1, fieldWire == .lengthDelimited { oneofName = String(decoding: try oneof.bytes(), as: UTF8.self) } else { try oneof.skip(fieldWire) }
                }
                oneofs.append(oneofName)
            default: try reader.skip(wire)
            }
        }
        let fullName = scope + "." + name
        file.messages.append(Message(fullName: fullName, fields: try fieldBytes.map(field), isMapEntry: isMapEntry, oneofs: oneofs))
        for bytes in nested { try message(bytes, scope: fullName, into: &file) }
        for bytes in enums { file.enums.append(try enumeration(bytes, scope: fullName)) }
    }

    private static func field(_ data: Data) throws -> Field {
        var reader = Reader(data)
        var field = Field(name: "", jsonName: "", number: 0, repeated: false, type: 0, typeName: "", oneofIndex: nil, proto3Optional: false)
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (1, .lengthDelimited): field.name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (3, .varint): field.number = Int(try reader.varint())
            case (4, .varint): field.repeated = try reader.varint() == 3
            case (5, .varint): field.type = Int(try reader.varint())
            case (6, .lengthDelimited): field.typeName = String(decoding: try reader.bytes(), as: UTF8.self)
            case (9, .varint): field.oneofIndex = Int(try reader.varint())
            case (10, .lengthDelimited): field.jsonName = String(decoding: try reader.bytes(), as: UTF8.self)
            case (17, .varint): field.proto3Optional = try reader.varint() != 0
            default: try reader.skip(wire)
            }
        }
        if field.jsonName.isEmpty { field.jsonName = camelCase(field.name) }
        return field
    }

    /// protoc's json_name: `user_id` → `userId`.
    package static func camelCase(_ name: String) -> String {
        var out = ""
        var upper = false
        for c in name {
            if c == "_" {
                upper = true
            } else {
                out.append(upper ? Character(c.uppercased()) : c)
                upper = false
            }
        }
        return out
    }

    private static func enumeration(_ data: Data, scope: String) throws -> Enum {
        var reader = Reader(data)
        var result = Enum(fullName: "", values: [])
        var name = ""
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (1, .lengthDelimited): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, .lengthDelimited):
                var value = Reader(try reader.bytes())
                var valueName = ""
                var valueNumber = 0
                while let (field, fieldWire) = try value.tag() {
                    switch (field, fieldWire) {
                    case (1, .lengthDelimited): valueName = String(decoding: try value.bytes(), as: UTF8.self)
                    case (2, .varint): valueNumber = Int(Int32(truncatingIfNeeded: try value.varint()))
                    default: try value.skip(fieldWire)
                    }
                }
                result.values.append((valueName, valueNumber))
            default: try reader.skip(wire)
            }
        }
        result.fullName = scope + "." + name
        return result
    }

    private static func service(_ data: Data, scope: String) throws -> Service {
        var reader = Reader(data)
        var name = ""
        var methods: [Method] = []
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (1, .lengthDelimited): name = String(decoding: try reader.bytes(), as: UTF8.self)
            case (2, .lengthDelimited):
                var method = Reader(try reader.bytes())
                var m = Method(name: "", input: "", output: "", clientStreaming: false, serverStreaming: false)
                while let (field, fieldWire) = try method.tag() {
                    switch (field, fieldWire) {
                    case (1, .lengthDelimited): m.name = String(decoding: try method.bytes(), as: UTF8.self)
                    case (2, .lengthDelimited): m.input = String(decoding: try method.bytes(), as: UTF8.self)
                    case (3, .lengthDelimited): m.output = String(decoding: try method.bytes(), as: UTF8.self)
                    case (5, .varint): m.clientStreaming = try method.varint() != 0
                    case (6, .varint): m.serverStreaming = try method.varint() != 0
                    default: try method.skip(fieldWire)
                    }
                }
                methods.append(m)
            default: try reader.skip(wire)
            }
        }
        return Service(fullName: (scope.isEmpty ? "" : String(scope.dropFirst()) + ".") + name, methods: methods)
    }

    // MARK: A registry

    /// Every message, enum and service of a set of files, by full name.
    package struct Registry: Equatable, Sendable {
        package var messages: [String: Message] = [:]
        package var enums: [String: Enum] = [:]
        package var services: [Service] = []
        package var files: [String] = []

        package init(_ files: [File] = []) {
            for file in files { add(file) }
        }

        package mutating func add(_ file: File) {
            guard !files.contains(file.name) else { return }
            files.append(file.name)
            for message in file.messages { messages[message.fullName] = message }
            for item in file.enums { enums[item.fullName] = item }
            for service in file.services where !services.contains(where: { $0.fullName == service.fullName }) { services.append(service) }
        }

        /// `/package.Service/Method`, as gRPC's path names it.
        package func method(path: String) -> (Service, Method)? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2 else { return nil }
            guard let service = services.first(where: { $0.fullName == parts[0] }), let method = service.methods.first(where: { $0.name == parts[1] })
            else { return nil }
            return (service, method)
        }

        /// Every method, as `/package.Service/Method`.
        package var paths: [String] { services.flatMap { service in service.methods.map { "/\(service.fullName)/\($0.name)" } } }
    }

    // MARK: JSON → bytes

    /// A message as proto3's JSON writes it, in bytes.
    package static func encode(_ json: JSONValue, as typeName: String, registry: Registry) throws -> Data {
        if let special = try wellKnownEncode(json, typeName) { return special }
        guard let message = registry.messages[typeName] else { throw Failure(message: "The schema has no message \(typeName.dropFirst()).") }
        guard case .object(let object) = json else {
            throw Failure(message: "\(typeName.dropFirst()) is a message: an object, { … }, not \(json.pretty).")
        }
        var writer = Writer()
        for (key, value) in object {
            guard let field = message.fields.first(where: { $0.jsonName == key || $0.name == key }) else {
                throw Failure(message: "\(typeName.dropFirst()) has no field “\(key)” — it has \(message.fields.map(\.jsonName).joined(separator: ", ")).")
            }
            if value == .null { continue }
            try encode(value, field: field, registry: registry, into: &writer)
        }
        return writer.data
    }

    private static func encode(_ value: JSONValue, field: Field, registry: Registry, into writer: inout Writer) throws {
        if let entry = registry.messages[field.typeName], entry.isMapEntry {
            guard case .object(let map) = value else { throw Failure(message: "\(field.jsonName) is a map: an object.") }
            guard let keyField = entry.fields.first(where: { $0.number == 1 }), let valueField = entry.fields.first(where: { $0.number == 2 }) else { return }
            for (key, item) in map.sorted(by: { $0.key < $1.key }) {
                var pair = Writer()
                let keyValue: JSONValue = keyField.type == 8 ? .bool(key == "true") : (keyField.type == 9 ? .string(key) : .string(key))
                try encodeSingle(keyValue, field: keyField, registry: registry, into: &pair)
                try encodeSingle(item, field: valueField, registry: registry, into: &pair)
                writer.field(field.number, bytes: pair.data)
            }
            return
        }
        guard field.repeated else { return try encodeSingle(value, field: field, registry: registry, into: &writer) }
        guard case .array(let items) = value else { throw Failure(message: "\(field.jsonName) is repeated: a list, [ … ].") }
        if field.isPackable {
            var packed = Writer()
            for item in items { try scalar(item, field: field, registry: registry, into: &packed) }
            writer.field(field.number, bytes: packed.data)
        } else {
            for item in items { try encodeSingle(item, field: field, registry: registry, into: &writer) }
        }
    }

    private static func encodeSingle(_ value: JSONValue, field: Field, registry: Registry, into writer: inout Writer) throws {
        switch field.type {
        case 11:
            writer.field(field.number, bytes: try encode(value, as: field.typeName, registry: registry))
        case 9:
            guard let text = value.string else { throw Failure(message: "\(field.jsonName) is a string.") }
            writer.field(field.number, string: text)
        case 12:
            guard let text = value.string, let data = Data(base64Encoded: text) ?? Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
            else { throw Failure(message: "\(field.jsonName) is bytes: base64 text.") }
            writer.field(field.number, bytes: data)
        case 1, 6, 16:
            writer.tag(field.number, .fixed64)
            try scalar(value, field: field, registry: registry, into: &writer)
        case 2, 7, 15:
            writer.tag(field.number, .fixed32)
            try scalar(value, field: field, registry: registry, into: &writer)
        default:
            writer.tag(field.number, .varint)
            try scalar(value, field: field, registry: registry, into: &writer)
        }
    }

    /// A number, a bool or an enum's value, without its tag.
    private static func scalar(_ value: JSONValue, field: Field, registry: Registry, into writer: inout Writer) throws {
        func number() throws -> Double {
            switch value {
            case .int(let n): return Double(n)
            case .double(let n): return n
            case .string(let text):
                switch text {
                case "NaN": return .nan
                case "Infinity": return .infinity
                case "-Infinity": return -.infinity
                default:
                    guard let n = Double(text) else { throw Failure(message: "\(field.jsonName) is a number, not “\(text)”.") }
                    return n
                }
            case .bool(let flag): return flag ? 1 : 0
            default: throw Failure(message: "\(field.jsonName) is a number.")
            }
        }
        func integer() throws -> Int64 {
            if case .string(let text) = value, let n = Int64(text) { return n }
            if case .int(let n) = value { return Int64(n) }
            let n = try number()
            guard n == n.rounded(), abs(n) < 9.3e18 else { throw Failure(message: "\(field.jsonName) is a whole number.") }
            return Int64(n)
        }
        func unsigned() throws -> UInt64 {
            if case .string(let text) = value, let n = UInt64(text) { return n }
            return UInt64(bitPattern: try integer())
        }
        switch field.type {
        case 1: writer.fixed64(try number().bitPattern)
        case 2: writer.fixed32(Float(try number()).bitPattern)
        case 3, 5: writer.varint(UInt64(bitPattern: try integer()))
        case 4, 13: writer.varint(try unsigned())
        case 6: writer.fixed64(try unsigned())
        case 7: writer.fixed32(UInt32(truncatingIfNeeded: try unsigned()))
        case 8:
            guard case .bool(let flag) = value else { throw Failure(message: "\(field.jsonName) is true or false.") }
            writer.varint(flag ? 1 : 0)
        case 14:
            if case .string(let name) = value {
                guard let found = registry.enums[field.typeName]?.values.first(where: { $0.name == name }) else {
                    let names = registry.enums[field.typeName]?.values.map(\.name).joined(separator: ", ") ?? ""
                    throw Failure(message: "\(field.jsonName) is one of \(names), not “\(name)”.")
                }
                writer.varint(UInt64(bitPattern: Int64(found.number)))
            } else {
                writer.varint(UInt64(bitPattern: try integer()))
            }
        case 15: writer.fixed32(UInt32(bitPattern: Int32(truncatingIfNeeded: try integer())))
        case 16: writer.fixed64(UInt64(bitPattern: try integer()))
        case 17: writer.varint(zigzag(try integer()))
        case 18: writer.varint(zigzag(try integer()))
        default: throw Failure(message: "\(field.jsonName)'s type (\(field.type)) isn't written.")
        }
    }

    // MARK: bytes → JSON

    /// A message's bytes as proto3's JSON: what is set, numbers of 64 bits as
    /// strings, enums by name, bytes in base64.
    package static func decode(_ data: Data, as typeName: String, registry: Registry) throws -> JSONValue {
        if let special = try wellKnownDecode(data, typeName, registry: registry) { return special }
        guard let message = registry.messages[typeName] else { throw Failure(message: "The schema has no message \(typeName.dropFirst()).") }
        var reader = Reader(data)
        var out: [String: JSONValue] = [:]
        var order: [String] = []
        while let (number, wire) = try reader.tag() {
            guard let field = message.fields.first(where: { $0.number == number }) else {
                try reader.skip(wire)
                continue
            }
            if !order.contains(field.jsonName) { order.append(field.jsonName) }
            if let entry = registry.messages[field.typeName], entry.isMapEntry {
                let pair = try decode(try reader.bytes(), entryOf: entry, registry: registry)
                var map = out[field.jsonName]?.object ?? [:]
                map[pair.key] = pair.value
                out[field.jsonName] = .object(map)
                continue
            }
            if field.repeated, wire == .lengthDelimited, field.isPackable {
                var packed = Reader(try reader.bytes())
                var items = out[field.jsonName]?.array ?? []
                while !packed.atEnd { items.append(try value(&packed, field: field, wire: packedWire(field), registry: registry)) }
                out[field.jsonName] = .array(items)
                continue
            }
            let item = try value(&reader, field: field, wire: wire, registry: registry)
            if field.repeated {
                out[field.jsonName] = .array((out[field.jsonName]?.array ?? []) + [item])
            } else {
                out[field.jsonName] = item
            }
        }
        return .object(out)
    }

    private static func packedWire(_ field: Field) -> WireType {
        switch field.type {
        case 1, 6, 16: .fixed64
        case 2, 7, 15: .fixed32
        default: .varint
        }
    }

    private static func decode(_ data: Data, entryOf entry: Message, registry: Registry) throws -> (key: String, value: JSONValue) {
        var reader = Reader(data)
        var key = ""
        var value: JSONValue = .null
        while let (number, wire) = try reader.tag() {
            guard let field = entry.fields.first(where: { $0.number == number }) else {
                try reader.skip(wire)
                continue
            }
            let item = try Self.value(&reader, field: field, wire: wire, registry: registry)
            if number == 1 {
                switch item {
                case .string(let text): key = text
                case .int(let n): key = String(n)
                case .bool(let flag): key = flag ? "true" : "false"
                default: key = item.pretty
                }
            } else {
                value = item
            }
        }
        return (key, value)
    }

    private static func value(_ reader: inout Reader, field: Field, wire: WireType, registry: Registry) throws -> JSONValue {
        switch field.type {
        case 1: return double(Double(bitPattern: try reader.fixed64()))
        case 2: return double(Double(Float(bitPattern: try reader.fixed32())))
        case 3: return .string(String(Int64(bitPattern: try reader.varint())))
        case 4: return .string(String(try reader.varint()))
        case 5: return .int(Int(Int32(truncatingIfNeeded: try reader.varint())))
        case 6: return .string(String(try reader.fixed64()))
        case 7: return .int(Int(try reader.fixed32()))
        case 8: return .bool(try reader.varint() != 0)
        case 9: return .string(String(decoding: try reader.bytes(), as: UTF8.self))
        case 11: return try decode(try reader.bytes(), as: field.typeName, registry: registry)
        case 12: return .string(try reader.bytes().base64EncodedString())
        case 13: return .int(Int(UInt32(truncatingIfNeeded: try reader.varint())))
        case 14:
            let number = Int(Int32(truncatingIfNeeded: try reader.varint()))
            return registry.enums[field.typeName]?.values.first { $0.number == number }.map { .string($0.name) } ?? .int(number)
        case 15: return .int(Int(Int32(bitPattern: try reader.fixed32())))
        case 16: return .string(String(Int64(bitPattern: try reader.fixed64())))
        case 17: return .int(Int(unzigzag(try reader.varint())))
        case 18: return .string(String(unzigzag(try reader.varint())))
        default:
            try reader.skip(wire)
            return .null
        }
    }

    private static func double(_ value: Double) -> JSONValue {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return .string(value > 0 ? "Infinity" : "-Infinity") }
        return value == value.rounded() && abs(value) < 1e15 ? .int(Int(value)) : .double(value)
    }

    // MARK: Well-known types

    package static let wrappers: [String: Int] = [
        ".google.protobuf.DoubleValue": 1, ".google.protobuf.FloatValue": 2, ".google.protobuf.Int64Value": 3,
        ".google.protobuf.UInt64Value": 4, ".google.protobuf.Int32Value": 5, ".google.protobuf.UInt32Value": 13,
        ".google.protobuf.BoolValue": 8, ".google.protobuf.StringValue": 9, ".google.protobuf.BytesValue": 12,
    ]

    private static func wrapperField(_ type: Int) -> Field {
        Field(name: "value", jsonName: "value", number: 1, repeated: false, type: type, typeName: "", oneofIndex: nil, proto3Optional: false)
    }

    private static func wellKnownEncode(_ json: JSONValue, _ typeName: String) throws -> Data? {
        var writer = Writer()
        switch typeName {
        case ".google.protobuf.Timestamp":
            guard let text = json.string, let date = timestamp(text) else { throw Failure(message: "A Timestamp is RFC 3339 text: \"2026-01-02T03:04:05Z\".") }
            let seconds = date.timeIntervalSince1970.rounded(.down)
            if seconds != 0 { writer.tag(1, .varint); writer.varint(UInt64(bitPattern: Int64(seconds))) }
            let nanos = Int64(((date.timeIntervalSince1970 - seconds) * 1e9).rounded())
            if nanos != 0 { writer.tag(2, .varint); writer.varint(UInt64(nanos)) }
            return writer.data
        case ".google.protobuf.Duration":
            guard let text = json.string, text.hasSuffix("s"), let value = Double(text.dropLast()) else {
                throw Failure(message: "A Duration is seconds with an s: \"1.5s\".")
            }
            let seconds = value.rounded(.towardZero)
            if seconds != 0 { writer.tag(1, .varint); writer.varint(UInt64(bitPattern: Int64(seconds))) }
            let nanos = Int64(((value - seconds) * 1e9).rounded())
            if nanos != 0 { writer.tag(2, .varint); writer.varint(UInt64(bitPattern: nanos)) }
            return writer.data
        case ".google.protobuf.Empty":
            return Data()
        case ".google.protobuf.Struct":
            guard case .object(let object) = json else { throw Failure(message: "A Struct is an object.") }
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                var entry = Writer()
                entry.field(1, string: key)
                entry.field(2, bytes: try structValue(value))
                writer.field(1, bytes: entry.data)
            }
            return writer.data
        case ".google.protobuf.Value":
            return try structValue(json)
        case ".google.protobuf.ListValue":
            guard case .array(let items) = json else { throw Failure(message: "A ListValue is a list.") }
            for item in items { writer.field(1, bytes: try structValue(item)) }
            return writer.data
        default:
            guard let type = wrappers[typeName] else { return nil }
            try encodeSingle(json, field: wrapperField(type), registry: Registry(), into: &writer)
            return writer.data
        }
    }

    private static func structValue(_ value: JSONValue) throws -> Data {
        var writer = Writer()
        switch value {
        case .null: writer.tag(1, .varint); writer.varint(0)
        case .int(let n): writer.tag(2, .fixed64); writer.fixed64(Double(n).bitPattern)
        case .double(let n): writer.tag(2, .fixed64); writer.fixed64(n.bitPattern)
        case .string(let text): writer.field(3, string: text)
        case .bool(let flag): writer.tag(4, .varint); writer.varint(flag ? 1 : 0)
        case .object: writer.field(5, bytes: try wellKnownEncode(value, ".google.protobuf.Struct") ?? Data())
        case .array: writer.field(6, bytes: try wellKnownEncode(value, ".google.protobuf.ListValue") ?? Data())
        }
        return writer.data
    }

    private static func wellKnownDecode(_ data: Data, _ typeName: String, registry: Registry) throws -> JSONValue? {
        var reader = Reader(data)
        switch typeName {
        case ".google.protobuf.Timestamp", ".google.protobuf.Duration":
            var seconds: Int64 = 0
            var nanos: Int64 = 0
            while let (number, wire) = try reader.tag() {
                switch number {
                case 1: seconds = Int64(bitPattern: try reader.varint())
                case 2: nanos = Int64(Int32(truncatingIfNeeded: try reader.varint()))
                default: try reader.skip(wire)
                }
            }
            if typeName.hasSuffix("Duration") {
                let total = Double(seconds) + Double(nanos) / 1e9
                return .string((total == total.rounded() ? String(Int64(total)) : String(format: "%.9g", total)) + "s")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = nanos == 0 ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
            return .string(formatter.string(from: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)))
        case ".google.protobuf.Empty":
            return .object([:])
        case ".google.protobuf.Struct":
            var object: [String: JSONValue] = [:]
            while let (number, wire) = try reader.tag() {
                guard number == 1 else {
                    try reader.skip(wire)
                    continue
                }
                var entry = Reader(try reader.bytes())
                var key = ""
                var value: JSONValue = .null
                while let (field, fieldWire) = try entry.tag() {
                    if field == 1 { key = String(decoding: try entry.bytes(), as: UTF8.self) } else if field == 2 { value = try structValue(try entry.bytes()) } else { try entry.skip(fieldWire) }
                }
                object[key] = value
            }
            return .object(object)
        case ".google.protobuf.Value":
            return try structValue(data)
        case ".google.protobuf.ListValue":
            var items: [JSONValue] = []
            while let (number, wire) = try reader.tag() {
                if number == 1 { items.append(try structValue(try reader.bytes())) } else { try reader.skip(wire) }
            }
            return .array(items)
        default:
            guard let type = wrappers[typeName] else { return nil }
            var value: JSONValue = type == 8 ? .bool(false) : (type == 9 || type == 12 ? .string("") : .int(0))
            while let (number, wire) = try reader.tag() {
                if number == 1 { value = try Self.value(&reader, field: wrapperField(type), wire: wire, registry: registry) } else { try reader.skip(wire) }
            }
            return value
        }
    }

    private static func structValue(_ data: Data) throws -> JSONValue {
        var reader = Reader(data)
        var value: JSONValue = .null
        while let (number, wire) = try reader.tag() {
            switch number {
            case 1: _ = try reader.varint(); value = .null
            case 2: value = double(Double(bitPattern: try reader.fixed64()))
            case 3: value = .string(String(decoding: try reader.bytes(), as: UTF8.self))
            case 4: value = .bool(try reader.varint() != 0)
            case 5: value = try wellKnownDecode(try reader.bytes(), ".google.protobuf.Struct", registry: Registry()) ?? .null
            case 6: value = try wellKnownDecode(try reader.bytes(), ".google.protobuf.ListValue", registry: Registry()) ?? .null
            default: try reader.skip(wire)
            }
        }
        return value
    }

    package static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: A message to start from

    /// A message's fields with an empty value each, nested messages one
    /// level deep — a body to fill in, as Bruno and grpcurl's describe show.
    package static func skeleton(_ typeName: String, registry: Registry, depth: Int = 0) -> JSONValue {
        switch typeName {
        case ".google.protobuf.Timestamp": return .string(ISO8601DateFormatter().string(from: Date()))
        case ".google.protobuf.Duration": return "1s"
        case ".google.protobuf.Struct": return .object([:])
        default: break
        }
        if let type = wrappers[typeName] { return type == 8 ? .bool(false) : (type == 9 || type == 12 ? .string("") : .int(0)) }
        guard let message = registry.messages[typeName] else { return .object([:]) }
        var out: [String: JSONValue] = [:]
        var oneofsSeen: Set<Int> = []
        for field in message.fields {
            // A oneof: its first field only.
            if let oneof = field.oneofIndex, !field.proto3Optional {
                guard oneofsSeen.insert(oneof).inserted else { continue }
            }
            if let entry = registry.messages[field.typeName], entry.isMapEntry {
                out[field.jsonName] = .object([:])
            } else if field.repeated {
                out[field.jsonName] = .array([])
            } else if field.isMessage {
                out[field.jsonName] = depth < 2 ? skeleton(field.typeName, registry: registry, depth: depth + 1) : .object([:])
            } else if field.isEnum {
                out[field.jsonName] = .string(registry.enums[field.typeName]?.values.first?.name ?? "")
            } else {
                switch field.type {
                case 8: out[field.jsonName] = .bool(false)
                case 9, 12: out[field.jsonName] = .string("")
                case 3, 4, 6, 16, 18: out[field.jsonName] = .string("0")
                default: out[field.jsonName] = .int(0)
                }
            }
        }
        return .object(out)
    }
}
