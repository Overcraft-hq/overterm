import Foundation

/// Kafka's protocol as bytes, both ways — no client library: the client
/// that fits (`swift-kafka-client`) wants macOS 15, the app runs from 13
/// (issue-tracker#134). Requests and answers of the APIs the panel uses,
/// each in its non-flexible versions only (no tagged fields), the version
/// the broker and this both speak picked from ApiVersions; record batches
/// (magic 2) read and written. Pure. docs/architecture.md, Kafka.
package enum KafkaWire {
    package struct Failure: LocalizedError, Equatable {
        package let message: String
        package init(_ message: String) { self.message = message }
        package var errorDescription: String? { message }
    }

    /// The APIs, their keys, and the versions this reads: `range`'s lower
    /// end the oldest a Kafka 4 broker still takes where it dropped older
    /// ones (KIP-896), its upper the last before tagged fields.
    package enum API: Int16, CaseIterable, Sendable {
        case produce = 0, fetch = 1, listOffsets = 2, metadata = 3, offsetFetch = 9, findCoordinator = 10
        case describeGroups = 15, listGroups = 16, saslHandshake = 17, apiVersions = 18, saslAuthenticate = 36

        package var range: ClosedRange<Int16> {
            switch self {
            case .produce: 3...8
            case .fetch: 4...11
            case .listOffsets: 1...5
            case .metadata: 1...8
            case .offsetFetch: 2...5
            case .findCoordinator: 0...2
            case .describeGroups: 0...4
            case .listGroups: 0...2
            case .saslHandshake: 1...1
            case .apiVersions: 0...0
            case .saslAuthenticate: 0...1
            }
        }

        package var name: String {
            switch self {
            case .produce: "Produce"
            case .fetch: "Fetch"
            case .listOffsets: "ListOffsets"
            case .metadata: "Metadata"
            case .offsetFetch: "OffsetFetch"
            case .findCoordinator: "FindCoordinator"
            case .describeGroups: "DescribeGroups"
            case .listGroups: "ListGroups"
            case .saslHandshake: "SaslHandshake"
            case .apiVersions: "ApiVersions"
            case .saslAuthenticate: "SaslAuthenticate"
            }
        }
    }

    /// The version to speak: the newest both say, or why there is none.
    package static func version(of api: API, broker: [Int16: ClosedRange<Int16>]) throws -> Int16 {
        guard let theirs = broker[api.rawValue] else { throw Failure("The broker doesn't speak \(api.name).") }
        let mine = api.range
        guard theirs.lowerBound <= mine.upperBound, mine.lowerBound <= theirs.upperBound else {
            let when = theirs.lowerBound > mine.upperBound ? "only from version \(theirs.lowerBound)" : "only up to version \(theirs.upperBound)"
            throw Failure("The broker speaks \(api.name) \(when); Overterm speaks \(mine.lowerBound)–\(mine.upperBound).")
        }
        return min(mine.upperBound, theirs.upperBound)
    }

    // MARK: Bytes

    package struct Writer {
        package private(set) var bytes: [UInt8] = []
        package init() {}

        package mutating func int8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
        package mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
        package mutating func int16(_ v: Int16) { append(UInt16(bitPattern: v)) }
        package mutating func int32(_ v: Int32) { append(UInt32(bitPattern: v)) }
        package mutating func uint32(_ v: UInt32) { append(v) }
        package mutating func int64(_ v: Int64) { append(UInt64(bitPattern: v)) }

        private mutating func append<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
        }

        package mutating func string(_ s: String?) {
            guard let s else { return int16(-1) }
            // A protocol string is at most Int16.max bytes; names are checked long before.
            let utf8 = Array(s.utf8.prefix(Int(Int16.max)))
            int16(Int16(utf8.count))
            bytes += utf8
        }

        package mutating func data(_ b: [UInt8]?) {
            guard let b else { return int32(-1) }
            int32(Int32(b.count))
            bytes += b
        }

        package mutating func array<T>(_ items: [T]?, _ each: (inout Writer, T) -> Void) {
            guard let items else { return int32(-1) }
            int32(Int32(items.count))
            for item in items { each(&self, item) }
        }

        /// Zig-zag, then 7 bits a byte, as protobuf.
        package mutating func varint(_ v: Int64) {
            var u = UInt64(bitPattern: (v << 1) ^ (v >> 63))
            while u >= 0x80 {
                bytes.append(UInt8(u & 0x7F) | 0x80)
                u >>= 7
            }
            bytes.append(UInt8(u))
        }

        package mutating func varData(_ b: [UInt8]?) {
            guard let b else { return varint(-1) }
            varint(Int64(b.count))
            bytes += b
        }

        package mutating func raw(_ b: [UInt8]) { bytes += b }
    }

    package struct Reader {
        package let bytes: [UInt8]
        package private(set) var at: Int
        private let end: Int

        package init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
            self.bytes = bytes
            at = start
            self.end = min(end ?? bytes.count, bytes.count)
        }

        package var remaining: Int { end - at }

        package mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= remaining else { throw Failure("Kafka's answer ended early.") }
            defer { at += count }
            return bytes[at..<at + count]
        }

        private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            var v: T = 0
            for byte in try take(MemoryLayout<T>.size) { v = v << 8 | T(byte) }
            return v
        }

        package mutating func int8() throws -> Int8 { Int8(bitPattern: try integer(UInt8.self)) }
        package mutating func bool() throws -> Bool { try int8() != 0 }
        package mutating func int16() throws -> Int16 { Int16(bitPattern: try integer(UInt16.self)) }
        package mutating func int32() throws -> Int32 { Int32(bitPattern: try integer(UInt32.self)) }
        package mutating func uint32() throws -> UInt32 { try integer(UInt32.self) }
        package mutating func int64() throws -> Int64 { Int64(bitPattern: try integer(UInt64.self)) }

        package mutating func string() throws -> String? {
            let length = Int(try int16())
            guard length >= 0 else { return nil }
            return String(decoding: try take(length), as: UTF8.self)
        }

        package mutating func data() throws -> [UInt8]? {
            let length = Int(try int32())
            guard length >= 0 else { return nil }
            return Array(try take(length))
        }

        package mutating func array<T>(_ each: (inout Reader) throws -> T) throws -> [T] {
            let count = Int(try int32())
            guard count > 0 else { return [] }
            // Each element is at least a byte: a count past what is left is a broken answer.
            guard count <= remaining else { throw Failure("Kafka's answer ended early.") }
            var items: [T] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try each(&self)) }
            return items
        }

        package mutating func varint() throws -> Int64 {
            var u: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard shift < 64 else { throw Failure("A varint in Kafka's answer runs past 64 bits.") }
                let byte = try take(1).first!
                u |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { break }
                shift += 7
            }
            return Int64(bitPattern: u >> 1) ^ -Int64(bitPattern: u & 1)
        }

        package mutating func varData() throws -> [UInt8]? {
            let length = Int(try varint())
            guard length >= 0 else { return nil }
            return Array(try take(length))
        }
    }

    // MARK: Frames

    package static let clientID = "overterm"

    /// A request as it goes on the wire: its size, the v1 header, the body.
    package static func request(_ api: API, version: Int16, correlation: Int32, body: [UInt8]) -> [UInt8] {
        var header = Writer()
        header.int16(api.rawValue)
        header.int16(version)
        header.int32(correlation)
        header.string(clientID)
        var frame = Writer()
        frame.int32(Int32(header.bytes.count + body.count))
        frame.raw(header.bytes)
        frame.raw(body)
        return frame.bytes
    }

    /// One whole answer at the start of `bytes`: its correlation id, its
    /// body and the bytes it took; nil until all of it has come.
    package static func answer(_ bytes: [UInt8]) throws -> (correlation: Int32, body: [UInt8], length: Int)? {
        guard bytes.count >= 4 else { return nil }
        var reader = Reader(bytes)
        let size = Int(try reader.int32())
        guard size >= 4, size <= 256 << 20 else { throw Failure("Kafka's answer said it was \(size) bytes long.") }
        guard bytes.count >= 4 + size else { return nil }
        let correlation = try reader.int32()
        return (correlation, Array(bytes[8..<4 + size]), 4 + size)
    }

    // MARK: Errors

    /// A Kafka error code in words.
    package static func error(_ code: Int16) -> String {
        let names: [Int16: String] = [
            -1: "an error the broker didn't name", 1: "OFFSET_OUT_OF_RANGE", 2: "CORRUPT_MESSAGE",
            3: "UNKNOWN_TOPIC_OR_PARTITION — no such topic", 5: "LEADER_NOT_AVAILABLE", 6: "NOT_LEADER_OR_FOLLOWER", 7: "REQUEST_TIMED_OUT",
            10: "MESSAGE_TOO_LARGE", 14: "COORDINATOR_LOAD_IN_PROGRESS", 15: "COORDINATOR_NOT_AVAILABLE", 16: "NOT_COORDINATOR",
            17: "INVALID_TOPIC_EXCEPTION", 19: "NOT_ENOUGH_REPLICAS", 29: "TOPIC_AUTHORIZATION_FAILED — this user may not read or write the topic",
            30: "GROUP_AUTHORIZATION_FAILED — this user may not describe the group", 31: "CLUSTER_AUTHORIZATION_FAILED",
            33: "UNSUPPORTED_SASL_MECHANISM", 34: "ILLEGAL_SASL_STATE", 35: "UNSUPPORTED_VERSION", 58: "SASL_AUTHENTICATION_FAILED",
            69: "GROUP_ID_NOT_FOUND", 87: "INVALID_RECORD",
        ]
        return names[code] ?? "error \(code)"
    }

    // MARK: ApiVersions

    package static func apiVersions(_ body: [UInt8]) throws -> [Int16: ClosedRange<Int16>] {
        var r = Reader(body)
        let code = try r.int16()
        let keys = try r.array { r in (try r.int16(), try r.int16(), try r.int16()) }
        guard code == 0 || !keys.isEmpty else { throw Failure("The broker refused ApiVersions: \(error(code)).") }
        var versions: [Int16: ClosedRange<Int16>] = [:]
        for (key, low, high) in keys where low <= high { versions[key] = low...high }
        return versions
    }

    // MARK: Metadata

    package struct Broker: Equatable, Sendable {
        package var id: Int32
        package var host: String
        package var port: Int32
        package var rack: String?
    }

    package struct Partition: Equatable, Sendable {
        package var index: Int32
        package var error: Int16
        package var leader: Int32
        package var replicas: [Int32]
        package var inSync: [Int32]
        package var offline: [Int32] = []
    }

    package struct Topic: Equatable, Sendable {
        package var name: String
        package var error: Int16
        package var isInternal: Bool
        package var partitions: [Partition]
    }

    package struct Metadata: Equatable, Sendable {
        package var brokers: [Broker]
        package var clusterID: String?
        package var controller: Int32
        package var topics: [Topic]
    }

    /// Metadata, every topic's or those named; `create` lets a broker that
    /// does (`auto.create.topics.enable`) make a missing one — PUBLISH's,
    /// as producers have it, never a read's.
    package static func metadataRequest(version: Int16, topics: [String]?, create: Bool = false) -> [UInt8] {
        var w = Writer()
        w.array(topics) { w, name in w.string(name) }
        if version >= 4 { w.bool(create) }
        if version >= 8 {
            w.bool(false)
            w.bool(false)
        }
        return w.bytes
    }

    package static func metadata(_ body: [UInt8], version: Int16) throws -> Metadata {
        var r = Reader(body)
        if version >= 3 { _ = try r.int32() }
        let brokers = try r.array { r in
            Broker(id: try r.int32(), host: try r.string() ?? "", port: try r.int32(), rack: version >= 1 ? try r.string() : nil)
        }
        let cluster = version >= 2 ? try r.string() : nil
        let controller = version >= 1 ? try r.int32() : -1
        let topics = try r.array { r -> Topic in
            let error = try r.int16()
            let name = try r.string() ?? ""
            let isInternal = version >= 1 ? try r.bool() : false
            let partitions = try r.array { r -> Partition in
                let error = try r.int16()
                let index = try r.int32()
                let leader = try r.int32()
                if version >= 7 { _ = try r.int32() }
                let replicas = try r.array { try $0.int32() }
                let inSync = try r.array { try $0.int32() }
                let offline = version >= 5 ? try r.array { try $0.int32() } : []
                return Partition(index: index, error: error, leader: leader, replicas: replicas, inSync: inSync, offline: offline)
            }
            if version >= 8 { _ = try r.int32() }
            return Topic(name: name, error: error, isInternal: isInternal, partitions: partitions.sorted { $0.index < $1.index })
        }
        return Metadata(brokers: brokers, clusterID: cluster, controller: controller, topics: topics)
    }

    // MARK: ListOffsets

    /// The offset of a partition's next message (`latest`) or its first kept one (`earliest`).
    package static let latest: Int64 = -1
    package static let earliest: Int64 = -2

    package static func listOffsetsRequest(version: Int16, _ asks: [String: [(partition: Int32, timestamp: Int64)]]) -> [UInt8] {
        var w = Writer()
        w.int32(-1)
        if version >= 2 { w.int8(0) }
        w.array(asks.keys.sorted()) { w, topic in
            w.string(topic)
            w.array(asks[topic] ?? []) { w, ask in
                w.int32(ask.partition)
                if version >= 4 { w.int32(-1) }
                w.int64(ask.timestamp)
            }
        }
        return w.bytes
    }

    /// Each topic's partitions' offsets; a partition that failed, its error.
    package static func listOffsets(_ body: [UInt8], version: Int16) throws -> [String: [Int32: Result<Int64, Failure>]] {
        var r = Reader(body)
        if version >= 2 { _ = try r.int32() }
        var out: [String: [Int32: Result<Int64, Failure>]] = [:]
        for (topic, partitions) in try r.array({ r -> (String, [(Int32, Int16, Int64)]) in
            let name = try r.string() ?? ""
            let partitions = try r.array { r -> (Int32, Int16, Int64) in
                let index = try r.int32()
                let error = try r.int16()
                _ = try r.int64()
                let offset = try r.int64()
                if version >= 4 { _ = try r.int32() }
                return (index, error, offset)
            }
            return (name, partitions)
        }) {
            for (index, error, offset) in partitions {
                out[topic, default: [:]][index] = error == 0 ? .success(offset) : .failure(Failure(Self.error(error)))
            }
        }
        return out
    }

    // MARK: Fetch

    package static func fetchRequest(version: Int16, topic: String, partitions: [(partition: Int32, offset: Int64)], maxBytes: Int32) -> [UInt8] {
        var w = Writer()
        w.int32(-1)  // replica_id: a consumer, never a follower
        w.int32(500)  // max_wait_ms
        w.int32(1)  // min_bytes
        w.int32(maxBytes)
        w.int8(0)  // read_uncommitted: what is there, as a console consumer sees it
        if version >= 7 {
            w.int32(0)  // no fetch session
            w.int32(-1)
        }
        w.array([topic]) { w, topic in
            w.string(topic)
            w.array(partitions) { w, p in
                w.int32(p.partition)
                if version >= 9 { w.int32(-1) }
                w.int64(p.offset)
                if version >= 5 { w.int64(-1) }
                w.int32(maxBytes)
            }
        }
        if version >= 7 { w.array([Int]()) { _, _ in } }
        if version >= 11 { w.string("") }
        return w.bytes
    }

    package struct FetchedPartition: Equatable, Sendable {
        package var partition: Int32
        package var error: Int16
        package var highWatermark: Int64
        package var records: [UInt8]
    }

    package static func fetch(_ body: [UInt8], version: Int16) throws -> [FetchedPartition] {
        var r = Reader(body)
        _ = try r.int32()
        if version >= 7 {
            let code = try r.int16()
            _ = try r.int32()
            if code != 0 { throw Failure("Fetch refused: \(error(code)).") }
        }
        var out: [FetchedPartition] = []
        for partitions in try r.array({ r -> [FetchedPartition] in
            _ = try r.string()
            return try r.array { r -> FetchedPartition in
                let index = try r.int32()
                let error = try r.int16()
                let high = try r.int64()
                _ = try r.int64()
                if version >= 5 { _ = try r.int64() }
                _ = try r.array { r in (try r.int64(), try r.int64()) }
                if version >= 11 { _ = try r.int32() }
                return FetchedPartition(partition: index, error: error, highWatermark: high, records: try r.data() ?? [])
            }
        }) {
            out += partitions
        }
        return out
    }

    // MARK: Record batches

    package struct Header: Equatable, Sendable {
        package var key: String
        package var value: [UInt8]?
    }

    package struct Message: Equatable, Sendable {
        package var partition: Int32 = 0
        package var offset: Int64
        package var timestamp: Int64
        package var key: [UInt8]?
        package var value: [UInt8]?
        package var headers: [Header] = []
        /// The value's whole size, when `value` keeps only its start.
        package var valueSize = 0
    }

    package enum Codec: Int16, Sendable {
        case none = 0, gzip, snappy, lz4, zstd
        package var name: String { ["none", "gzip", "snappy", "lz4", "zstd"][Int(rawValue)] }
    }

    /// What a fetch may decode in all: batches past it wait for the next.
    package static let decodeBudget = 128 << 20
    /// What of a key or a value is kept: the grid shows less.
    package static let kept = 64 << 10

    /// The messages of a fetch's records: every whole batch, a transaction's
    /// markers left out, one cut off at the end (the size asked for) left
    /// for the next fetch — and the offset where the next fetch starts (nil:
    /// no batch was whole). Decoding stops once `wanted` messages from
    /// `from` on are in, or `decodeBudget` bytes were opened. A compressed
    /// batch is opened by `inflate`; a key or value keeps its first `kept`
    /// bytes.
    package static func messages(
        _ records: [UInt8], from: Int64 = 0, wanted: Int = .max, inflate: (Codec, [UInt8]) throws -> [UInt8]
    ) throws -> (messages: [Message], next: Int64?) {
        var messages: [Message] = []
        var next: Int64?
        var decoded = 0
        var at = 0
        while records.count - at >= 12 {
            var head = Reader(records, from: at)
            let baseOffset = try head.int64()
            let length = Int(try head.int32())
            let end = at + 12 + length
            guard length > 0, end <= records.count else { break }
            var r = Reader(records, from: at + 12, to: end)
            _ = try r.int32()
            let magic = try r.int8()
            guard magic == 2 else {
                throw Failure("A batch in the old message format (magic \(magic)) — written before Kafka 0.11 — isn't read here.")
            }
            let crc = try r.uint32()
            let checked = Array(records[(at + 21)..<end])
            guard crc32c(checked) == crc else { throw Failure("A batch at offset \(baseOffset) fails its CRC: the bytes are damaged.") }
            let attributes = try r.int16()
            let lastOffsetDelta = try r.int32()
            let batchNext = baseOffset + Int64(lastOffsetDelta) + 1
            let baseTimestamp = try r.int64()
            let maxTimestamp = try r.int64()
            _ = try r.int64()
            _ = try r.int16()
            _ = try r.int32()
            let count = Int(try r.int32())
            guard count >= 0 else { throw Failure("A batch at offset \(baseOffset) says it holds \(count) records.") }
            // The broker's own time (LogAppendTime): every record's is the batch's.
            let appendTime = attributes & 0x08 != 0
            at = end
            guard decoded < decodeBudget, messages.count < wanted else { break }
            next = batchNext
            // A transaction's commit or abort marker: no message of anyone's.
            if attributes & 0x20 != 0 { continue }
            guard let codec = Codec(rawValue: attributes & 0x07) else { throw Failure("A batch at offset \(baseOffset) is compressed in a way Kafka doesn't name (\(attributes & 0x07)).") }
            let payload = Array(records[r.at..<end])
            let plain = codec == .none ? payload : try inflate(codec, payload)
            decoded += plain.count
            var m = Reader(plain)
            for _ in 0..<count {
                let size = try m.varint()
                guard size >= 0, size <= Int64(m.remaining) else { throw Failure("A record at offset \(baseOffset) runs past its batch.") }
                let start = m.at
                _ = try m.take(Int(size))
                var one = Reader(plain, from: start, to: start + Int(size))
                _ = try one.int8()
                let timestampDelta = try one.varint()
                let offsetDelta = try one.varint()
                let key = try one.varData()
                let value = try one.varData()
                let headerCount = try one.varint()
                guard headerCount >= 0, headerCount <= Int64(one.remaining) else { throw Failure("A record at offset \(baseOffset) has a broken header count.") }
                var headers: [Header] = []
                for _ in 0..<Int(headerCount) {
                    let name = try one.varData().map { String(decoding: $0, as: UTF8.self) } ?? ""
                    headers.append(Header(key: name, value: try one.varData()))
                }
                let offset = baseOffset + offsetDelta
                guard offset >= from else { continue }
                messages.append(
                    Message(
                        offset: offset, timestamp: appendTime ? maxTimestamp : baseTimestamp + timestampDelta, key: key.map { Array($0.prefix(kept)) },
                        value: value.map { Array($0.prefix(kept)) }, headers: headers, valueSize: value?.count ?? 0))
                if messages.count >= wanted {
                    next = offset + 1
                    break
                }
            }
        }
        return (messages, next)
    }

    /// One message as a batch of its own, uncompressed, for Produce.
    package static func batch(key: [UInt8]?, value: [UInt8]?, headers: [Header] = [], timestamp: Int64) -> [UInt8] {
        var record = Writer()
        record.int8(0)
        record.varint(0)  // timestamp delta
        record.varint(0)  // offset delta
        record.varData(key)
        record.varData(value)
        record.varint(Int64(headers.count))
        for header in headers {
            record.varData(Array(header.key.utf8))
            record.varData(header.value)
        }
        var records = Writer()
        records.varint(Int64(record.bytes.count))
        records.raw(record.bytes)
        // What the CRC covers: attributes to the end.
        var checked = Writer()
        checked.int16(0)
        checked.int32(0)  // last offset delta
        checked.int64(timestamp)
        checked.int64(timestamp)
        checked.int64(-1)  // producer id: none
        checked.int16(-1)
        checked.int32(-1)
        checked.int32(1)
        checked.raw(records.bytes)
        var batch = Writer()
        batch.int64(0)
        batch.int32(Int32(4 + 1 + 4 + checked.bytes.count))
        batch.int32(-1)  // partition leader epoch
        batch.int8(2)
        batch.uint32(crc32c(checked.bytes))
        batch.raw(checked.bytes)
        return batch.bytes
    }

    // MARK: Produce

    package static func produceRequest(version: Int16, topic: String, partition: Int32, batch: [UInt8]) -> [UInt8] {
        var w = Writer()
        w.string(nil)  // no transaction
        w.int16(-1)  // acks: every in-sync replica
        w.int32(15_000)
        w.array([topic]) { w, topic in
            w.string(topic)
            w.array([partition]) { w, partition in
                w.int32(partition)
                w.data(batch)
            }
        }
        return w.bytes
    }

    /// The offset the message was written at, or why it wasn't.
    package static func produce(_ body: [UInt8], version: Int16) throws -> Int64 {
        var r = Reader(body)
        var result: Result<Int64, Failure> = .failure(Failure("The broker's answer named no partition."))
        _ = try r.array { r in
            _ = try r.string()
            _ = try r.array { r in
                _ = try r.int32()
                let code = try r.int16()
                let offset = try r.int64()
                _ = try r.int64()
                if version >= 5 { _ = try r.int64() }
                var said: String?
                if version >= 8 {
                    _ = try r.array { r in (try r.int32(), try r.string()) }
                    said = try r.string()
                }
                result = code == 0 ? .success(offset) : .failure(Failure("The broker refused the message: \(error(code))\(said.map { " — \($0)" } ?? "")."))
            }
        }
        return try result.get()
    }

    // MARK: Groups

    package static func findCoordinatorRequest(version: Int16, group: String) -> [UInt8] {
        var w = Writer()
        w.string(group)
        if version >= 1 { w.int8(0) }
        return w.bytes
    }

    package static func findCoordinator(_ body: [UInt8], version: Int16) throws -> Broker {
        var r = Reader(body)
        if version >= 1 { _ = try r.int32() }
        let code = try r.int16()
        let said = version >= 1 ? try r.string() : nil
        let broker = Broker(id: try r.int32(), host: try r.string() ?? "", port: try r.int32())
        guard code == 0 else { throw Failure("No coordinator for the group: \(error(code))\(said.map { " — \($0)" } ?? "").") }
        return broker
    }

    package struct GroupListing: Equatable, Sendable {
        package var id: String
        package var protocolType: String
    }

    package static func listGroups(_ body: [UInt8], version: Int16) throws -> [GroupListing] {
        var r = Reader(body)
        if version >= 1 { _ = try r.int32() }
        let code = try r.int16()
        guard code == 0 else { throw Failure("ListGroups refused: \(error(code)).") }
        return try r.array { r in GroupListing(id: try r.string() ?? "", protocolType: try r.string() ?? "") }
    }

    package struct Group: Equatable, Sendable {
        package var id: String
        package var error: Int16
        package var state: String
        package var protocolType: String
        package var assignor: String
        package var members: [(id: String, client: String, host: String)]

        package static func == (a: Group, b: Group) -> Bool {
            a.id == b.id && a.state == b.state && a.members.map(\.id) == b.members.map(\.id)
        }
    }

    package static func describeGroupsRequest(version: Int16, groups: [String]) -> [UInt8] {
        var w = Writer()
        w.array(groups) { w, group in w.string(group) }
        if version >= 3 { w.bool(false) }
        return w.bytes
    }

    package static func describeGroups(_ body: [UInt8], version: Int16) throws -> [Group] {
        var r = Reader(body)
        if version >= 1 { _ = try r.int32() }
        return try r.array { r -> Group in
            let code = try r.int16()
            let id = try r.string() ?? ""
            let state = try r.string() ?? ""
            let type = try r.string() ?? ""
            let assignor = try r.string() ?? ""
            let members = try r.array { r -> (String, String, String) in
                let member = try r.string() ?? ""
                if version >= 4 { _ = try r.string() }
                let client = try r.string() ?? ""
                let host = try r.string() ?? ""
                _ = try r.data()
                _ = try r.data()
                return (member, client, host)
            }
            if version >= 3 { _ = try r.int32() }
            return Group(id: id, error: code, state: state, protocolType: type, assignor: assignor, members: members.map { (id: $0.0, client: $0.1, host: $0.2) })
        }
    }

    package static func offsetFetchRequest(version: Int16, group: String) -> [UInt8] {
        var w = Writer()
        w.string(group)
        w.array([String]?.none) { _, _ in }  // every topic it has committed for
        return w.bytes
    }

    /// A group's committed offsets, by topic and partition.
    package static func offsetFetch(_ body: [UInt8], version: Int16) throws -> [String: [Int32: Int64]] {
        var r = Reader(body)
        if version >= 3 { _ = try r.int32() }
        var out: [String: [Int32: Int64]] = [:]
        for (topic, partitions) in try r.array({ r -> (String, [(Int32, Int64)]) in
            let name = try r.string() ?? ""
            let partitions = try r.array { r -> (Int32, Int64) in
                let index = try r.int32()
                let offset = try r.int64()
                if version >= 5 { _ = try r.int32() }
                _ = try r.string()
                _ = try r.int16()
                return (index, offset)
            }
            return (name, partitions)
        }) {
            for (index, offset) in partitions where offset >= 0 { out[topic, default: [:]][index] = offset }
        }
        if version >= 2 {
            let code = try r.int16()
            if code != 0 { throw Failure("OffsetFetch refused: \(error(code)).") }
        }
        return out
    }

    // MARK: SASL

    package static func saslHandshakeRequest(mechanism: String) -> [UInt8] {
        var w = Writer()
        w.string(mechanism)
        return w.bytes
    }

    package static func saslHandshake(_ body: [UInt8]) throws -> (error: Int16, mechanisms: [String]) {
        var r = Reader(body)
        let code = try r.int16()
        return (code, try r.array { try $0.string() ?? "" })
    }

    package static func saslAuthenticateRequest(_ token: [UInt8]) -> [UInt8] {
        var w = Writer()
        w.data(token)
        return w.bytes
    }

    package static func saslAuthenticate(_ body: [UInt8]) throws -> [UInt8] {
        var r = Reader(body)
        let code = try r.int16()
        let said = try r.string()
        let token = try r.data() ?? []
        guard code == 0 else { throw Failure(said.map { $0.isEmpty ? error(code) : $0 } ?? error(code)) }
        return token
    }

    // MARK: Checksums and partitions

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }
        return c
    }

    /// CRC-32C (Castagnoli), as record batches carry it.
    package static func crc32c<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// The Java client's murmur2, so a keyed message lands where the
    /// producers' default partitioner would put it.
    package static func murmur2(_ data: [UInt8]) -> Int32 {
        let m: UInt32 = 0x5BD1_E995
        var h: UInt32 = 0x9747_B28C ^ UInt32(truncatingIfNeeded: data.count)
        var i = 0
        while i + 4 <= data.count {
            var k = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            k = k &* m
            k ^= k >> 24
            k = k &* m
            h = h &* m
            h ^= k
            i += 4
        }
        let rest = data.count - i
        if rest >= 3 { h ^= UInt32(data[i + 2]) << 16 }
        if rest >= 2 { h ^= UInt32(data[i + 1]) << 8 }
        if rest >= 1 {
            h ^= UInt32(data[i])
            h = h &* m
        }
        h ^= h >> 13
        h = h &* m
        h ^= h >> 15
        return Int32(bitPattern: h)
    }

    /// The partition the default partitioner gives a key.
    package static func partition(forKey key: [UInt8], of count: Int) -> Int32 {
        Int32((Int(murmur2(key)) & 0x7FFF_FFFF) % max(count, 1))
    }
}
