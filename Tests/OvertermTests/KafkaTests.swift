import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker

/// Kafka: the protocol's bytes, the codecs against their own tools' output
/// (gzip, lz4 with linked blocks, zstd — Fixtures/kafka-codec.*), the
/// console's language, always; against a broker when OVERTERM_DB_TESTS=1
/// and `Scripts/database-test-servers.sh kafka` has one on :59092 (plain)
/// and :59093 (SASL: PLAIN, SCRAM-SHA-256/512 as `ot`/`otpass`).
final class KafkaTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: Self.fixtures.appendingPathComponent(name)))
    }

    // MARK: The protocol

    func testBytes() throws {
        // CRC-32C's check value.
        XCTAssertEqual(KafkaWire.crc32c(Array("123456789".utf8)), 0xE306_9283)
        var writer = KafkaWire.Writer()
        let numbers: [Int64] = [0, -1, 1, 63, -64, 300, -300, .max, .min]
        for n in numbers { writer.varint(n) }
        var reader = KafkaWire.Reader(writer.bytes)
        for n in numbers { XCTAssertEqual(try reader.varint(), n) }
        // The Java client's murmur2: Kafka's own UtilsTest.testMurmur2 cases.
        let murmur: [(String, Int32)] = [
            ("21", -973_932_308), ("foobar", -790_332_482), ("a-little-bit-long-string", -985_981_536),
            ("a-little-bit-longer-string", -1_486_304_829), ("lkjh234lh9fiuh90y23oiuhsafujhadof229phr9h19h89h8", -58_897_971), ("abc", 479_470_107),
        ]
        for (text, hash) in murmur { XCTAssertEqual(KafkaWire.murmur2(Array(text.utf8)), hash, text) }
        XCTAssertEqual(KafkaWire.partition(forKey: Array("foo".utf8), of: 3), 2)
    }

    func testABatchRoundTrips() throws {
        let batch = KafkaWire.batch(
            key: Array("k".utf8), value: Array("hello".utf8), headers: [.init(key: "trace", value: Array("abc".utf8))], timestamp: 1_700_000_000_000)
        let read = try KafkaWire.messages(batch, inflate: KafkaCompression.inflate)
        XCTAssertEqual(read.messages.count, 1)
        XCTAssertEqual(read.messages.first?.value, Array("hello".utf8))
        XCTAssertEqual(read.messages.first?.key, Array("k".utf8))
        XCTAssertEqual(read.messages.first?.headers, [.init(key: "trace", value: Array("abc".utf8))])
        XCTAssertEqual(read.messages.first?.timestamp, 1_700_000_000_000)
        XCTAssertEqual(read.next, 1)
        // A batch cut at the end of a fetch: nothing whole, left for the next.
        XCTAssertNil(try KafkaWire.messages(Array(batch.dropLast(3)), inflate: KafkaCompression.inflate).next)
        // Damaged bytes fail the CRC.
        var damaged = batch
        damaged[damaged.count - 2] ^= 0xFF
        XCTAssertThrowsError(try KafkaWire.messages(damaged, inflate: KafkaCompression.inflate))
    }

    /// A batch changed in place, its CRC made right again — what a broker
    /// that lies would send.
    private func altered(_ batch: [UInt8], _ change: (inout [UInt8]) -> Void) -> [UInt8] {
        var bytes = batch
        change(&bytes)
        let crc = KafkaWire.crc32c(bytes[21...])
        for k in 0..<4 { bytes[17 + k] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * k)) }
        return bytes
    }

    func testABrokerThatLiesCrashesNothing() throws {
        let batch = KafkaWire.batch(key: nil, value: Array("v".utf8), timestamp: 1_000)
        // A negative record count.
        let negative = altered(batch) { for k in 57..<61 { $0[k] = 0xFF } }
        XCTAssertThrowsError(try KafkaWire.messages(negative, inflate: KafkaCompression.inflate))
        // A record that says it is longer than its batch (a varint near Int64.max).
        let long = altered(batch) { bytes in
            bytes.replaceSubrange(61..<62, with: [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
            bytes[11] += 9  // the batch's length, so only the record lies
        }
        XCTAssertThrowsError(try KafkaWire.messages(long, inflate: KafkaCompression.inflate))
        // A string longer than Int16 is cut, not a trap.
        var writer = KafkaWire.Writer()
        writer.string(String(repeating: "a", count: 40_000))
        XCTAssertEqual(writer.bytes.count, 2 + Int(Int16.max))
        XCTAssertThrowsError(try KafkaText.parse("PEEK " + String(repeating: "t", count: 250)))
    }

    func testLogAppendTime() throws {
        let batch = KafkaWire.batch(key: nil, value: Array("v".utf8), timestamp: 1_000)
        // The broker's time: attribute 0x08, every record's timestamp the batch's max.
        let appended = altered(batch) { bytes in
            bytes[22] |= 0x08
            for k in 0..<8 { bytes[35 + k] = UInt8(truncatingIfNeeded: Int64(5_000) >> (56 - 8 * k)) }
        }
        XCTAssertEqual(try KafkaWire.messages(appended, inflate: KafkaCompression.inflate).messages.first?.timestamp, 5_000)
    }

    func testVersions() throws {
        XCTAssertEqual(try KafkaWire.version(of: .fetch, broker: [1: 4...17]), 11, "the last before tagged fields")
        XCTAssertEqual(try KafkaWire.version(of: .metadata, broker: [3: 0...5]), 5)
        XCTAssertThrowsError(try KafkaWire.version(of: .fetch, broker: [1: 12...17])) { error in
            XCTAssertTrue(error.localizedDescription.contains("only from version 12"), error.localizedDescription)
        }
        XCTAssertThrowsError(try KafkaWire.version(of: .produce, broker: [:]))
    }

    func testCodecs() throws {
        let plain = try fixture("kafka-codec.txt")
        XCTAssertEqual(try KafkaCompression.inflate(.gzip, fixture("kafka-codec.txt.gz")), plain)
        XCTAssertEqual(try KafkaCompression.inflate(.lz4, fixture("kafka-codec.txt.lz4")), plain, "64 KB linked blocks with checksums (lz4 -B4 -BD -BX)")
        XCTAssertTrue(KafkaCompression.readsZstd, "zstd from DuckDB's library")
        XCTAssertEqual(try KafkaCompression.inflate(.zstd, fixture("kafka-codec.txt.zst")), plain)
        // Snappy: a literal, then a copy of it; raw, and in xerial's framing.
        let raw: [UInt8] = [12, 3 << 2, 0x61, 0x62, 0x63, 0x64, ((8 - 4) << 2) | 1, 4]
        XCTAssertEqual(try KafkaCompression.inflate(.snappy, raw), Array("abcdabcdabcd".utf8))
        let framed: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00, 0, 0, 0, 1, 0, 0, 0, 1] + [0, 0, 0, UInt8(raw.count)] + raw + [0, 0, 0, UInt8(raw.count)] + raw
        XCTAssertEqual(try KafkaCompression.inflate(.snappy, framed), Array(String(repeating: "abcd", count: 6).utf8))
        XCTAssertThrowsError(try KafkaCompression.inflate(.gzip, [1, 2, 3]))
    }

    // MARK: The console

    func testCommands() throws {
        XCTAssertEqual(try KafkaText.parse("TOPICS"), .topics)
        XCTAssertEqual(try KafkaText.parse("peek orders"), .peek(topic: "orders", count: 10, partition: nil, from: .newest))
        XCTAssertEqual(try KafkaText.parse("PEEK orders 5 PARTITION 1 FROM 42"), .peek(topic: "orders", count: 5, partition: 1, from: .offset(42)))
        XCTAssertEqual(try KafkaText.parse("PEEK \"my topic\" FROM BEGINNING"), .peek(topic: "my topic", count: 10, partition: nil, from: .beginning))
        XCTAssertThrowsError(try KafkaText.parse("PEEK orders FROM 42"), "an offset needs its partition")
        XCTAssertEqual(
            try KafkaText.parse(#"PUBLISH orders KEY "a b" {"id": 1}"#), .publish(topic: "orders", partition: nil, key: "a b", value: #"{"id": 1}"#))
        XCTAssertEqual(try KafkaText.parse("PUBLISH orders PARTITION 2 hello\nworld"), .publish(topic: "orders", partition: 2, key: nil, value: "hello\nworld"))
        XCTAssertThrowsError(try KafkaText.parse("PUBLISH orders"))
        XCTAssertEqual(try KafkaText.parse("LAG billing"), .lag("billing"))
        let text = "TOPICS\n\n# a comment\nPUBLISH t {\n  \"a\": 1\n}\nLAG g"
        XCTAssertEqual(KafkaText.statements(in: text).map { (text as NSString).substring(with: $0) }, ["TOPICS", "PUBLISH t {\n  \"a\": 1\n}", "LAG g"])
        XCTAssertTrue(DatabaseKind.kafka.agentReads("PEEK orders 5"))
        XCTAssertFalse(DatabaseKind.kafka.agentReads("PUBLISH orders x"), "a write: asked, or refused")
        XCTAssertFalse(DatabaseKind.kafka.onlyReads("PUBLISH orders x"))
        XCTAssertEqual(KafkaText.browse(CatalogTable(schema: "topics", name: "my orders"), limit: 100), #"PEEK "my orders" 100"#)
        XCTAssertEqual(KafkaText.browse(CatalogTable(schema: "groups", name: "billing"), limit: 100), "LAG billing")
        XCTAssertEqual(KafkaText.text(Array("héllo".utf8)), "héllo")
        XCTAssertEqual(KafkaText.text([0, 1, 255]), "0x0001ff (3 bytes)")
        XCTAssertEqual(KafkaText.text(Array("abc".utf8), size: 70_000), "abc… (70000 bytes)", "only its start kept")
    }

    func testConnection() {
        XCTAssertEqual(DatabaseKind.kafka.defaultPort, 9092)
        XCTAssertEqual(DatabaseKind.kafka.features, [.monitoring])
        var connection = DatabaseConnection(name: "k", kind: .kafka)
        connection.host = "a:9093, b"
        XCTAssertEqual(KafkaDriver.seeds(connection).map { "\($0.host):\($0.port)" }, ["a:9093", "b:9092"])
        connection.sshEnabled = true
        connection.sshHost = "bastion"
        XCTAssertEqual(connection.problem, "Through a tunnel, one broker: its address — a cluster's other brokers can't be reached that way.")
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "apache/kafka:4.1.0")?.0, .kafka)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "confluentinc/cp-kafka:7.6.0")?.0, .kafka)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "redpandadata/redpanda:v24.1.1")?.0, .kafka)
        XCTAssertNil(DockerDatabaseGuess.kind(of: "provectuslabs/kafka-ui"))
        XCTAssertNil(DockerDatabaseGuess.kind(of: "confluentinc/cp-kafka-connect"))
        XCTAssertNil(DockerDatabaseGuess.kind(of: "confluentinc/cp-schema-registry"))
    }

    // MARK: Against a broker

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(port: Int = 59092, mechanism: String = "", readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Kafka", kind: .kafka)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.sslMode = .disable
        connection.authSource = mechanism
        connection.user = mechanism.isEmpty ? "" : "ot"
        connection.readOnly = readOnly
        return connection
    }

    func testABroker() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh kafka")
        let topic = "ot.orders.\(UUID().uuidString.prefix(8))"
        let driver = KafkaDriver(connection(), password: nil)
        try await driver.connect()
        // A topic is made by its first message where the broker creates them (the script's does).
        for i in 0..<6 { _ = try await driver.execute("PUBLISH \(topic) KEY order-\(i) {\"id\": \(i)}", limit: 1) }
        let published = try await driver.execute("PUBLISH \(topic) PARTITION 0 plain", limit: 1)
        XCTAssertEqual(published.affected, 1)
        let newest = try await driver.execute("PEEK \(topic) 3", limit: 100)
        XCTAssertEqual(newest.columns, ["partition", "offset", "timestamp", "key", "value", "headers"])
        XCTAssertEqual(newest.rows.count, 3)
        let all = try await driver.execute("PEEK \(topic) 100 FROM BEGINNING", limit: 1000)
        XCTAssertEqual(all.rows.count, 7)
        XCTAssertEqual(Set(all.rows.compactMap { $0[4] }), Set((0..<6).map { "{\"id\": \($0)}" } + ["plain"]))
        let described = try await driver.execute("DESCRIBE \(topic)", limit: 100)
        XCTAssertEqual(described.rows.compactMap { $0[6].flatMap(Int.init) }.reduce(0, +), 7)
        let topics = try await driver.execute("TOPICS", limit: 1000)
        XCTAssertTrue(topics.rows.contains { $0[0] == topic && $0[3] == "7" }, "\(topics.rows)")
        let tables = try await driver.tables(in: KafkaText.topicsSchema)
        XCTAssertTrue(tables.contains { $0.name == topic })
        do {
            _ = try await driver.execute("PEEK nope.\(UUID().uuidString)", limit: 1)
            XCTFail("no such topic")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No topic"), error.localizedDescription)
        }
        // Each codec, as Kafka's own producer wrote it (the script's topics).
        for codec in ["gzip", "snappy", "lz4", "zstd"] {
            let read = try await driver.execute("PEEK ot.codec.\(codec) 10 FROM BEGINNING", limit: 10)
            XCTAssertEqual(Set(read.rows.compactMap { $0[4] }), ["one", "two", "three"], codec)
        }
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Brokers" && $0.value == "1" }, "\(overview.facts)")
        await driver.close()

        let reader = KafkaDriver(connection(readOnly: true), password: nil)
        do {
            _ = try await reader.execute("PUBLISH \(topic) x", limit: 1)
            XCTFail("a read-only connection published")
        } catch {
            XCTAssertEqual(error as? DatabaseError, .readOnly("PUBLISH"))
        }
    }

    func testSignIn() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh kafka")
        for mechanism in KafkaDriver.mechanisms {
            let driver = KafkaDriver(connection(port: 59093, mechanism: mechanism), password: "otpass")
            try await driver.connect()
            _ = try await driver.execute("TOPICS", limit: 10)
            await driver.close()
            do {
                try await KafkaDriver(connection(port: 59093, mechanism: mechanism), password: "wrong").connect()
                XCTFail("\(mechanism) signed in with a wrong password")
            } catch {
                XCTAssertTrue(error.localizedDescription.hasPrefix("Authentication failed"), "\(mechanism): \(error.localizedDescription)")
            }
        }
    }
}
